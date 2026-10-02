import SwiftUI

// Chat-style auto-scroll container built on the native bottom anchor.
//
// `.defaultScrollAnchor(.bottom)` (initial offset + size changes) makes the
// framework itself keep the view pinned to the newest content while the user
// is at the bottom, leave the offset alone once they scroll up into history,
// and re-engage pinning when they scroll back down. Anchoring happens inside
// the scroll view's own layout pass, so content growing or shrinking (draft /
// refining / listening bubbles appearing and disappearing within one frame)
// can never strand the offset past the content end.
//
// Do NOT reintroduce hand-rolled following (onScrollGeometryChange +
// programmatic scrollTo). Three generations of that approach all lost the
// race against the layout system: scrollTo(id:) overshot on LazyVStack height
// estimates, scrollTo(edge: .bottom) was skipped as a value-unchanged no-op,
// and scrollTo(y:) computed offsets from a contentSize that a same-frame
// bubble churn had already invalidated, stranding the viewport in blank space
// below the content.
//
// `.alignment` deliberately keeps its default so a conversation shorter than
// the viewport still reads from the top.
struct FollowBottomScrollView<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
    }
}
