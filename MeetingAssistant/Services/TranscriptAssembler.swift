import Foundation

/// Turns SpeechTranscriber results into short display paragraphs.
///
/// SpeechTranscriber reports the current audio range as volatile text that
/// keeps growing, and only emits a final for it when the speaker pauses; during
/// a monologue that can take minutes. Each paragraph is translated on its own,
/// so waiting for finals would mean one huge late translation.
///
/// Paragraphs are therefore cut at the text level, without disturbing the
/// recognizer (forcing `finalize(through:)` mid-speech cut words in half and
/// degraded later recognition in a real run):
/// - once the live text holds a sentence or two, everything up to the last
///   sentence end closes as a paragraph, and that part of the volatile text
///   is remembered as already committed;
/// - later volatile and final text for the same range has the committed part
///   stripped, so it is never shown or translated twice;
/// - the owner still calls `commitFinalized()` after the speaker goes quiet.
struct TranscriptAssembler {
    private(set) var paragraphs: [String] = []
    /// Final text since the last paragraph, with any committed prefix removed.
    private(set) var finalizedPending = ""
    /// Uncommitted part of the current volatile text.
    private(set) var volatileText = ""
    /// Part of the current range's volatile text already closed as paragraphs.
    private(set) var committedVolatilePrefix = ""

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

    /// Returns true when a paragraph closed mid-speech.
    @discardableResult
    mutating func acceptVolatile(_ text: String) -> Bool {
        let full = text.trimmingCharacters(in: .whitespacesAndNewlines)
        volatileText = stripCommitted(from: full)
        guard let cut = splitPoint(in: volatileText) else { return false }

        let characters = Array(volatileText)
        let head = String(characters[...cut])
        finalizedPending = Self.join(finalizedPending, head, joiner: joiner)
        commitFinalized()
        committedVolatilePrefix = String(full.prefix(full.count - (characters.count - cut - 1)))
        volatileText = String(characters[(cut + 1)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return true
    }

    /// Returns true when the final closed a paragraph.
    @discardableResult
    mutating func acceptFinal(_ text: String) -> Bool {
        let remainder = stripCommitted(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
        // A final ends its range; the next volatile text starts fresh.
        committedVolatilePrefix = ""
        finalizedPending = Self.join(finalizedPending, remainder, joiner: joiner)
        volatileText = ""
        let length = Self.meaningfulCharacterCount(finalizedPending)
        if (length >= softParagraphLength && endsSentence(finalizedPending)) || length >= hardParagraphLength {
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
        committedVolatilePrefix = ""
        commitFinalized()
    }

    mutating func reset() {
        paragraphs = []
        finalizedPending = ""
        volatileText = ""
        committedVolatilePrefix = ""
    }

    // MARK: - Splitting

    /// Offset in `text` of the character that ends the paragraph to close
    /// now, or nil to keep waiting.
    private func splitPoint(in text: String) -> Int? {
        let characters = Array(text)
        let pendingLength = Self.meaningfulCharacterCount(finalizedPending)
        let enders = characters.indices.filter { Self.sentenceEnders.contains(characters[$0]) }
        if let lastEnder = enders.last,
           pendingLength + Self.meaningfulCharacterCount(String(characters[...lastEnder])) >= softParagraphLength {
            return lastEnder
        }
        // Run-on speech without a sentence end: cut after the last clause
        // mark, or everything if there is none.
        guard pendingLength + Self.meaningfulCharacterCount(text) >= hardParagraphLength else { return nil }
        return characters.lastIndex(where: { Self.clauseMarks.contains($0) }) ?? characters.count - 1
    }

    /// Removes the already-committed part from a newer volatile or final text
    /// of the same range. The recognizer may still revise words inside that
    /// part, so when the text no longer starts with it verbatim, the cut moves
    /// to the sentence end nearest the committed length.
    private func stripCommitted(from text: String) -> String {
        guard !committedVolatilePrefix.isEmpty else { return text }
        if text.hasPrefix(committedVolatilePrefix) {
            return String(text.dropFirst(committedVolatilePrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let characters = Array(text)
        let target = committedVolatilePrefix.count - 1
        let candidates = characters.indices.filter {
            (Self.sentenceEnders.contains(characters[$0]) || Self.clauseMarks.contains(characters[$0]))
                && abs($0 - target) <= Self.revisionTolerance
        }
        let cut = candidates.min(by: { abs($0 - target) < abs($1 - target) })
            ?? min(target, characters.count - 1)
        guard cut >= 0 else { return text }
        return String(characters[(cut + 1)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func endsSentence(_ text: String) -> Bool {
        text.last.map { Self.sentenceEnders.contains($0) } ?? false
    }

    // MARK: - Helpers

    private static let sentenceEnders: Set<Character> = ["。", "？", "！", ".", "?", "!"]
    private static let clauseMarks: Set<Character> = ["、", ","]
    // How far a revised volatile text may shift the committed boundary.
    private static let revisionTolerance = 8

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
