import SwiftUI

/// Scroll offset published by a page's vertical `ScrollView` so its pinned
/// top chrome can fade in a glass strip once content passes underneath.
/// Reference-backed like `PhoneDetailScrollState`, so only the small strip
/// re-evaluates while the scroll view's body stays stable.
@Observable
@MainActor
final class PageChromeScrollState {
    private(set) var offset: CGFloat = 0
    /// True on iPhone and iPad once the page has scrolled far enough for a
    /// pinned header to fold to one line. Folding shortens the header, which
    /// lowers the measured offset by the height it lost without the page
    /// moving, so the header folds and unfolds at points further apart than
    /// that and can't flip back.
    private(set) var isCompact = false

    static let compactAt: CGFloat = 44
    static let expandAt: CGFloat = 4
    /// How far past the fold point the reported offset runs, so a header
    /// that loses more than the usual gap can still fold later.
    static let foldRange: CGFloat = 200

    /// The header's top inset while unfolded, and how much it has been seen
    /// to lose by folding. At large text sizes the loss can exceed the gap
    /// between `compactAt` and `expandAt`; the fold point then moves past it.
    @ObservationIgnored private var unfoldedInset: CGFloat?
    @ObservationIgnored private var foldLoss: CGFloat = 0

    /// Far enough down that the folded header's offset stays clear of
    /// `expandAt`, with some room to spare.
    private var foldAt: CGFloat {
        max(Self.compactAt, foldLoss + Self.expandAt + 8)
    }

    func update(_ rawOffset: CGFloat, topInset: CGFloat = 0) {
        let scrolled = max(0, rawOffset)
        #if os(iOS)
        if isCompact {
            if let unfoldedInset {
                foldLoss = max(foldLoss, unfoldedInset - topInset)
            }
        } else {
            unfoldedInset = topInset
        }
        if !isCompact, scrolled >= foldAt {
            isCompact = true
        } else if isCompact, scrolled <= Self.expandAt {
            isCompact = false
        }
        #endif
        // The strip is fully opaque past `fadeEnd`; folding larger offsets
        // onto that endpoint avoids invalidating the chrome while scrolling
        // deep into the page.
        let clamped = min(scrolled, PageChromeGlass.fadeEnd)
        guard abs(clamped - offset) >= 0.5 else { return }
        offset = clamped
    }
}

/// Full-width strip that fades in behind pinned page chrome as the page
/// scrolls. On iPhone and iPad it's a dark fade that runs a little past the
/// chrome and dissolves, so content passes under the title without showing
/// through it and without a hard bottom line. On the Mac it's Liquid Glass,
/// as in the Detail page's `PhoneDetailTopGlass`: the native glass node is
/// equatable and retained while only its alpha changes. Place it as the
/// chrome's `background`; it covers the status-bar region itself.
struct PageChromeGlass: View {
    /// Offset at which the strip starts to appear.
    static let fadeStart: CGFloat = 8
    /// Offset at which the strip is fully opaque.
    static let fadeEnd: CGFloat = 56
    /// How far the iOS fade runs past the chrome's bottom edge.
    static let fadeTail: CGFloat = 28

    let scrollState: PageChromeScrollState

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        #if os(tvOS)
        EmptyView()
        #elseif os(iOS)
        Group {
            if reduceTransparency {
                // A solid strip: nothing shows through the header.
                Color.siloPageCanvas
            } else {
                fade.padding(.bottom, -Self.fadeTail)
            }
        }
        .opacity(pageChromeSmoothProgress(scrollState.offset, from: Self.fadeStart, to: Self.fadeEnd))
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
        #endif
    }

    #if os(iOS)
    private var fade: some View {
        LinearGradient(
            stops: [
                .init(color: Color.siloPageCanvas.opacity(0.97), location: 0),
                .init(color: Color.siloPageCanvas.opacity(0.93), location: 0.72),
                .init(color: Color.siloPageCanvas.opacity(0), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
    #endif
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
        self.onScrollGeometryChange(for: PageChromeScrollGeometry.self) { geometry in
            let offset = max(0, geometry.contentOffset.y + geometry.contentInsets.top)
            return PageChromeScrollGeometry(
                offset: min(offset, PageChromeScrollState.foldRange),
                topInset: geometry.contentInsets.top
            )
        } action: { _, geometry in
            state.update(geometry.offset, topInset: geometry.topInset)
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

private struct PageChromeScrollGeometry: Equatable {
    let offset: CGFloat
    let topInset: CGFloat
}

extension View {
    /// Animates a pinned header folding or unfolding, unless Reduce Motion
    /// is on.
    func animatesPageChromeFold(_ scrollState: PageChromeScrollState) -> some View {
        modifier(PageChromeFoldAnimation(isCompact: scrollState.isCompact))
    }
}

private struct PageChromeFoldAnimation: ViewModifier {
    let isCompact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : .snappy(duration: 0.25), value: isCompact)
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
