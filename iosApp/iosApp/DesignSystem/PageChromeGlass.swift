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
    #if os(iOS)
    @Environment(\.statusColumn) private var statusColumn
    #endif

    @ViewBuilder
    var body: some View {
        #if os(tvOS)
        EmptyView()
        #else
        if showsStrip {
            strip
        }
        #endif
    }

    /// Beside the iPhone Duo's status column the strip would end at the
    /// column in a hard edge, so the header's own content carries rounded
    /// glass there instead (see `pageChromeBacking`).
    private var showsStrip: Bool {
        #if os(iOS)
        statusColumn == nil
        #else
        true
        #endif
    }

    #if !os(tvOS)
    private var strip: some View {
        PageChromeStaticGlass(reduceTransparency: reduceTransparency)
            .equatable()
            .opacity(
                pageChromeSmoothProgress(
                    scrollState.offset,
                    from: Self.fadeStart,
                    to: Self.fadeEnd
                )
            )
            #if os(macOS)
            // Extend the strip a little below the chrome and fade only that
            // extension, so the title and pills keep a full blur behind them
            // while the strip still melts into the page with no hard line.
            .padding(.bottom, -SiloTheme.macPageChromeFadeLength)
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: SiloTheme.macPageChromeFadeLength)
                }
            }
            // Run under the Mac sidebar too, so the strip does not end in a
            // straight edge beside the sidebar's rounded panel.
            .ignoresSafeArea(edges: [.top, .leading])
            #else
            .ignoresSafeArea(edges: .top)
            #endif
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
    #endif
}

extension View {
    /// Rounded glass behind a header's leading content, used only beside
    /// the iPhone Duo's status column, where the page has no full-width
    /// strip. It fades in on the strip's schedule. `outset` extends the
    /// glass past the content without moving it; negative values inset it.
    @ViewBuilder
    func pageChromeBacking(scrollState: PageChromeScrollState, outset: EdgeInsets) -> some View {
        #if os(iOS)
        background {
            PageChromeBackingGlass(scrollState: scrollState, outset: outset)
        }
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct PageChromeBackingGlass: View {
    let scrollState: PageChromeScrollState
    let outset: EdgeInsets

    @Environment(\.statusColumn) private var statusColumn
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if statusColumn != nil {
            PageChromeStaticGlass(reduceTransparency: reduceTransparency, cornerRadius: 28)
                .equatable()
                .padding(EdgeInsets(
                    top: -outset.top,
                    leading: -outset.leading,
                    bottom: -outset.bottom,
                    trailing: -outset.trailing
                ))
                .opacity(
                    pageChromeSmoothProgress(
                        scrollState.offset,
                        from: PageChromeGlass.fadeStart,
                        to: PageChromeGlass.fadeEnd
                    )
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
#endif

private struct PageChromeStaticGlass: View, Equatable {
    let reduceTransparency: Bool
    var cornerRadius: CGFloat = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            Color(white: 0.16).opacity(0.98)
                .clipShape(shape)
        } else {
            Color.clear
                .siloGlass(in: shape, tint: Color.black.opacity(0.10))
                .overlay(Color.white.opacity(0.025).clipShape(shape))
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
