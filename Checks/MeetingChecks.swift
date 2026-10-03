import CoreAudio
import Foundation

@main
struct MeetingChecks {
    static func main() {
        checkCallDetector()
        checkTranslationCleanup()
        checkTranscriptAssembler()
        checkStreamParser()
        checkKnowledgeAndPrompts()
        checkMeetingHistory()
        checkEchoCancellationChoice()
        print("All meeting checks passed")
    }

    static func checkCallDetector() {
        let aliases = MeetingCallDetector.defaultAliases
        for text in ["セキさん、どう思いますか", "石さんはどうですか", "席 さんいかがですか", "Seki, what do you think?", "seki-san any thoughts"] {
            precondition(MeetingCallDetector.containsCall(text, aliases: aliases), "Missed call: \(text)")
        }
        for text in ["セキュリティの話です", "会議の席で決めましょう", "石を投げる", ""] {
            precondition(!MeetingCallDetector.containsCall(text, aliases: aliases), "False call: \(text)")
        }
        precondition(MeetingCallDetector.aliases(from: "田中さん、 Tanaka ") == ["田中さん", "Tanaka"])
        precondition(MeetingCallDetector.aliases(from: "  ") == aliases)
    }

    static func checkTranslationCleanup() {
        precondition(MeetingTranslationCleanup.trimmingDanglingTail("也没法正常进行。要是你……") == "也没法正常进行。")
        precondition(MeetingTranslationCleanup.trimmingDanglingTail("下周发布。如果...") == "下周发布。")
        precondition(MeetingTranslationCleanup.trimmingDanglingTail("要是你……") == "要是你……")
        precondition(MeetingTranslationCleanup.trimmingDanglingTail("好的，谢谢。") == "好的，谢谢。")
    }

    static func checkTranscriptAssembler() {
        var japanese = TranscriptAssembler(language: .japanese)
        japanese.acceptVolatile("今週の")
        precondition(japanese.liveText == "今週の")
        // A final replaces its volatile preview; the live line never rewinds.
        japanese.acceptFinal("今週のリリースは")
        japanese.acceptVolatile("厳しい")
        precondition(japanese.liveText == "今週のリリースは厳しい")
        // Quiet commit closes only finalized text; volatile stays live.
        precondition(japanese.commitFinalized())
        precondition(japanese.paragraphs == ["今週のリリースは"])
        precondition(japanese.liveText == "厳しい")

        // Continuous speech: the recognizer keeps one growing volatile text.
        // Paragraphs close at sentence ends without waiting for a final.
        var monologue = TranscriptAssembler(language: .japanese)
        precondition(!monologue.acceptVolatile("今週のリリースは厳しいです。検証環境の"), "Closed before a sentence or two")
        let first = "今週のリリースは厳しいです。検証環境のテストがまだ終わっていないので、来週にずらしたいと思います。"
        precondition(monologue.acceptVolatile(first + "火曜"))
        precondition(monologue.paragraphs == [first], "Unexpected cut: \(monologue.paragraphs)")
        precondition(monologue.liveText == "火曜")
        // Growing volatile text keeps the committed part out of the live line.
        monologue.acceptVolatile(first + "火曜はどうですか")
        precondition(monologue.liveText == "火曜はどうですか")
        // A revision inside the committed part still strips at the sentence end.
        monologue.acceptVolatile(first.replacingOccurrences(of: "終わっていない", with: "終わってない") + "火曜はどうですか")
        precondition(monologue.liveText == "火曜はどうですか", "Revision leaked: \(monologue.liveText)")
        // The final for the whole range contributes only the uncommitted rest.
        monologue.acceptFinal(first + "火曜はどうですか。")
        precondition(monologue.paragraphs == [first] && monologue.finalizedPending == "火曜はどうですか。")
        precondition(monologue.commitFinalized() && monologue.paragraphs.count == 2)
        // The next range starts clean.
        monologue.acceptVolatile("はい")
        precondition(monologue.liveText == "はい")

        // Run-on speech without a sentence end is still bounded, at a clause mark.
        var runaway = TranscriptAssembler(language: .japanese)
        let clause = String(repeating: "い", count: 70) + "、"
        precondition(!runaway.acceptVolatile(clause + String(repeating: "う", count: 40)))
        precondition(runaway.acceptVolatile(clause + String(repeating: "う", count: 50)))
        precondition(runaway.paragraphs == [clause] && runaway.liveText == String(repeating: "う", count: 50))

        var english = TranscriptAssembler(language: .english)
        precondition(!english.acceptVolatile("So the release slips."), "English closed too early")

        // Noise-floor single characters never become paragraphs.
        var noise = TranscriptAssembler(language: .japanese)
        noise.acceptFinal("あ")
        precondition(!noise.commitFinalized() && noise.paragraphs.isEmpty)

        english = TranscriptAssembler(language: .english)
        english.acceptFinal("So the release")
        english.acceptVolatile("slips to Tuesday")
        precondition(english.liveText == "So the release slips to Tuesday")
        english.flushAll()
        precondition(english.paragraphs == ["So the release slips to Tuesday"])
    }

