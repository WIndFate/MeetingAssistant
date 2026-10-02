import Foundation

enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case japanese
    case english

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .japanese: return "JA"
        case .english: return "EN"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .japanese: return "ja-JP"
        case .english: return "en-US"
        }
    }

    /// Name the prompts use for the meeting language.
    var promptName: String {
        switch self {
        case .japanese: return "Japanese"
        case .english: return "English"
        }
    }

    var next: TranscriptionLanguage {
        self == .japanese ? .english : .japanese
    }
}
