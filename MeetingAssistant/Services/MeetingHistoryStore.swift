import Foundation

/// Meeting records on disk: one JSON file per meeting under Application
/// Support, outside the repository, so transcripts never end up in git.
enum MeetingHistoryStore {
    static let defaultFolder = URL.applicationSupportDirectory
        .appendingPathComponent("MeetingAssistant/History", isDirectory: true)

    static func save(_ record: MeetingRecord, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(record).write(to: fileURL(for: record, in: folder), options: .atomic)
    }

    /// Newest first. Unreadable files are skipped, not fatal.
    // ponytail: decodes every file on each open; index the folder if history grows to thousands of meetings.
    static func loadAll(from folder: URL) -> [MeetingRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let records = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(MeetingRecord.self, from: Data(contentsOf: $0)) }
        if records.count != files.count {
            print("[MeetingHistoryStore] skipped files=\(files.count - records.count)")
        }
        return records.sorted { $0.startedAt > $1.startedAt }
    }

    static func fileURL(for record: MeetingRecord, in folder: URL) -> URL {
        folder.appendingPathComponent(fileNameFormatter.string(from: record.startedAt) + ".json")
    }

    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
