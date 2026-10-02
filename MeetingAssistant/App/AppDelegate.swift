import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = MeetingViewModel()

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

    private func installPanel() {
        // ignoresSafeArea: let SwiftUI draw into the hidden title bar strip.
        let hosting = NSHostingView(
            rootView: ContentView(viewModel: viewModel, settings: viewModel.settings)
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
        stealthObservation = viewModel.$isStealthEnabled
            .sink { [weak self] enabled in
                self?.panel?.sharingType = enabled ? .none : .readOnly
            }
    }
}
