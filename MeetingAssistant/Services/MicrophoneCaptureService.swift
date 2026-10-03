import AVFoundation
import CoreAudio

/// Captures the user's microphone for the "me" side of the transcript.
///
/// On speakers the mic also hears the meeting. Apple voice processing removes
/// that echo: in a speaker test a 94-character echo transcript dropped to
/// zero, and the user's own speech stayed clean while both sides talked. It
/// ducks other audio about 8 dB even at the minimum level (the default level
/// nearly mutes the meeting), so it is only used when the meeting plays on
/// speakers; on headphones there is no echo and the raw mic is used.
///
/// `start` / `stop` are called from the main actor only; captured buffers are
/// copied in the engine's tap and handed to `callbackQueue`.
final class MicrophoneCaptureService {
    typealias AudioHandler = (AVAudioPCMBuffer) -> Void
    typealias FailureHandler = (Error) -> Void

    private let callbackQueue: DispatchQueue
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?

    // kIOAudioOutputPortSubTypeHeadphones ('hdpn'): the built-in jack on
    // Macs that switch one built-in device between speakers and headphones.
    private static let headphonesDataSource: UInt32 = 0x6864_706E
    // Apple silicon / T2 Macs expose the jack as its own built-in device.
    private static let headphonesDeviceUIDMarker = "Headphone"
    // kAudioUnitErr_FailedInitialization: voice processing refuses some
    // input/output pairs, e.g. a Continuity or USB mic with built-in speakers.
    private static let voiceProcessingInitializationFailed = -10875

    init(callbackQueue: DispatchQueue) {
        self.callbackQueue = callbackQueue
    }

    deinit {
        stop()
    }

    func start(
        echoCancellation: Bool,
        audioHandler: @escaping AudioHandler,
        failureHandler: @escaping FailureHandler
    ) throws {
        stop()
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        do {
            if echoCancellation {
                try input.setVoiceProcessingEnabled(true)
                input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )
            }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0,
                  format.channelCount > 0,
                  let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)
            else {
                throw MicrophoneCaptureError.noInput
            }
            input.installTap(
                onBus: 0,
                bufferSize: 4096,
                format: format,
                block: Self.copyingTap(into: mono, queue: callbackQueue, handler: audioHandler)
            )
            // Gives the engine its output side: voice processing runs input
            // and output as one unit, and with the raw mic it makes an output
            // device change (headphones unplugged) post a configuration
            // change, which restarts the mic with a fresh echo decision.
            _ = engine.mainMixerNode
            do {
                try engine.start()
            } catch let error as NSError where echoCancellation && error.code == Self.voiceProcessingInitializationFailed {
                throw MicrophoneCaptureError.unsupportedDevices
            }
            // Registered after start: enabling voice processing itself
            // reconfigures the device.
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { _ in
                failureHandler(MicrophoneCaptureError.deviceChanged)
            }
            print(
                "[MicrophoneCaptureService] started echoCancellation=\(echoCancellation) " +
                    "sampleRate=\(Int(format.sampleRate)) channels=\(format.channelCount)"
            )
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        // Voice processing left on would keep other audio ducked.
        if engine.inputNode.isVoiceProcessingEnabled {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
        self.engine = nil
    }

    // Voice processing delivers several channels; channel 0 is the processed
    // voice. Static so the block is not inferred as main-actor isolated.
    private static func copyingTap(
        into mono: AVAudioFormat,
        queue: DispatchQueue,
        handler: @escaping AudioHandler
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let source = buffer.floatChannelData?[0],
                  buffer.frameLength > 0,
                  let copy = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
                  let destination = copy.floatChannelData?[0]
            else { return }
            copy.frameLength = buffer.frameLength
            destination.update(from: source, count: Int(buffer.frameLength))
            queue.async { handler(copy) }
        }
    }

    // MARK: - Output device

    /// True when the meeting plays where the mic can hear it.
    static func currentOutputNeedsEchoCancellation() -> Bool {
        guard let device = readDefaultOutputDevice() else { return true }
        let transport = readUInt32(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal) ?? 0
        let dataSource = readUInt32(device, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput)
        return needsEchoCancellation(transportType: transport, dataSource: dataSource, uid: readUID(device))
    }

    static func needsEchoCancellation(transportType: UInt32, dataSource: UInt32?, uid: String?) -> Bool {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            let isHeadphones = dataSource == headphonesDataSource
                || uid?.contains(headphonesDeviceUIDMarker) == true
            return !isHeadphones
        // ponytail: Bluetooth output is assumed to be headphones; a Bluetooth
        // speaker would echo. USB headsets get voice processing they do not
        // need. Make it a setting if either shows up in practice.
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return false
        default:
            return true
        }
    }

    private static func readDefaultOutputDevice() -> AudioObjectID? {
        let device = readUInt32(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioObjectPropertyScopeGlobal
        )
        return device.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    private static func readUID(_ device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        return status == noErr ? uid as String? : nil
    }

    private static func readUInt32(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}

enum MicrophoneCaptureError: LocalizedError {
    case permissionDenied
    case noInput
    case unsupportedDevices
    case deviceChanged

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone permission denied. Enable Meeting Assistant in System Settings > Privacy & Security > Microphone."
        case .noInput:
            return "No microphone input is available."
        case .unsupportedDevices:
            return "Echo cancellation cannot run with this microphone and speaker. Use the built-in microphone, or wear headphones."
        case .deviceChanged:
            return "The microphone or speaker kept changing, so the microphone was turned off. Turn it on again once the devices settle."
        }
    }
}
