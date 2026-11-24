import SwiftUI

/// Scroll offset published by a page's vertical `ScrollView` so its pinned
/// top chrome can fade in its backing once content passes underneath.
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

/// Full-width backing that fades in behind pinned page chrome as the page
/// scrolls. On iPhone and iPad it is a soft edge: the page blurs and dims
/// from the top of the screen and fades out below the chrome with no line,
/// as on the Detail page (`PhoneDetailTopGlass`). The Mac keeps a Liquid
/// Glass strip. Either node is equatable and retained while only its alpha
/// changes. Place it as the chrome's `background`; it ignores the top safe
/// area so it also covers the status-bar region.
struct PageChromeGlass: View {
    /// Offset at which the strip starts to appear.
    static let fadeStart: CGFloat = 8
    /// Offset at which the strip is fully opaque.
    static let fadeEnd: CGFloat = 56
    /// The height of every header pill (`pageChromePill`), whatever it
    /// holds.
    static let pillHeight: CGFloat = 52
    /// How far below the chrome the soft edge reaches before it is gone.
    private static let softEdgeTail: CGFloat = 48
    /// The length of the soft edge's fade. Longer than the tail, so the
    /// fade is already under way at the chrome's lower edge.
    private static let softEdgeFadeLength: CGFloat = 70

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
    @ViewBuilder
    private var stripSurface: some View {
        #if os(iOS)
        SiloSoftEdgeSurface(reduceTransparency: reduceTransparency)
            .equatable()
        #else
        PageChromeStaticGlass(reduceTransparency: reduceTransparency)
            .equatable()
        #endif
    }

    private var strip: some View {
        stripSurface
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
            .padding(.bottom, -Self.softEdgeTail)
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: Self.softEdgeFadeLength)
                }
            }
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
            PageChromeBackingGlass(scrollState: scrollState, outset: outset, besideStatusColumn: true)
        }
        #else
        self
        #endif
    }

    /// A glass pill behind one header control (the action cluster, and on
    /// iPad the library selector and the sidebar button) on iPhone and
    /// iPad, where the page's backing is a soft edge with no bar to hold it. It fades in on the soft
    /// edge's schedule, like the glass circles on the Detail page's
    /// buttons. Beside the iPhone Duo's status column `pageChromeBacking`
    /// draws the glass instead.
    /// Every pill is `PageChromeGlass.pillHeight` tall, centred on the item,
    /// so pills match across pages and beside each other; one grows only
    /// when its item is taller, as at large text sizes. `sideOutset` extends
    /// the pill past the item's sides without moving it.
    @ViewBuilder
    func pageChromePill(
        scrollState: PageChromeScrollState?,
        sideOutset: (leading: CGFloat, trailing: CGFloat) = (0, 0)
    ) -> some View {
        #if os(iOS)
        if let scrollState {
            background {
                PageChromeBackingGlass(
                    scrollState: scrollState,
                    outset: EdgeInsets(top: 0, leading: sideOutset.leading, bottom: 0, trailing: sideOutset.trailing),
                    besideStatusColumn: false
                )
            }
        } else {
            self
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
    /// Which layout draws this glass: the folded iPhone Duo's, beside its
    /// status column, or every other.
    let besideStatusColumn: Bool

    @Environment(\.statusColumn) private var statusColumn
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if (statusColumn != nil) == besideStatusColumn {
            PageChromeStaticGlass(reduceTransparency: reduceTransparency, cornerRadius: 28)
                .equatable()
                .padding(EdgeInsets(
                    top: -outset.top,
                    leading: -outset.leading,
                    bottom: -outset.bottom,
                    trailing: -outset.trailing
                ))
                .frame(minHeight: besideStatusColumn ? nil : PageChromeGlass.pillHeight)
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

#if os(iOS)
/// The blurred, dimmed fill of a soft top edge. Callers mask it with a
/// gradient so it fades out downwards.
struct SiloSoftEdgeSurface: View, Equatable {
    let reduceTransparency: Bool

    var body: some View {
        if reduceTransparency {
            Color(white: 0.10)
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay(Color.black.opacity(0.22))
        }
    }
}
#endif

extension View {
    /// Fades a header's title out as content scrolls under the header, on
    /// the soft edge's schedule, so no text sits over the scrolling page.
    /// iPhone and iPad only, and not beside the iPhone Duo's status column,
    /// where `pageChromeBacking` keeps the title on glass.
    @ViewBuilder
    func pageChromeTitleFadesOut(scrollState: PageChromeScrollState?) -> some View {
        #if os(iOS)
        if let scrollState {
            modifier(PageChromeTitleFade(scrollState: scrollState))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct PageChromeTitleFade: ViewModifier {
    let scrollState: PageChromeScrollState

    @Environment(\.statusColumn) private var statusColumn

    func body(content: Content) -> some View {
        let progress = statusColumn == nil
            ? pageChromeSmoothProgress(
                scrollState.offset,
                from: PageChromeGlass.fadeStart,
                to: PageChromeGlass.fadeEnd
            )
            : 0
        // The title stays the page's heading for VoiceOver, so the fade
        // stops just short of zero: SwiftUI drops a fully transparent view
        // from the accessibility tree.
        content.opacity(max(1 - progress, 0.001))
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
