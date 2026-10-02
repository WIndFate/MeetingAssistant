import Foundation

/// One committed transcript paragraph with its translation and any reply
/// hints generated while it was the latest paragraph.
struct MeetingTurn: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var translation = ""
    var isTranslating = false
    var translationError: String?
    var archivedHints: [String] = []
    var hint = ""
    var isHintStreaming = false
}
