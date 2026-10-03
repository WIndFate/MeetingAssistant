import Foundation

/// One saved meeting: every paragraph with its translation and reply hints.
struct MeetingRecord: Codable, Identifiable, Equatable {
    struct Entry: Codable, Equatable {
        var text: String
        var isMine = false
        var translation: String
        var hints: [String]
    }

    let id: UUID
    let startedAt: Date
    var endedAt: Date
    var entries: [Entry]

    static func entries(from turns: [MeetingTurn]) -> [Entry] {
        turns.map { turn in
            Entry(
                text: turn.text,
                isMine: turn.isMine,
                translation: turn.translation,
                hints: turn.archivedHints + (turn.hint.isEmpty ? [] : [turn.hint])
            )
        }
    }

    /// Plain-text export used by Copy in both the panel and the history window.
    static func plainText(_ entries: [Entry]) -> String {
        entries.map { entry in
            var lines = ["\(entry.isMine ? "Me" : "Speaker"): \(entry.text)"]
            if !entry.translation.isEmpty { lines.append("中文: \(entry.translation)") }
            lines += entry.hints.map { "Hint: \($0)" }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    func contains(_ query: String) -> Bool {
        entries.contains {
            $0.text.localizedCaseInsensitiveContains(query)
                || $0.translation.localizedCaseInsensitiveContains(query)
        }
    }
}

extension MeetingRecord.Entry {
    private enum CodingKeys: String, CodingKey {
        case text, isMine, translation, hints
    }

    // Records saved before the microphone existed have no isMine key.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        isMine = try container.decodeIfPresent(Bool.self, forKey: .isMine) ?? false
        translation = try container.decode(String.self, forKey: .translation)
        hints = try container.decode([String].self, forKey: .hints)
    }
}
