import AppKit
import Foundation

/// Saved meetings for the history window, grouped by day.
@MainActor
final class HistoryViewModel: ObservableObject {
    struct Day: Identifiable {
        let date: Date
        let records: [MeetingRecord]
        var id: Date { date }
    }

    @Published private(set) var records: [MeetingRecord] = []
    @Published var selection: MeetingRecord.ID?
    @Published var query = ""

    private let folder: URL

    init(folder: URL = MeetingHistoryStore.defaultFolder) {
        self.folder = folder
    }

    func reload() {
        records = MeetingHistoryStore.loadAll(from: folder)
        if !records.contains(where: { $0.id == selection }) {
            selection = records.first?.id
        }
    }

    var days: [Day] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let visible = query.isEmpty ? records : records.filter { $0.contains(query) }
        var days: [Day] = []
        for record in visible {
            let date = Calendar.current.startOfDay(for: record.startedAt)
            if days.last?.date == date {
                days[days.count - 1] = Day(date: date, records: days[days.count - 1].records + [record])
            } else {
                days.append(Day(date: date, records: [record]))
            }
        }
        return days
    }

    var selectedRecord: MeetingRecord? {
        records.first { $0.id == selection }
    }

    func copy(_ record: MeetingRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MeetingRecord.plainText(record.entries), forType: .string)
    }

    func revealInFinder(_ record: MeetingRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([MeetingHistoryStore.fileURL(for: record, in: folder)])
    }

    /// Trash rather than delete, so a mistaken click is recoverable.
    func moveToTrash(_ record: MeetingRecord) {
        do {
            try FileManager.default.trashItem(at: MeetingHistoryStore.fileURL(for: record, in: folder), resultingItemURL: nil)
        } catch {
            print("[HistoryViewModel] trash failed error=\(error.localizedDescription)")
        }
        reload()
    }
}
