import SwiftUI

/// Scroll offset published by a page's vertical `ScrollView` so its pinned
/// top chrome can fade in a glass strip once content passes underneath.
/// Reference-backed like `PhoneDetailScrollState`, so only the small strip
/// re-evaluates while the scroll view's body stays stable.
@Observable
@MainActor
final class PageChromeScrollState {
    private(set) var offset: CGFloat = 0

    func update(_ rawOffset: CGFloat) {
        // The strip is fully opaque past `fadeEnd`; folding larger offsets
        // onto that endpoint avoids invalidating the chrome while scrolling
        // deep into the page.
        let clamped = min(max(0, rawOffset), PageChromeGlass.fadeEnd)
        guard abs(clamped - offset) >= 0.5 else { return }
        offset = clamped
    }

    func reset() {
        offset = 0
    }
}

/// Full-width Liquid Glass strip that fades in behind pinned page chrome as
/// the page scrolls. Mirrors the Detail page's `PhoneDetailTopGlass`: the
/// native glass node is equatable and retained while only its alpha changes.
/// Place it as the chrome's `background` and let it ignore the top safe area
/// so it also covers the status-bar region.
struct PageChromeGlass: View {
    /// Offset at which the strip starts to appear.
    static let fadeStart: CGFloat = 8
    /// Offset at which the strip is fully opaque.
    static let fadeEnd: CGFloat = 56

    let scrollState: PageChromeScrollState

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        #if os(tvOS)
        EmptyView()
        #else
        PageChromeStaticGlass(reduceTransparency: reduceTransparency)
            .equatable()
            .opacity(
                pageChromeSmoothProgress(
                    scrollState.offset,
                    from: Self.fadeStart,
                    to: Self.fadeEnd
                )
            )
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        #endif
    }
}

private struct PageChromeStaticGlass: View, Equatable {
    let reduceTransparency: Bool

    var body: some View {
        if reduceTransparency {
            Color(white: 0.16).opacity(0.98)
        } else {
            Color.clear
                .siloGlass(in: Rectangle(), tint: Color.black.opacity(0.10))
                .overlay(Color.white.opacity(0.025))
        }
    }
}

private func pageChromeSmoothProgress(
    _ value: CGFloat,
    from lowerBound: CGFloat,
    to upperBound: CGFloat
) -> CGFloat {
    let progress = min(max((value - lowerBound) / (upperBound - lowerBound), 0), 1)
    return progress * progress * (3 - (2 * progress))
}

extension View {
    /// Publish this vertical `ScrollView`'s offset to `state`. No-op on tvOS,
    /// which has no floating page chrome.
    @ViewBuilder
    func reportsPageChromeScroll(to state: PageChromeScrollState) -> some View {
        #if os(tvOS)
        self
        #else
        self.onScrollGeometryChange(for: CGFloat.self) { geometry in
            let offset = max(0, geometry.contentOffset.y + geometry.contentInsets.top)
            return min(offset, PageChromeGlass.fadeEnd)
        } action: { _, offset in
            state.update(offset)
        }
        #endif
    }

    /// Publish this vertical `ScrollView`'s offset to the
    /// `PageChromeScrollState` in the environment, if a parent installed one.
    /// Lets shared tab content (Browse, Recommended, Collections) feed the
    /// Library tab's chrome without knowing about it.
    func reportsPageChromeScroll() -> some View {
        modifier(EnvironmentPageChromeScrollReporter())
    }
}

private struct EnvironmentPageChromeScrollReporter: ViewModifier {
    @Environment(PageChromeScrollState.self) private var scrollState: PageChromeScrollState?

    func body(content: Content) -> some View {
        if let scrollState {
            content.reportsPageChromeScroll(to: scrollState)
        } else {
            content
        }
    }
}
