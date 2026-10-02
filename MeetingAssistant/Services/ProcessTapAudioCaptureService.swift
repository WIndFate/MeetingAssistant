import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Owns the complete Core Audio process-tap lifecycle. Audio IO is dispatched
/// synchronously onto the caller-provided serial queue, so the buffer remains
/// valid while it is copied into an owned `AVAudioPCMBuffer` and no Core Audio
/// pointer crosses an asynchronous boundary.
final class ProcessTapAudioCaptureService: @unchecked Sendable {
    typealias AudioHandler = (AVAudioPCMBuffer) -> Void
    typealias FailureHandler = (Error) -> Void

    private let callbackQueue: DispatchQueue
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.windfate.meetingassistant",
        category: "ProcessTapAudioCapture"
    )
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false
    private var aggregateAliveListener: AudioObjectPropertyListenerBlock?
    private var audioServiceRestartListener: AudioObjectPropertyListenerBlock?
    private var diagnosticFramesReceived: UInt64 = 0
    private var didLogFirstBuffer = false
    private var didLogSignal = false
    private var didLogSilentWarning = false

    init(callbackQueue: DispatchQueue) {
        self.callbackQueue = callbackQueue
    }

    deinit {
        stop()
    }

    func start(
        audioHandler: @escaping AudioHandler,
        failureHandler: @escaping FailureHandler
    ) throws {
        stop()

        do {
            let tapDescription = try makeSystemAudioTapDescription()

            var createdTapID = AudioObjectID(kAudioObjectUnknown)
            try checkStatus(
                AudioHardwareCreateProcessTap(tapDescription, &createdTapID),
                operation: "create the process audio tap"
            )
            tapID = createdTapID

            var tapFormat = try readTapFormat(tapID: createdTapID)
            let resolvedSourceFormat = withUnsafePointer(to: &tapFormat) {
                AVAudioFormat(streamDescription: $0)
            }
            guard
                tapFormat.mFormatID == kAudioFormatLinearPCM,
                tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                tapFormat.mBitsPerChannel == 32,
                tapFormat.mChannelsPerFrame == 1,
                let sourceFormat = resolvedSourceFormat
            else {
                throw ProcessTapCaptureError.unsupportedTapFormat(tapFormat)
            }

            let systemOutputDeviceID = try readDefaultSystemOutputDeviceID()
            let systemOutputUID = try readDeviceUID(deviceID: systemOutputDeviceID)
            var createdAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            let tapUID = tapDescription.uuid.uuidString
            let subTapDescription: [String: Any] = [
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Meeting Assistant Audio Capture \(UUID().uuidString)",
                kAudioAggregateDeviceUIDKey: "com.windfate.meetingassistant.tap.\(UUID().uuidString)",
                // Anchor the private aggregate to the current system output.
                // A tap-only aggregate can start its IOProc yet deliver only
                // zeroes because it has no hardware clock/source device.
                kAudioAggregateDeviceMainSubDeviceKey: systemOutputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: systemOutputUID],
                ],
                // The aggregate must be born with its complete sub-tap
                // composition. Attaching only a UUID after creation can leave
                // the IOProc running while every delivered sample is zero.
                kAudioAggregateDeviceTapListKey: [subTapDescription],
                kAudioAggregateDeviceTapAutoStartKey: true,
            ]
            try checkStatus(
                AudioHardwareCreateAggregateDevice(
                    aggregateDescription as CFDictionary,
                    &createdAggregateDeviceID
                ),
                operation: "create the private aggregate audio device"
            )
            aggregateDeviceID = createdAggregateDeviceID
            try verifyTapAttachment(
                uid: tapUID,
                aggregateDeviceID: createdAggregateDeviceID
            )

            var createdIOProcID: AudioDeviceIOProcID?
            let createIOStatus = AudioDeviceCreateIOProcIDWithBlock(
                &createdIOProcID,
                createdAggregateDeviceID,
                callbackQueue
            ) { [weak self] _, inputData, _, _, _ in
                guard let buffer = Self.copyInputBuffer(
                    inputData,
                    format: sourceFormat
                ) else {
                    return
                }
                self?.recordDiagnostics(for: buffer)
                audioHandler(buffer)
            }
            try checkStatus(createIOStatus, operation: "create the aggregate-device IO callback")
            guard let createdIOProcID else {
                throw ProcessTapCaptureError.missingIOProc
            }
            ioProcID = createdIOProcID

            try checkStatus(
                AudioDeviceStart(createdAggregateDeviceID, createdIOProcID),
                operation: "start system audio capture"
            )
            isRunning = true
            try registerFailureListeners(
                aggregateDeviceID: createdAggregateDeviceID,
                failureHandler: failureHandler
            )

            print(
                "[ProcessTapAudioCaptureService] started " +
                    "tapID=\(createdTapID) aggregateDeviceID=\(createdAggregateDeviceID) " +
                    "sampleRate=\(Int(sourceFormat.sampleRate)) channels=\(sourceFormat.channelCount)"
            )
            Self.logger.info(
                "started tapID=\(createdTapID) aggregateDeviceID=\(createdAggregateDeviceID) sampleRate=\(sourceFormat.sampleRate) channels=\(sourceFormat.channelCount)"
            )
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        let deviceID = aggregateDeviceID
        let currentIOProcID = ioProcID

        unregisterFailureListeners(aggregateDeviceID: deviceID)

        // Stop callbacks before releasing their block and before destroying the
        // aggregate/tap objects they reference.
        if deviceID != kAudioObjectUnknown, let currentIOProcID {
            if isRunning {
                logCleanupStatus(
                    AudioDeviceStop(deviceID, currentIOProcID),
                    operation: "stop aggregate-device IO"
                )
            }
            logCleanupStatus(
                AudioDeviceDestroyIOProcID(deviceID, currentIOProcID),
                operation: "destroy aggregate-device IO callback"
            )
        }

        ioProcID = nil
        isRunning = false
        diagnosticFramesReceived = 0
        didLogFirstBuffer = false
        didLogSignal = false
        didLogSilentWarning = false

        if deviceID != kAudioObjectUnknown {
            logCleanupStatus(
                AudioHardwareDestroyAggregateDevice(deviceID),
                operation: "destroy private aggregate device"
            )
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != kAudioObjectUnknown {
            logCleanupStatus(
                AudioHardwareDestroyProcessTap(tapID),
                operation: "destroy process audio tap"
            )
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Mono mixdown of everything the Mac plays, excluding this app itself.
    private func makeSystemAudioTapDescription() throws -> CATapDescription {
        let ownProcessObjectID = try readProcessObjectID(
            pid: ProcessInfo.processInfo.processIdentifier
        )
        let excluded = ownProcessObjectID == kAudioObjectUnknown ? [] : [ownProcessObjectID]
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        description.name = "Meeting Assistant Process Tap"
        description.bundleIDs = Bundle.main.bundleIdentifier.map { [$0] } ?? []
        description.isPrivate = true
        description.isProcessRestoreEnabled = true
        description.muteBehavior = .unmuted
        return description
    }

    private func readProcessObjectID(pid: Int32) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var propertySize = UInt32(MemoryLayout<AudioObjectID>.stride)
        let status = withUnsafePointer(to: &qualifier) { qualifierPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<Int32>.stride),
                qualifierPointer,
                &propertySize,
                &objectID
            )
        }
        try checkStatus(status, operation: "translate this app's PID to an audio process")
        return objectID
    }

    private func readDefaultSystemOutputDeviceID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var propertySize = UInt32(MemoryLayout<AudioObjectID>.stride)
        try checkStatus(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &propertySize,
                &deviceID
            ),
            operation: "read the default system output device"
        )
        guard deviceID != kAudioObjectUnknown else {
            throw ProcessTapCaptureError.missingSystemOutputDevice
        }
        return deviceID
    }

    private func readDeviceUID(deviceID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString? = nil
        var propertySize = UInt32(MemoryLayout<CFString?>.stride)
        try withUnsafeMutablePointer(to: &value) { valuePointer in
            try checkStatus(
                AudioObjectGetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    &propertySize,
                    valuePointer
                ),
                operation: "read the default system output device UID"
            )
        }
        guard let uid = value as String?, !uid.isEmpty else {
            throw ProcessTapCaptureError.missingSystemOutputDevice
        }
        return uid
    }

    private func readTapFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
        try checkStatus(
            AudioObjectGetPropertyData(
                tapID,
                &address,
                0,
                nil,
                &propertySize,
                &format
            ),
            operation: "read the process-tap audio format"
        )
        return format
    }

    private func verifyTapAttachment(
        uid: String,
        aggregateDeviceID: AudioObjectID
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize: UInt32 = 0
        try checkStatus(
            AudioObjectGetPropertyDataSize(
                aggregateDeviceID,
                &address,
                0,
                nil,
                &propertySize
            ),
            operation: "read the aggregate-device tap-list size"
        )
        var tapList: CFArray? = nil
        let status = withUnsafeMutablePointer(to: &tapList) { listPointer in
            AudioObjectGetPropertyData(
                aggregateDeviceID,
                &address,
                0,
                nil,
                &propertySize,
                listPointer
            )
        }
        try checkStatus(status, operation: "read the aggregate-device tap list")
        let attachedUIDs = (tapList as? [CFString])?.map { $0 as String } ?? []
        guard attachedUIDs.contains(uid) else {
            throw ProcessTapCaptureError.tapAttachmentMissing
        }
    }

    private func registerFailureListeners(
        aggregateDeviceID: AudioObjectID,
        failureHandler: @escaping FailureHandler
    ) throws {
        var aliveAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let aliveListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.checkAggregateDeviceIsAlive(
                aggregateDeviceID,
                failureHandler: failureHandler
            )
        }
        try checkStatus(
            AudioObjectAddPropertyListenerBlock(
                aggregateDeviceID,
                &aliveAddress,
                callbackQueue,
                aliveListener
            ),
            operation: "monitor the aggregate audio device"
        )
        aggregateAliveListener = aliveListener

        var restartAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyServiceRestarted,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let restartListener: AudioObjectPropertyListenerBlock = { _, _ in
            failureHandler(ProcessTapCaptureError.audioServiceRestarted)
        }
        do {
            try checkStatus(
                AudioObjectAddPropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    &restartAddress,
                    callbackQueue,
                    restartListener
                ),
                operation: "monitor Core Audio service restarts"
            )
            audioServiceRestartListener = restartListener
        } catch {
            AudioObjectRemovePropertyListenerBlock(
                aggregateDeviceID,
                &aliveAddress,
                callbackQueue,
                aliveListener
            )
            aggregateAliveListener = nil
            throw error
        }
    }

    private func unregisterFailureListeners(aggregateDeviceID: AudioObjectID) {
        if aggregateDeviceID != kAudioObjectUnknown,
           let aggregateAliveListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                aggregateDeviceID,
                &address,
                callbackQueue,
                aggregateAliveListener
            )
            self.aggregateAliveListener = nil
        }

        if let audioServiceRestartListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyServiceRestarted,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                callbackQueue,
                audioServiceRestartListener
            )
            self.audioServiceRestartListener = nil
        }
    }

    private func checkAggregateDeviceIsAlive(
        _ aggregateDeviceID: AudioObjectID,
        failureHandler: FailureHandler
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isAlive: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.stride)
        let status = AudioObjectGetPropertyData(
            aggregateDeviceID,
            &address,
            0,
            nil,
            &propertySize,
            &isAlive
        )
        if status != noErr || isAlive == 0 {
            failureHandler(ProcessTapCaptureError.aggregateDeviceStopped(status: status))
        }
    }

    private static func copyInputBuffer(
        _ inputData: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let streamDescription = format.streamDescription
        let bytesPerFrame = Int(streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }

        // A mono mixdown process tap contributes exactly one aggregate input
        // buffer on supported configurations. Reject any unexpected layout
        // instead of guessing at buffer ordering and mixing the wrong stream.
        guard inputData.pointee.mNumberBuffers == 1 else {
            return nil
        }
        let source = inputData.pointee.mBuffers
        guard source.mData != nil, source.mDataByteSize > 0 else { return nil }
        let frameCount = AVAudioFrameCount(Int(source.mDataByteSize) / bytesPerFrame)
        guard frameCount > 0,
              let ownedBuffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: frameCount
              )
        else {
            return nil
        }

        // AVAudioPCMBuffer starts with frameLength == 0, so its ABL reports a
        // zero mDataByteSize even though backing storage for frameCapacity has
        // been allocated. Set the length before consulting the destination ABL;
        // otherwise min(sourceSize, destinationSize) copies zero bytes and turns
        // every valid process-tap buffer into silence.
        ownedBuffer.frameLength = frameCount
        let destinationList = ownedBuffer.mutableAudioBufferList
        guard destinationList.pointee.mNumberBuffers == 1,
              let sourceData = source.mData,
              let destinationData = destinationList.pointee.mBuffers.mData
        else {
            return nil
        }
        let destinationCapacity = Int(frameCount) * bytesPerFrame
        let byteCount = Int(source.mDataByteSize)
        guard byteCount <= destinationCapacity else { return nil }
        memcpy(destinationData, sourceData, byteCount)
        destinationList.pointee.mBuffers.mDataByteSize = UInt32(byteCount)
        return ownedBuffer
    }

    /// A running IOProc does not prove that the tap carries real audio. Keep a
    /// lightweight signal probe so an all-zero tap is visible in both Xcode and
    /// the macOS unified log instead of looking like a successful startup.
    private func recordDiagnostics(for buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        diagnosticFramesReceived += UInt64(frameCount)

        if !didLogFirstBuffer {
            didLogFirstBuffer = true
            print(
                "[ProcessTapAudioCaptureService] first buffer " +
                    "frames=\(frameCount) sampleRate=\(Int(buffer.format.sampleRate))"
            )
            Self.logger.info(
                "first buffer frames=\(frameCount) sampleRate=\(buffer.format.sampleRate)"
            )
        }

        // Stop inspecting individual samples once live audio has been proven;
        // the downstream recognition path already performs its own RMS work.
        guard !didLogSignal,
              let samples = buffer.floatChannelData?[0],
              frameCount > 0
        else {
            return
        }
        var peak: Float = 0
        for index in 0..<frameCount {
            peak = max(peak, abs(samples[index]))
        }

        if peak > 0.000_01 {
            didLogSignal = true
            print(
                "[ProcessTapAudioCaptureService] non-silent signal detected " +
                    "peak=\(peak) framesReceived=\(diagnosticFramesReceived)"
            )
            Self.logger.notice(
                "non-silent signal detected peak=\(peak) framesReceived=\(self.diagnosticFramesReceived)"
            )
        } else if !didLogSilentWarning,
                  diagnosticFramesReceived >= UInt64(buffer.format.sampleRate * 3)
        {
            didLogSilentWarning = true
            print(
                "[ProcessTapAudioCaptureService] warning: received 3 seconds " +
                    "of all-zero audio; verify the selected source is playing"
            )
            Self.logger.warning(
                "received 3 seconds of all-zero audio; verify the selected source is playing"
            )
        }
    }

    private func checkStatus(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            if status == kAudioDevicePermissionsError {
                throw ProcessTapCaptureError.permissionDenied
            }
            throw ProcessTapCaptureError.coreAudioFailure(
                operation: operation,
                status: status
            )
        }
    }

    private func logCleanupStatus(_ status: OSStatus, operation: String) {
        guard status != noErr,
              status != kAudioHardwareBadObjectError,
              status != kAudioHardwareBadDeviceError
        else {
            return
        }
        print(
            "[ProcessTapAudioCaptureService] cleanup warning " +
                "operation=\(operation) status=\(status)"
        )
    }
}

