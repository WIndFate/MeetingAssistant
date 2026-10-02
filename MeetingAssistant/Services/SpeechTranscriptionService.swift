import AVFoundation
import Foundation
import Speech

/// System audio → Process Tap → SpeechAnalyzer → paragraphs.
///
/// Paragraph rules live in `TranscriptAssembler`; this service only decides
/// *when* the speaker went quiet: no recognizer update for `quietInterval`
/// means the turn paused, so it asks the analyzer to finalize and closes the
/// paragraph once the final arrives.
@MainActor
final class SpeechTranscriptionService {
    var onStateChange: ((TranscriptionState) -> Void)?
    private(set) var state = TranscriptionState()

    private let audioQueue = DispatchQueue(label: "MeetingAssistant.Audio")
    private lazy var capture = ProcessTapAudioCaptureService(callbackQueue: audioQueue)
    private let feedSlot = AudioFeedSlot()
    private var engine: SpeechAnalyzerEngine?
    private var assembler = TranscriptAssembler(language: .japanese)
    private var language: TranscriptionLanguage = .japanese
    private var generation = 0

    private var quietTask: Task<Void, Never>?
    private var finalizeFallbackTask: Task<Void, Never>?
    private var awaitingQuietCommit = false

    // Volatile results stream every few hundred ms while someone talks.
    private let quietInterval: Duration = .milliseconds(1200)
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
                audioHandler: { [feedSlot] buffer in
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

    private func startEngine(language: TranscriptionLanguage) async throws {
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

    private func scheduleQuietCheck() {
        quietTask?.cancel()
        let interval = quietInterval
        quietTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.speakerWentQuiet()
        }
    }

    private func speakerWentQuiet() {
        guard assembler.hasPendingText else { return }
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
