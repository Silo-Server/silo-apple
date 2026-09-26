#if os(tvOS)
import SwiftUI
import UIKit

/// A one-point focus fence beside the composite episode carousel. The
/// carousel spans the full screen width, so a Left or Right move — swipes in
/// particular — can otherwise resolve to a card that a lower rail lays out
/// beyond the screen edge. While the carousel owns focus, the fence is the
/// nearest target on its side and refuses the update. The rejected move still
/// reaches the carousel's `onMoveCommand`, which stays the only owner of
/// episode movement.
struct TVEpisodeRailEdgeFence: UIViewRepresentable {
    var isActive: Bool

    func makeUIView(context: Context) -> FenceView { FenceView() }

    func updateUIView(_ uiView: FenceView, context: Context) {
        uiView.isActive = isActive
    }

    final class FenceView: UIView {
        var isActive = false

        override var canBecomeFocused: Bool { isActive }

        override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            context.nextFocusedItem !== self
        }
    }
}
#endif
