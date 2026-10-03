import Foundation

/// Prompt text for the two LLM calls. The system prompt depends only on the
/// knowledge folder, never on the request, so OpenAI's prefix cache can reuse
/// it; everything per-request lives in the user message.
enum MeetingPrompts {
    static func translationSystem(_ knowledge: MeetingKnowledge) -> String {
        """
        You are a professional interpreter for live business meetings. Translate the TARGET segment of a meeting transcript into natural Simplified Chinese.

        Rules:
        - Output only the Chinese translation of TARGET, always in Simplified Chinese. Never answer with Japanese or English sentences, not even a cleaned-up version of TARGET. No notes, labels, quotes or romanization.
        - The transcript comes from live speech recognition: it may contain misrecognized words, missing punctuation and sentence fragments. Use CONTEXT (earlier segments, not to be translated) and the meeting background to recover what the speaker meant. Do not translate an obvious misrecognition literally, and do not add information that was not said.
        - Keep proper nouns, product names and terms consistent with the meeting background. Keep English technical terms that Chinese engineers normally leave untranslated (API, PR, RAG, ...).
        - Be concise, like a live interpreter: drop fillers (えーと, なんか, まあ, um, like), false starts, repetitions and self-corrections. Keep every piece of actual content: facts, numbers, names, requests, opinions and their reasons.
        - Preserve the speaker's intent, including polite or indirect phrasing, in short natural Chinese rather than word-for-word.
        - If TARGET is only a filler or backchannel, output a short Chinese equivalent.
        - If TARGET ends with an unfinished sentence, end your translation after the last complete sentence. Do not translate the unfinished tail and do not add an ellipsis; the next segment will cover it. If TARGET has no complete sentence at all, translate it as is.
        - If the last CONTEXT segment ended with an unfinished sentence that TARGET continues, begin with the translation of that whole sentence, including its start from CONTEXT.
        \(extraInstructions(knowledge))
        [MEETING BACKGROUND]
        \(background(knowledge))
        """
    }

    static func translationUser(text: String, context: [String], language: TranscriptionLanguage) -> String {
        var lines = ["Source language: \(language.promptName)"]
        let context = context.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !context.isEmpty {
            lines.append("CONTEXT:")
            lines += context
        }
        lines.append("TARGET:")
        lines.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        // Ending on the source text invites the model to continue in that
        // language; the last line restates the output language.
        lines.append("Translate TARGET into Simplified Chinese.")
        return lines.joined(separator: "\n")
    }

    static func hintSystem(_ knowledge: MeetingKnowledge) -> String {
        """
        You are a discreet real-time meeting assistant for the user. Someone in the meeting has just addressed the user by name, or the user asked for help. From the recent transcript, work out what they want from the user (an opinion, a status update, an answer, a confirmation, a decision) and give the user a reply hint they can glance at in a few seconds.

        Output exactly this plain-text layout, no markdown headings:
        对方在问：<one short Chinese sentence>
        要点：
        - <2-3 concrete Chinese bullets>
        可以这样说：
        <1-3 sentences in the meeting language, natural spoken business register, first person, ready to say as is>

        Rules:
        - 对方在问 and 要点 are always written in Simplified Chinese, even when the meeting is in Japanese or English. Only 可以这样说 uses the meeting language.
        - The transcript is live speech recognition and may contain misrecognized words; infer the intended meaning from context. Lines starting with [Me] are what the user already said; other lines are the other participants, without names. Do not suggest repeating what the user already said; build on it, and if the user has already answered, say so in 对方在问 and keep 可以这样说 to a short follow-up.
        - Ground the hint in what was actually discussed and in the meeting background. Never invent facts, numbers, decisions or commitments the user has not made. When the needed facts are unknown, suggest an honest move instead: confirm the premise, ask a clarifying question, or say you will check and follow up.
        - If they ask whether the user has questions, concerns or anything unclear, draw on the whole transcript: point to 1-2 concrete items from the discussion worth confirming (a date, a number, an owner, a dependency), or a short thanks if nothing stands out.
        - If the name was only mentioned (talking about the user, not to them) and no reply is expected, say so in 对方在问 and write （无需回应） under 可以这样说.
        - Keep it short.
        \(extraInstructions(knowledge))
        [MEETING BACKGROUND]
        \(background(knowledge))
        """
    }

    static func hintUser(transcript: [String], language: TranscriptionLanguage, userName: String) -> String {
        var lines = ["Meeting language: \(language.promptName)"]
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            lines.append("The user is addressed as: \(name)")
        }
        lines.append("Recent transcript (oldest first; [Me] marks the user's own words; the user was addressed near the end):")
        lines += transcript
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "- \($0)" }
        return lines.joined(separator: "\n")
    }

    static func hintLine(_ text: String, isMine: Bool) -> String {
        isMine ? "[Me] \(text)" : text
    }

    /// The newest paragraphs whose total length fits `characterLimit`,
    /// oldest first. The newest one is always kept, even if it is longer.
    static func hintTranscript(_ paragraphs: [String], characterLimit: Int) -> [String] {
        var used = 0
        var kept: [String] = []
        for paragraph in paragraphs.reversed() {
            guard kept.isEmpty || used + paragraph.count <= characterLimit else { break }
            used += paragraph.count
            kept.append(paragraph)
        }
        return kept.reversed()
    }

    private static func background(_ knowledge: MeetingKnowledge) -> String {
        knowledge.background.isEmpty ? "(none provided)" : knowledge.background
    }

    private static func extraInstructions(_ knowledge: MeetingKnowledge) -> String {
        knowledge.instructions.isEmpty ? "" : "\n[ADDITIONAL INSTRUCTIONS]\n\(knowledge.instructions)\n"
    }
}

/// Cleans meeting translations after a paragraph boundary cut a sentence.
///
/// The translation model sometimes renders an unfinished trailing half
/// sentence as "要是你……" even when told to skip it, while the next
/// paragraph's translation already covers the whole sentence. Dropping an
/// ellipsis-ended trailing fragment after at least one complete sentence
/// removes the dangling half without losing content.
enum MeetingTranslationCleanup {
    private static let sentenceEnders: Set<Character> = ["。", "！", "？", "!", "?"]

    // Above these shares the "translation" is mostly the source language.
    private static let kanaShareLimit = 0.3
    private static let latinShareLimit = 0.5

    /// True when the output is mostly in the source language. Chinese never
    /// needs kana, and keeps English only for a few terms (API, PR).
    static func isUntranslated(_ text: String, source: TranscriptionLanguage) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let matching: Int
        switch source {
        case .japanese:
            // Hiragana and katakana, without the long-vowel mark and middle dot
            // that Chinese text sometimes borrows.
            matching = letters.filter { (0x3041...0x30FA).contains($0.value) }.count
            return Double(matching) / Double(letters.count) >= kanaShareLimit
        case .english:
            matching = letters.filter { $0.isASCII }.count
            return Double(matching) / Double(letters.count) >= latinShareLimit
        }
    }

    static func trimmingDanglingTail(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("…") || trimmed.hasSuffix("...") else { return text }
        guard let lastEnder = trimmed.lastIndex(where: { sentenceEnders.contains($0) }) else { return text }
        return String(trimmed[...lastEnder])
    }
}
