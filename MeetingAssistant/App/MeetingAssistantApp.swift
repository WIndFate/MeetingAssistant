import SwiftUI

@main
struct MeetingAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The UI lives on a NonActivatingFloatingPanel owned by AppDelegate so
        // clicking it never steals focus from the meeting app. This inert
        // Settings scene only keeps the menu commands wired up.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Meeting") {
                Button("Toggle Japanese / English") {
                    appDelegate.viewModel.toggleLanguage()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("Reply Hint Now") {
                    appDelegate.viewModel.requestHintNow()
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])

                Button("Meeting History") {
                    appDelegate.showHistory()
                }
                .keyboardShortcut("y", modifiers: .command)
            }
        }
    }
}
