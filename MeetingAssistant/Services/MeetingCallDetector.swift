import Foundation

/// Detects when a meeting participant addresses the user by name.
///
/// Deterministic local matching over an alias list. Speech recognition writes
/// the same spoken name as many homophones (セキ / 石 / 関 / 席), so every
/// Japanese alias carries its honorific: a bare "セキ" would match "セキュリティ"
/// and a bare "席" would match "会議の席". Override the list with a comma
/// separated list in Settings; the first entry is also the name shown to the
/// reply-hint model.
enum MeetingCallDetector {
    static let defaultAliases = ["セキさん", "せきさん", "石さん", "関さん", "席さん", "積さん", "seki"]

    /// Parses the Settings field; falls back to the defaults when empty.
    static func aliases(from raw: String) -> [String] {
        let custom = raw
            .split(whereSeparator: { $0 == "," || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return custom.isEmpty ? defaultAliases : custom
    }

    static func containsCall(_ text: String, aliases: [String]) -> Bool {
        let haystack = normalized(text)
        guard !haystack.isEmpty else { return false }
        return aliases.contains { alias in
            let needle = normalized(alias)
            return !needle.isEmpty && haystack.contains(needle)
        }
    }

    // Recognizers insert spaces or hyphens inconsistently ("セキ さん",
    // "Seki-san"), so both sides drop them before matching.
    static func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && $0 != "-" }
    }
}