    static func checkStreamParser() {
        precondition(OpenAIStreamParser.parse(line: #"data: {"choices":[{"delta":{"content":"你好"}}]}"#) == .content("你好"))
        precondition(OpenAIStreamParser.parse(line: "data: [DONE]") == .done)
        precondition(OpenAIStreamParser.parse(line: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#) == .ignore)
        precondition(OpenAIStreamParser.parse(line: "") == .ignore)
    }

    static func checkKnowledgeAndPrompts() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-checks-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try! "second".write(to: folder.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try! "first".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try! "docs".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try! "Be brief.".write(to: folder.appendingPathComponent("instructions.md"), atomically: true, encoding: .utf8)

        let knowledge = MeetingKnowledge.load(from: folder)
        precondition(knowledge == MeetingKnowledge(background: "first\n\nsecond", instructions: "Be brief."))
        precondition(MeetingKnowledge.load(from: folder.appendingPathComponent("missing")).background.isEmpty)

        let system = MeetingPrompts.translationSystem(knowledge)
        precondition(system.contains("first") && system.contains("[ADDITIONAL INSTRUCTIONS]\nBe brief."))
        precondition(MeetingPrompts.hintSystem(knowledge).contains("对方在问"))

        let user = MeetingPrompts.translationUser(text: "来週です", context: ["前の話", " "], language: .japanese)
        precondition(user == "Source language: Japanese\nCONTEXT:\n前の話\nTARGET:\n来週です")
        let hint = MeetingPrompts.hintUser(transcript: ["一つ目", "セキさん、どう？"], language: .japanese, userName: "セキさん")
        precondition(hint.contains("addressed as: セキさん") && hint.hasSuffix("- セキさん、どう？"))

        // Hint context keeps the newest paragraphs within the character cap.
        precondition(MeetingPrompts.hintTranscript(["aaaa", "bb", "cc"], characterLimit: 4) == ["bb", "cc"])
        precondition(MeetingPrompts.hintTranscript(["aaaa", "bb", "cc"], characterLimit: 100) == ["aaaa", "bb", "cc"])
        precondition(MeetingPrompts.hintTranscript(["old", "a very long latest paragraph"], characterLimit: 5) == ["a very long latest paragraph"])
        precondition(MeetingPrompts.hintTranscript([], characterLimit: 5).isEmpty)
        precondition(MeetingPrompts.hintLine("了解です", isMine: true) == "[Me] 了解です")
        precondition(MeetingPrompts.hintLine("どうですか", isMine: false) == "どうですか")
        precondition(MeetingPrompts.hintSystem(knowledge).contains("[Me]"))
    }

    static func checkMeetingHistory() {
        var turn = MeetingTurn(text: "来週です")
        turn.translation = "下周。"
        turn.archivedHints = ["旧提示"]
        turn.hint = "新提示"
        let entries = MeetingRecord.entries(from: [turn, MeetingTurn(text: "はい")])
        precondition(entries[0] == MeetingRecord.Entry(text: "来週です", translation: "下周。", hints: ["旧提示", "新提示"]))
        precondition(MeetingRecord.plainText(entries) == "Speaker: 来週です\n中文: 下周。\nHint: 旧提示\nHint: 新提示\n\nSpeaker: はい")

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        precondition(MeetingHistoryStore.loadAll(from: folder).isEmpty, "Missing folder must read as empty")

        // Whole seconds: ISO 8601 storage drops fractions.
        let older = MeetingRecord(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_790_000_000), endedAt: Date(timeIntervalSince1970: 1_790_000_600), entries: entries)
        var newer = MeetingRecord(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_790_090_000), endedAt: Date(timeIntervalSince1970: 1_790_090_060), entries: [])
        try! MeetingHistoryStore.save(older, in: folder)
        try! MeetingHistoryStore.save(newer, in: folder)
        // Saving again overwrites the same meeting's file.
        newer.entries = entries
        try! MeetingHistoryStore.save(newer, in: folder)
        try! "not json".write(to: folder.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)

        // Records saved before the microphone existed decode as other participants.
        let legacy = #"{"text":"はい","translation":"好","hints":[]}"#
        let decoded = try! JSONDecoder().decode(MeetingRecord.Entry.self, from: Data(legacy.utf8))
        precondition(decoded == MeetingRecord.Entry(text: "はい", translation: "好", hints: []) && !decoded.isMine)
        var mine = MeetingTurn(text: "了解です", isMine: true)
        mine.translation = "明白。"
        precondition(MeetingRecord.plainText(MeetingRecord.entries(from: [mine])) == "Me: 了解です\n中文: 明白。")

        let loaded = MeetingHistoryStore.loadAll(from: folder)
        precondition(loaded == [newer, older], "History must round-trip newest first")
        precondition(loaded[0].contains("下周") && loaded[0].contains("来週") && !loaded[0].contains("再来年"))
    }

    static func checkEchoCancellationChoice() {
        let headphones: UInt32 = 0x6864_706E // 'hdpn'
        let speakers: UInt32 = 0x6973_706B   // 'ispk'
        precondition(MicrophoneCaptureService.needsEchoCancellation(transportType: kAudioDeviceTransportTypeBuiltIn, dataSource: speakers))
        precondition(!MicrophoneCaptureService.needsEchoCancellation(transportType: kAudioDeviceTransportTypeBuiltIn, dataSource: headphones))
        precondition(!MicrophoneCaptureService.needsEchoCancellation(transportType: kAudioDeviceTransportTypeBluetooth, dataSource: nil))
        precondition(MicrophoneCaptureService.needsEchoCancellation(transportType: kAudioDeviceTransportTypeHDMI, dataSource: nil))
    }
}
