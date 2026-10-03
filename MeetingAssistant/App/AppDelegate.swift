import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = MeetingViewModel()
    private let history = HistoryViewModel()
    private var historyWindow: NSWindow?

    private let hintHotKey = GlobalHotKeyService()
    private var panel: NonActivatingFloatingPanel?
    private var stealthObservation: AnyCancellable?

    private let defaultPanelSize = NSSize(width: 440, height: 460)
    private let panelInset: CGFloat = 20

    func applicationDidFinishLaunching(_ notification: Notification) {
        installPanel()
        hintHotKey.register(.replyHintNow) { [weak viewModel] in
            viewModel?.requestHintNow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel.saveHistoryNow()
    }

    /// A regular window: browsing history is deliberate, so it may take focus.
    func showHistory() {
        // Include the meeting in progress, up to this moment.
        viewModel.saveHistoryNow()
        history.reload()
        if historyWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "会议记录"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: HistoryView(viewModel: history))
            window.center()
            window.setFrameAutosaveName("MeetingHistory")
            historyWindow = window
            applyStealth()
        }
        NSApp.activate()
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    private func installPanel() {
        // ignoresSafeArea: let SwiftUI draw into the hidden title bar strip.
        let hosting = NSHostingView(
            rootView: ContentView(
                viewModel: viewModel,
                settings: viewModel.settings,
                onOpenHistory: { [weak self] in self?.showHistory() }
            )
                .ignoresSafeArea(.all)
                .frame(minWidth: defaultPanelSize.width, minHeight: defaultPanelSize.height)
        )

        let panel = NonActivatingFloatingPanel(
            contentRect: NSRect(origin: .zero, size: defaultPanelSize),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = defaultPanelSize
        panel.contentView = hosting

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - defaultPanelSize.width - panelInset,
                y: visible.maxY - defaultPanelSize.height - panelInset
            ))
        }
        panel.orderFront(nil)
        self.panel = panel

        // Best-effort hide from screen sharing; modern ScreenCaptureKit-based
        // capture may still record the composited display.
        // The history window shows the same content, so it follows too.
        stealthObservation = viewModel.$isStealthEnabled
            .sink { [weak self] _ in
                // The publisher fires before the property changes; read it on the next turn.
                DispatchQueue.main.async { self?.applyStealth() }
            }
    }

    private func applyStealth() {
        let sharing: NSWindow.SharingType = viewModel.isStealthEnabled ? .none : .readOnly
        panel?.sharingType = sharing
        historyWindow?.sharingType = sharing
    }
}
