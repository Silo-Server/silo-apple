import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Phone rails share a top edge even when one card has more metadata.
/// Other platforms retain their existing layout and focus behavior.
enum HorizontalMediaRailLayout {
    static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    static var cardAlignment: VerticalAlignment { isPhone ? .top : .center }
    static var scrollAnchor: UnitPoint { isPhone ? .leading : .center }
    static var targetBehavior: ViewAlignedScrollTargetBehavior {
        #if os(iOS)
        // The explicit leading anchor is iOS 26+. iOS 18 keeps the system
        // anchor, which still snaps whole cards into view.
        if #available(iOS 26.0, *) {
            return .viewAligned(limitBehavior: .always, anchor: isPhone ? .leading : nil)
        } else {
            return .viewAligned(limitBehavior: .always)
        }
        #else
        return .viewAligned(limitBehavior: .always, anchor: isPhone ? .leading : nil)
        #endif
    }
}

extension View {
    /// Attach to the stack INSIDE a horizontal media ScrollView, so the
    /// nearest native scroll view is the rail, not its vertically scrolling page.
    @ViewBuilder
    func phoneMediaRailBounds() -> some View {
        #if os(iOS)
        if HorizontalMediaRailLayout.isPhone {
            background(PhoneMediaRailBounds().allowsHitTesting(false))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct PhoneMediaRailBounds: UIViewRepresentable {
    func makeUIView(context: Context) -> PhoneMediaRailBoundsView {
        PhoneMediaRailBoundsView()
    }

    func updateUIView(_ uiView: PhoneMediaRailBoundsView, context: Context) {
        uiView.configureEnclosingRail()
        // SwiftUI can attach or update its native scroll view after this call.
        // One deferred pass handles that without polling or replacing delegates.
        DispatchQueue.main.async { [weak uiView] in
            uiView?.configureEnclosingRail()
        }
    }
}

final class PhoneMediaRailBoundsView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        configureEnclosingRail()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        configureEnclosingRail()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Reassert after a detail cover/zoom restores SwiftUI's scroll host.
        configureEnclosingRail()
    }

    func configureEnclosingRail() {
        var ancestor = superview
        while let view = ancestor {
            if let rail = view as? UIScrollView {
                // Native scrolling/deceleration stays in charge. Unlike
                // .basedOnSize, these flags also stop long rails overscrolling
                // past their first/last card and drifting vertically on a drag.
                if rail.bouncesHorizontally { rail.bouncesHorizontally = false }
                if rail.bouncesVertically { rail.bouncesVertically = false }
                if rail.alwaysBounceHorizontal { rail.alwaysBounceHorizontal = false }
                if rail.alwaysBounceVertical { rail.alwaysBounceVertical = false }
                if !rail.isDirectionalLockEnabled { rail.isDirectionalLockEnabled = true }
                return
            }
            ancestor = view.superview
        }
    }
}
#endif
