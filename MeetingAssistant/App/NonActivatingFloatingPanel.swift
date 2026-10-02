import AppKit

/// Floating utility-style panel that does NOT steal focus from the foreground
/// app when clicked or dragged. Combined with `.nonactivatingPanel` in the
/// style mask and `becomesKeyOnlyIfNeeded = true`, the panel still receives
/// mouse events for buttons/menus while leaving the user's current app
/// (e.g. a browser during screen sharing) as the active one.
final class NonActivatingFloatingPanel: NSPanel {
    // Allow becoming key only when a control inside genuinely needs first
    // responder status (text field focus, menu invocation). Combined with
    // `becomesKeyOnlyIfNeeded`, plain clicks and drags do not promote it.
    override var canBecomeKey: Bool { true }

    // Never become the main window — that's what triggers app activation /
    // Dock highlight, exactly the behavior we want to avoid.
    override var canBecomeMain: Bool { false }
}
