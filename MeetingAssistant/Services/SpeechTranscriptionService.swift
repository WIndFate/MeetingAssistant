import Accelerate
import AVFoundation
import Foundation
import os
import Speech

/// System audio → Process Tap → SpeechAnalyzer → paragraphs.
///
/// Paragraph rules live in `TranscriptAssembler`, including mid-speech cuts
/// at sentence ends. This service only decides *when* the speaker went quiet
/// and then asks the analyzer to finalize, closing the paragraph once the
/// final arrives.
///
/// A recognizer gap alone is not silence: under CPU load the analyzer can go
/// over a second without an update while someone is still talking, which cut
/// mid-sentence fragments in a real run. Quiet therefore also requires the
/// audio itself to be quiet; a long gap closes regardless, so a very low
/// meeting volume cannot keep the last sentence open forever.
@MainActor
final class SpeechTranscriptionService {
    var onStateChange: ((TranscriptionState) -> Void)?
    private(set) var state = TranscriptionState()

    private let audioQueue = DispatchQueue(label: "MeetingAssistant.Audio")
    private lazy var capture = ProcessTapAudioCaptureService(callbackQueue: audioQueue)
    // Internal (not private) so a headless harness can feed recorded audio.
    let feedSlot = AudioFeedSlot()
    let levelMeter = AudioLevelMeter()
    private var engine: SpeechAnalyzerEngine?
    private var assembler = TranscriptAssembler(language: .japanese)
    private var language: TranscriptionLanguage = .japanese
    private var generation = 0

    private var quietTask: Task<Void, Never>?
    private var finalizeFallbackTask: Task<Void, Never>?
    private var awaitingQuietCommit = false

    // Volatile results stream every few hundred ms while someone talks.
    private let quietInterval: Duration = .milliseconds(1200)
    private let audioQuietSeconds: TimeInterval = 0.6
    // A gap this long closes the paragraph even if the audio is not quiet.
    private let forcedQuietGap: TimeInterval = 3.0
    private var lastRecognizerUpdateAt = Date()
    // If the analyzer sends no final after a finalize request, close the
    // paragraph with what is already final; volatile text stays live.
    private let finalizeFallbackDelay: Duration = .milliseconds(1500)

    func start(language: TranscriptionLanguage) async {
        guard !state.isListening else { return }
        self.language = language
        state.lastError = nil
        setStatus("Starting...")
        do {
            try await ensureSpeechPermission()
            try await startEngine(language: language)
            try capture.start(
                audioHandler: { [feedSlot, levelMeter] buffer in
                    levelMeter.record(buffer)
                    feedSlot.feed?.append(buffer)
                },
                failureHandler: { [weak self] error in
                    Task { @MainActor in
                        self?.fail(error)
                    }
                }
            )
            state.isListening = true
            setStatus("Listening (\(language.shortTitle)).")
        } catch {
            fail(error)
        }
    }

    func stop() {
        capture.stop()
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

    private func fail(_ error: Error) {
        capture.stop()
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
