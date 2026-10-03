import Accelerate
import AVFoundation
import Foundation
import os
import Speech

/// Audio source → SpeechAnalyzer → paragraphs. One instance per source:
/// system audio (other participants) or the microphone (the user).
///
/// Paragraph rules live in `TranscriptAssembler`, including mid-speech cuts
/// at sentence ends. This service only decides *when* the speaker went quiet
/// and then asks the analyzer to finalize, closing the paragraph once the
/// final arrives.
///
/// A recognizer gap alone is not silence: with fastResults the analyzer
/// updates only about once a second while someone is still talking, which cut
/// mid-sentence fragments in a real run. Quiet therefore also requires the
/// audio itself to be quiet; a long gap closes regardless, so a very low
/// meeting volume cannot keep the last sentence open forever. An explicit
/// finalize returns the final within ~50ms, far sooner than the analyzer's
/// own endpointing (~2s).
@MainActor
final class SpeechTranscriptionService {
    enum Source {
        case system
        case microphone
    }

    var onStateChange: ((TranscriptionState) -> Void)?
    private(set) var state = TranscriptionState()
    let source: Source
    /// Microphone only: remove the meeting's echo from the mic.
    var usesEchoCancellation = false
    /// System audio only: see `ProcessTapAudioCaptureService.start`.
    private(set) var anchorsToOutputDevice = true

    private let audioQueue: DispatchQueue
    private lazy var tapCapture = ProcessTapAudioCaptureService(callbackQueue: audioQueue)
    private lazy var micCapture = MicrophoneCaptureService(callbackQueue: audioQueue)
    // Internal (not private) so a headless harness can feed recorded audio.
    let feedSlot = AudioFeedSlot()
    let levelMeter = AudioLevelMeter()
    private var engine: SpeechAnalyzerEngine?
    private var assembler = TranscriptAssembler(language: .japanese)
    private var language: TranscriptionLanguage = .japanese
    private var generation = 0
    // Bumped whenever a capture starts or stops: a torn-down capture's
    // device-alive callback can still arrive afterwards and must not stop
    // the capture that replaced it.
    private var captureGeneration = 0
    // Bumped by start, stop and fail: a start still awaiting permission or
    // the speech model must not open the capture after the user stopped.
    private var startRequest = 0
    /// Why the last run stopped, for callers that react to specific errors.
    private(set) var lastFailure: Error?

    private var quietTask: Task<Void, Never>?
    private var finalizeFallbackTask: Task<Void, Never>?
    private var awaitingQuietCommit = false

    // Volatile results arrive in bursts about once a second while someone
    // talks, so a recognizer gap is a weak signal; quiet audio is the real
    // one. Check soon after each update and let the audio gate decide.
    private let quietInterval: Duration = .milliseconds(600)
    private let audioQuietSeconds: TimeInterval = 0.6
    // A gap this long closes the paragraph even if the audio is not quiet.
    private let forcedQuietGap: TimeInterval = 3.0
    private var lastRecognizerUpdateAt = Date()
    // If the analyzer sends no final after a finalize request, close the
    // paragraph with what is already final; volatile text stays live.
    private let finalizeFallbackDelay: Duration = .milliseconds(1500)

    init(source: Source) {
        self.source = source
        audioQueue = DispatchQueue(label: "MeetingAssistant.Audio.\(source)")
    }

    func start(language: TranscriptionLanguage) async {
        guard !state.isListening else { return }
        startRequest += 1
        let request = startRequest
        self.language = language
        clearError()
        setStatus("Starting...")
        do {
            try await ensureSpeechPermission()
            guard startRequest == request else { return }
            if source == .microphone {
                let granted = await AVAudioApplication.requestRecordPermission()
                guard startRequest == request else { return }
                guard granted else { throw MicrophoneCaptureError.permissionDenied }
            }
            try await startEngine(language: language)
            guard startRequest == request else { return }
            try startCapture()
            state.isListening = true
            setStatus("Listening (\(language.shortTitle)).")
        } catch {
            fail(error)
        }
    }

    func stop() {
        startRequest += 1
        stopCapture()
        stopEngine()
        assembler.flushAll()
        state.isListening = false
        syncTranscript()
        setStatus("Stopped.")
    }

    func switchLanguage(to language: TranscriptionLanguage) async {
        guard language != self.language else { return }
        self.language = language
        guard state.isListening else { return }
        stopEngine()
        assembler.flushAll()
        syncTranscript()
        do {
            try await startEngine(language: language)
            setStatus("Listening (\(language.shortTitle)).")
        } catch {
            fail(error)
        }
    }