enum ProcessTapCaptureError: LocalizedError {
    case permissionDenied
    case missingSystemOutputDevice
    case unsupportedTapFormat(AudioStreamBasicDescription)
    case tapAttachmentMissing
    case missingIOProc
    case aggregateDeviceStopped(status: OSStatus)
    case audioServiceRestarted
    case coreAudioFailure(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "System Audio Recording permission denied. Enable Meeting Assistant in System Settings > Privacy & Security > Screen & System Audio Recording."
        case .missingSystemOutputDevice:
            return "Core Audio could not resolve the current system output device. Connect an output device and start listening again."
        case .unsupportedTapFormat(let format):
            return "Core Audio returned an unsupported process-tap format (formatID \(format.mFormatID), \(format.mChannelsPerFrame) channels, \(format.mBitsPerChannel)-bit)."
        case .tapAttachmentMissing:
            return "Core Audio did not attach the process tap to the private aggregate device."
        case .missingIOProc:
            return "Core Audio did not return an audio IO callback."
        case .aggregateDeviceStopped(let status):
            return "The Core Audio capture device stopped unexpectedly (OSStatus \(status)). Start listening again."
        case .audioServiceRestarted:
            return "The Core Audio service restarted. Start listening again to rebuild the audio tap."
        case .coreAudioFailure(let operation, let status):
            return "Failed to \(operation) (Core Audio OSStatus \(status), \(Self.fourCC(status)))."
        }
    }

    private static func fourCC(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        guard bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
            return "non-printable"
        }
        return String(bytes: bytes, encoding: .ascii) ?? "unknown"
    }
}
