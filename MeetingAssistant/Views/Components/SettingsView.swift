import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsViewModel
    @State private var apiKeyDraft = ""

    var body: some View {
        Form {
            Section("OpenAI") {
                HStack {
                    SecureField(settings.hasAPIKey ? "Saved in Keychain" : "sk-...", text: $apiKeyDraft)
                    Button("Save") {
                        settings.saveAPIKey(apiKeyDraft)
                        apiKeyDraft = ""
                    }
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                TextField("Translation model", text: $settings.translationModel)
                TextField("Reply hint model", text: $settings.hintModel)
            }
            Section {
                HStack {
                    TextField("Folder", text: $settings.knowledgeFolderPath)
                    Button("Open") { settings.openKnowledgeFolder() }
                }
            } header: {
                Text("Knowledge folder")
            } footer: {
                Text("*.md / *.txt are read on every request. instructions.md adds extra prompt rules.")
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Aliases", text: $settings.nameAliases)
            } header: {
                Text("Your name in the meeting")
            } footer: {
                Text("Comma separated. Japanese aliases need さん so セキュリティ does not match. The first one is shown to the model.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .padding(.vertical, 6)
    }
}
