import Foundation

/// Prompt text for the two LLM calls. The system prompt depends only on the
/// knowledge folder, never on the request, so OpenAI's prefix cache can reuse
/// it; everything per-request lives in the user message.
enum MeetingPrompts {
    static func translationSystem(_ knowledge: MeetingKnowledge) -> String {
        """
        You are a professional interpreter for live business meetings. Translate the TARGET segment of a meeting transcript into natural Simplified Chinese.

        Rules:
        - Output only the Chinese translation of TARGET. No notes, labels, quotes or romanization.
        - The transcript comes from live speech recognition: it may contain misrecognized words, missing punctuation and sentence fragments. Use CONTEXT (earlier segments, not to be translated) and the meeting background to recover what the speaker meant. Do not translate an obvious misrecognition literally, and do not add information that was not said.
        - Keep proper nouns, product names and terms consistent with the meeting background. Keep English technical terms that Chinese engineers normally leave untranslated (API, PR, RAG, ...).
        - Preserve the speaker's tone and intent, including polite or indirect phrasing, in natural Chinese rather than word-for-word.
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
        - The transcript is live speech recognition without speaker labels and may contain misrecognized words; infer the intended meaning from context.
        - Ground the hint in what was actually discussed and in the meeting background. Never invent facts, numbers, decisions or commitments the user has not made. When the needed facts are unknown, suggest an honest move instead: confirm the premise, ask a clarifying question, or say you will check and follow up.
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
        lines.append("Recent transcript (oldest first; the user was addressed near the end):")
        lines += transcript
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "- \($0)" }
        return lines.joined(separator: "\n")
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

    static func trimmingDanglingTail(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("…") || trimmed.hasSuffix("...") else { return text }
        guard let lastEnder = trimmed.lastIndex(where: { sentenceEnders.contains($0) }) else { return text }
        return String(trimmed[...lastEnder])
    }
}