    /// Manual hint: close the paragraph being spoken so the hint sees it.
    /// Waits briefly for the analyzer to finalize the volatile text; closing
    /// it directly would duplicate it when its final arrives later.
    func commitLiveText() async {
        if !assembler.volatileText.isEmpty {
            engine?.finalize()
            for _ in 0..<10 where !assembler.volatileText.isEmpty {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        closeQuietParagraph()
    }

    func clear() {
        assembler.reset()
        syncTranscript()
    }

    /// System audio only. Rebuilds just the capture; the recognizer and the
    /// paragraph being spoken carry on.
    func setAnchorsToOutputDevice(_ anchored: Bool) {
        guard anchored != anchorsToOutputDevice else { return }
        anchorsToOutputDevice = anchored
        guard source == .system, state.isListening else { return }
        stopCapture()
        do {
            try startCapture()
        } catch {
            fail(error)
        }
    }

    // MARK: - Capture

    private func startCapture() throws {
        let audioHandler: (AVAudioPCMBuffer) -> Void = { [feedSlot, levelMeter] buffer in
            levelMeter.record(buffer)
            feedSlot.feed?.append(buffer)
        }
        captureGeneration += 1
        let current = captureGeneration
        let failureHandler: (Error) -> Void = { [weak self] error in
            Task { @MainActor in
                guard let self, self.captureGeneration == current else { return }
                self.fail(error)
            }
        }
        switch source {
        case .system:
            try tapCapture.start(
                anchorsToOutputDevice: anchorsToOutputDevice,
                audioHandler: audioHandler,
                failureHandler: failureHandler
            )
        case .microphone:
            try micCapture.start(
                echoCancellation: usesEchoCancellation,
                audioHandler: audioHandler,
                failureHandler: failureHandler
            )
        }
    }

    private func stopCapture() {
        captureGeneration += 1
        switch source {
        case .system: tapCapture.stop()
        case .microphone: micCapture.stop()
        }
    }

    // MARK: - Engine

    func startEngine(language: TranscriptionLanguage) async throws {
        generation += 1
        let current = generation
        assembler.setLanguage(language)

        let engine = SpeechAnalyzerEngine()
        engine.onUpdate = { [weak self] update in
            guard let self, self.generation == current else { return }
            self.handle(update)
        }
        engine.onError = { [weak self] error in
            guard let self, self.generation == current else { return }
            self.fail(error)
        }
        setStatus("Preparing on-device speech model...")
        try await engine.start(language: language)
        guard generation == current else {
            engine.stop()
            return
        }
        self.engine = engine
        feedSlot.feed = engine.feed
    }

    private func stopEngine() {
        generation += 1
        feedSlot.feed = nil
        engine?.stop()
        engine = nil
        quietTask?.cancel()
        finalizeFallbackTask?.cancel()
        awaitingQuietCommit = false
    }

    private func handle(_ update: SpeechAnalyzerEngine.Update) {
        lastRecognizerUpdateAt = Date()
        if update.isFinal {
            assembler.acceptFinal(update.text)
            if awaitingQuietCommit, assembler.volatileText.isEmpty {
                closeQuietParagraph()
            }
        } else {
            assembler.acceptVolatile(update.text)
            awaitingQuietCommit = false
            finalizeFallbackTask?.cancel()
        }
        syncTranscript()
        scheduleQuietCheck()
    }

    private func scheduleQuietCheck(after delay: Duration? = nil) {
        quietTask?.cancel()
        let interval = delay ?? quietInterval
        quietTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.speakerWentQuiet()
        }
    }

    private func speakerWentQuiet() {
        guard assembler.hasPendingText else { return }
        let gap = Date().timeIntervalSince(lastRecognizerUpdateAt)
        if levelMeter.secondsSinceLoudAudio < audioQuietSeconds, gap < forcedQuietGap {
            // Audio is still active: the recognizer is just lagging. Re-check.
            scheduleQuietCheck(after: .milliseconds(300))
            return
        }
        if assembler.volatileText.isEmpty {
            closeQuietParagraph()
            return
        }
        awaitingQuietCommit = true
        engine?.finalize()
        finalizeFallbackTask?.cancel()
        let delay = finalizeFallbackDelay
        finalizeFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.awaitingQuietCommit else { return }
            self.closeQuietParagraph()
        }
    }

    private func closeQuietParagraph() {
        awaitingQuietCommit = false
        finalizeFallbackTask?.cancel()
        assembler.commitFinalized()
        syncTranscript()
    }

    // MARK: - State

    private func syncTranscript() {
        state.paragraphs = assembler.paragraphs
        state.partialTranscript = assembler.liveText
        onStateChange?(state)
    }

    private func setStatus(_ text: String) {
        state.statusText = text
        onStateChange?(state)
    }

    func clearError() {
        lastFailure = nil
        state.lastError = nil
    }

    private func fail(_ error: Error) {
        startRequest += 1
        lastFailure = error
        stopCapture()
        stopEngine()
        assembler.flushAll()
        state.isListening = false
        state.lastError = error.localizedDescription
        syncTranscript()
        setStatus("Stopped with an error.")
    }

    private func ensureSpeechPermission() async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw SpeechEngineError.speechDenied }
    }
}

/// Tracks when the captured audio was last above the speech floor. Written
/// on the audio queue, read on the main actor.
final class AudioLevelMeter: @unchecked Sendable {
    // ponytail: fixed floor; meeting audio at normal volume sits well above it
    // while speaking. Make it adaptive if quiet calls never register as loud.
    private static let speechRMS: Float = 0.005
    private let lastLoud = OSAllocatedUnfairLock(initialState: Date.distantPast)

    func record(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
        if rms >= Self.speechRMS {
            lastLoud.withLock { $0 = Date() }
        }
    }

    var secondsSinceLoudAudio: TimeInterval {
        Date().timeIntervalSince(lastLoud.withLock { $0 })
    }
}
