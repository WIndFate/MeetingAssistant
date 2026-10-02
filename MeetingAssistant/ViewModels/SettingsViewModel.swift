import AppKit
import Foundation

/// User settings: API key in the keychain, everything else in UserDefaults.
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var hasAPIKey: Bool
    @Published var translationModel: String { didSet { save(translationModel, Keys.translationModel) } }
    @Published var hintModel: String { didSet { save(hintModel, Keys.hintModel) } }
    @Published var knowledgeFolderPath: String { didSet { save(knowledgeFolderPath, Keys.knowledgeFolder) } }
    @Published var nameAliases: String { didSet { save(nameAliases, Keys.nameAliases) } }

    static let defaultTranslationModel = "gpt-5.4-mini"
    static let defaultHintModel = "gpt-5.4"
    // ponytail: assumes the repo lives at ~/Desktop/Meeting; editable in Settings.
    static let defaultKnowledgeFolder = "~/Desktop/Meeting/knowledge"

    private enum Keys {
        static let translationModel = "MeetingAssistant.TranslationModel"
        static let hintModel = "MeetingAssistant.HintModel"
        static let knowledgeFolder = "MeetingAssistant.KnowledgeFolder"
        static let nameAliases = "MeetingAssistant.NameAliases"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasAPIKey = Self.resolvedAPIKey() != nil
        translationModel = defaults.string(forKey: Keys.translationModel) ?? Self.defaultTranslationModel
        hintModel = defaults.string(forKey: Keys.hintModel) ?? Self.defaultHintModel
        knowledgeFolderPath = defaults.string(forKey: Keys.knowledgeFolder) ?? Self.defaultKnowledgeFolder
        nameAliases = defaults.string(forKey: Keys.nameAliases)
            ?? MeetingCallDetector.defaultAliases.joined(separator: ", ")
    }

    var apiKey: String? { Self.resolvedAPIKey() }

    var aliases: [String] { MeetingCallDetector.aliases(from: nameAliases) }

    var knowledgeFolderURL: URL {
        URL(fileURLWithPath: (knowledgeFolderPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    func saveAPIKey(_ key: String) {
        KeychainStore.saveAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
        hasAPIKey = Self.resolvedAPIKey() != nil
    }

    func openKnowledgeFolder() {
        try? FileManager.default.createDirectory(at: knowledgeFolderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(knowledgeFolderURL)
    }

    /// Keychain first; `OPENAI_API_KEY` in the Xcode scheme works for development.
    private static func resolvedAPIKey() -> String? {
        if let key = KeychainStore.readAPIKey(), !key.isEmpty { return key }
        let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
        return env.isEmpty ? nil : env
    }

    private func save(_ value: String, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
