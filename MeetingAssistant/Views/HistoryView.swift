import SwiftUI

/// Saved meetings: days and meetings on the left, the full transcript with
/// translations and reply hints on the right.
struct HistoryView: View {
    @ObservedObject var viewModel: HistoryViewModel
    @State private var pendingTrash: MeetingRecord?

    var body: some View {
        NavigationSplitView {
            List(selection: $viewModel.selection) {
                ForEach(viewModel.days) { day in
                    Section(dayTitle(day.date)) {
                        ForEach(day.records) { record in
                            HistoryRow(record: record)
                                .tag(record.id)
                        }
                    }
                }
            }
            .searchable(text: $viewModel.query, placement: .sidebar, prompt: "搜索原文或翻译")
            .overlay {
                if viewModel.records.isEmpty {
                    ContentUnavailableView(
                        "还没有会议记录",
                        systemImage: "clock",
                        description: Text("开始收听后，会议内容会自动保存在本机。")
                    )
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let record = viewModel.selectedRecord {
                HistoryDetailView(record: record)
                    .toolbar {
                        Button("复制全文", systemImage: "doc.on.doc") { viewModel.copy(record) }
                        Button("在 Finder 中显示", systemImage: "folder") { viewModel.revealInFinder(record) }
                        Button("移到废纸篓", systemImage: "trash") { pendingTrash = record }
                    }
            } else {
                ContentUnavailableView("选择一场会议", systemImage: "text.bubble")
            }
        }
        .confirmationDialog(
            "把这场会议记录移到废纸篓？",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            presenting: pendingTrash
        ) { record in
            Button("移到废纸篓", role: .destructive) { viewModel.moveToTrash(record) }
        }
        .preferredColorScheme(.dark)
    }
}

private struct HistoryRow: View {
    let record: MeetingRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(timeRange(record))
                .font(.system(size: 12, weight: .semibold))
            Text(record.entries.first?.text ?? "")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text("\(record.entries.count) 段")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

private struct HistoryDetailView: View {
    let record: MeetingRecord

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Text(dayTitle(record.startedAt) + "  " + timeRange(record))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(record.entries.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 6) {
                            MessageBubble(text: entry.text, style: .incoming, width: viewport.size.width) {
                                if !entry.translation.isEmpty {
                                    TranslationView(text: entry.translation, isLoading: false, error: nil)
                                }
                            }
                            ForEach(Array(entry.hints.enumerated()), id: \.offset) { _, hint in
                                HintBubble(text: hint, width: viewport.size.width)
                            }
                        }
                    }
                }
                .padding(16)
                .textSelection(.enabled)
            }
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
    }
}

// The UI is Chinese, so dates are too, whatever the system language.
private let chinese = Locale(identifier: "zh_Hans")

private func dayTitle(_ date: Date) -> String {
    date.formatted(.dateTime.year().month().day().weekday(.wide).locale(chinese))
}

private func timeRange(_ record: MeetingRecord) -> String {
    let time = Date.FormatStyle.dateTime.hour().minute().locale(chinese)
    return record.startedAt.formatted(time) + " – " + record.endedAt.formatted(time)
}
