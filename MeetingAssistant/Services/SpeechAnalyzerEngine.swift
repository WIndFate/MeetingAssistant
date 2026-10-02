@preconcurrency import AVFoundation
import Foundation
import os
import Speech

/// macOS 26 SpeechAnalyzer + SpeechTranscriber, on-device.
///
/// `start` / `stop` / `finalize` run on the main actor. Audio goes through
/// `AudioFeed`, which the Process Tap callback calls directly on the audio
/// queue, so format conversion never touches the main thread.
@MainActor
final class SpeechAnalyzerEngine {
    struct Update {
        let text: String
        let isFinal: Bool
    }

    var onUpdate: ((Update) -> Void)?
    var onError: ((Error) -> Void)?

    private(set) var feed: AudioFeed?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?

    func start(language: TranscriptionLanguage) async throws {
        stop()

        let locale = Locale(identifier: language.localeIdentifier)
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw SpeechEngineError.unsupportedLocale(language.localeIdentifier)
        }

        // fastResults: stream volatile text while the speaker is still
        // talking instead of batching it until near-final.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )

        // One-time on-device model download for this locale, if missing.
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechEngineError.noAudioFormat
        }
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    self?.onUpdate?(Update(text: String(result.text.characters), isFinal: result.isFinal))
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.onError?(error)
            }
        }

        try await analyzer.start(inputSequence: inputSequence)
        self.analyzer = analyzer
        feed = AudioFeed(continuation: continuation, format: format)
    }

    /// Ask the analyzer to finalize everything heard so far without ending
    /// the session; the pending volatile text arrives as a final result.
    func finalize() {
        guard let analyzer else { return }
        Task {
            try? await analyzer.finalize(through: nil)
        }
    }

    func stop() {
        resultsTask?.cancel()
        resultsTask = nil
        feed?.finish()
        feed = nil
        if let analyzer {
            Task {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }
        }
        analyzer = nil
    }
}

/// Converts captured buffers to the analyzer's format and feeds them in.
/// Called only from the serial audio queue.
final class AudioFeed: @unchecked Sendable {
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    init(continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) {
        self.continuation = continuation
        self.format = format
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        if buffer.format == format {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converterInputFormat = buffer.format
        }
        guard let converter else { return }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = max(AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1), 1)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }

        var provided = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, statusPointer in
            if provided {
                statusPointer.pointee = .noDataNow
                return nil
            }
            provided = true
            statusPointer.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: output))
    }

    func finish() {
        continuation.finish()
    }
}

/// Hands the current feed to the audio queue; swapped on language changes.
final class AudioFeedSlot: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<AudioFeed?>(initialState: nil)

    var feed: AudioFeed? {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

enum SpeechEngineError: LocalizedError {
    case unsupportedLocale(String)
    case noAudioFormat
    case speechDenied

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let locale):
            return "On-device speech recognition does not support \(locale) on this Mac."
        case .noAudioFormat:
            return "SpeechAnalyzer did not report a usable audio format."
        case .speechDenied:
            return "Speech Recognition permission denied. Enable Meeting Assistant in System Settings > Privacy & Security > Speech Recognition."
        }
    }
}
