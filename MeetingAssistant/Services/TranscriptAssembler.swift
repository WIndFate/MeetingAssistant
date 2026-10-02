import Foundation

/// Turns SpeechTranscriber results into display paragraphs.
///
/// SpeechTranscriber reports each audio range first as volatile text, then as
/// one final result; ranges never overlap. So the live line is simply
/// "finals since the last paragraph" + "current volatile text", and it can
/// never shrink or rewind when a final replaces its volatile preview.
///
/// Paragraphs close in two ways:
/// - the owner calls `commitFinalized()` after the speaker goes quiet;
/// - a final arrives once the paragraph holds a sentence or two and ends a
///   sentence (or has run far too long without one). Closing only on a final
///   keeps every cut on a phrase boundary, so a sentence is never split
///   mid-word the way a fixed time window splits it.
///
/// Paragraphs are deliberately short: each one is translated on its own, so
/// a one-or-two-sentence paragraph gives a translation within seconds of the
/// speaker finishing that sentence, and one the user can read at a glance.
struct TranscriptAssembler {
    private(set) var paragraphs: [String] = []
    private(set) var finalizedPending = ""
    private(set) var volatileText = ""

    private(set) var softParagraphLength = 40
    private(set) var hardParagraphLength = 120
    private(set) var joiner = ""

    init(language: TranscriptionLanguage) {
        setLanguage(language)
    }

    /// Paragraphs already on screen are kept; only new text uses the rules.
    mutating func setLanguage(_ language: TranscriptionLanguage) {
        // About one or two sentences. Japanese packs far more content per
        // character than English. The hard limit only bounds run-on speech
        // that never produces a sentence ending.
        softParagraphLength = language == .english ? 120 : 40
        hardParagraphLength = softParagraphLength * 3
        joiner = language == .english ? " " : ""
    }

    var liveText: String {
        Self.join(finalizedPending, volatileText, joiner: joiner)
    }

    var hasPendingText: Bool {
        !finalizedPending.isEmpty || !volatileText.isEmpty
    }

    mutating func acceptVolatile(_ text: String) {
        volatileText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns true when the final closed a long paragraph.
    @discardableResult
    mutating func acceptFinal(_ text: String) -> Bool {
        finalizedPending = Self.join(
            finalizedPending,
            text.trimmingCharacters(in: .whitespacesAndNewlines),
            joiner: joiner
        )
        volatileText = ""
        let length = Self.meaningfulCharacterCount(finalizedPending)
        let endsSentence = finalizedPending.last.map { Self.sentenceEnders.contains($0) } ?? false
        if (length >= softParagraphLength && endsSentence) || length >= hardParagraphLength {
            return commitFinalized()
        }
        return false
    }

    /// Closes the paragraph with everything finalized so far. Volatile text
    /// stays live: its final will arrive later and join the next paragraph.
    /// Returns true when a paragraph was added.
    @discardableResult
    mutating func commitFinalized() -> Bool {
        let text = finalizedPending
        finalizedPending = ""
        // A lone character after silence is a noise-floor hallucination.
        guard Self.meaningfulCharacterCount(text) >= 2 else { return false }
        paragraphs.append(text)
        return true
    }

    /// Stop / language switch: keep whatever was heard, finalized or not.
    mutating func flushAll() {
        finalizedPending = liveText
        volatileText = ""
        commitFinalized()
    }

    mutating func reset() {
        paragraphs = []
        finalizedPending = ""
        volatileText = ""
    }

    private static let sentenceEnders: Set<Character> = ["。", "？", "！", ".", "?", "!"]

    static func meaningfulCharacterCount(_ text: String) -> Int {
        text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        }.count
    }

    private static func join(_ lhs: String, _ rhs: String, joiner: String) -> String {
        if lhs.isEmpty { return rhs }
        if rhs.isEmpty { return lhs }
        return lhs + joiner + rhs
    }
}
