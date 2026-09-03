import SwiftUI

/// Next Up supplies geometry, never another video view. Moving a shared
/// AVPlayerLayer between two representables lets an outgoing view steal or
/// detach the incoming view's picture during a SwiftUI transition.
struct PlayerPreviewBoundsKey: PreferenceKey {
    struct Value {
        var bounds: Anchor<CGRect>?
        var viewport: Anchor<CGRect>?
        var actions: Anchor<CGRect>?
    }

    static var defaultValue: Value { Value() }

    static func reduce(value: inout Value, nextValue: () -> Value) {
        let next = nextValue()
        value.bounds = next.bounds ?? value.bounds
        value.viewport = next.viewport ?? value.viewport
        value.actions = next.actions ?? value.actions
    }
}

struct PlayerSurfaceLayout<Surface: View, Content: View>: View {
    let isPreview: Bool
    @ViewBuilder let surface: () -> Surface
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content()
            .overlayPreferenceValue(PlayerPreviewBoundsKey.self) { geometry in
                GeometryReader { proxy in
                    let fullFrame = CGRect(origin: .zero, size: proxy.size)
                    let frame = isPreview ? geometry.bounds.map { proxy[$0] } ?? fullFrame : fullFrame
                    let viewport = isPreview ? geometry.viewport.map { proxy[$0] } ?? fullFrame : fullFrame
                    // One structural identity in both modes. Only geometry changes;
                    // expansion must not load, seek, bind a second host, or resume.
                    surface()
                        .frame(width: frame.width, height: frame.height)
                        .clipShape(RoundedRectangle(cornerRadius: isPreview ? 8 : 0))
                        .overlay {
                            RoundedRectangle(cornerRadius: isPreview ? 8 : 0)
                                .stroke(.white.opacity(isPreview ? 0.16 : 0), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(isPreview ? 0.55 : 0), radius: isPreview ? 34 : 0, y: isPreview ? 18 : 0)
                        .position(x: frame.midX, y: frame.midY)
                        // Respect the original ScrollView's clipping even though
                        // the video itself is a persistent sibling of that view.
                        .mask {
                            Rectangle()
                                .frame(width: viewport.width, height: viewport.height)
                                .position(x: viewport.midX, y: viewport.midY)
                        }
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: isPreview)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(isPreview)
            }
    }
}

/// iOS keeps one vertical preview/actions stack through rotation. The Mac
/// retains its side-by-side layout and optional On Deck shelf.
struct PlayerNextUpMobileLayout<Preview: View, Panel: View, Extras: View>: View {
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let panel: (_ compact: Bool) -> Panel
    @ViewBuilder let extras: () -> Extras

    var body: some View {
        GeometryReader { proxy in
            #if os(iOS)
            let compact = proxy.size.width > proxy.size.height
            PlayerNextUpStackLayout(compact: compact) {
                preview()
                panel(compact)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, compact ? 8 : 16)
            .frame(width: proxy.size.width, height: proxy.size.height)
            #else
            let horizontalInset = max(20, max(proxy.safeAreaInsets.leading, proxy.safeAreaInsets.trailing) + 12)
            let topInset = max(16, proxy.safeAreaInsets.top + 12)
            let bottomInset = max(16, proxy.safeAreaInsets.bottom + 12)
            let width = max(0, min(1100, proxy.size.width - horizontalInset * 2))
            let height = max(0, proxy.size.height - topInset - bottomInset)
            let sideBySide = (width >= 500 && width > height) || width >= 760
            let previewWidth = sideBySide
                ? min(480, width * 0.43, height * 0.7 * 16 / 9)
                : min(260, width, height * 0.22 * 16 / 9)
            let layout = sideBySide
                ? AnyLayout(HStackLayout(alignment: .center, spacing: 24))
                : AnyLayout(VStackLayout(alignment: .center, spacing: 14))

            VStack(spacing: 16) {
                layout {
                    preview().frame(width: previewWidth)
                    panel(height < 270).frame(maxWidth: sideBySide ? 420 : .infinity)
                        .layoutPriority(1)
                }
                .frame(maxWidth: .infinity)
                .layoutPriority(1)

                ScrollView(.vertical, showsIndicators: false) {
                    extras()
                }
            }
            .frame(width: width, height: height, alignment: .top)
            .frame(maxWidth: .infinity)
            .padding(.top, topInset)
            #endif
        }
    }
}

#if os(iOS)
/// Measure the actual action panel first, then fit the preview above it.
/// Keeping the same stack and video anchor across sizes avoids reparenting
/// the playing surface or guessing how much room the text and buttons need.
struct PlayerNextUpStackLayout: Layout {
    var compact: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let panelWidth = min(bounds.width, compact ? 560 : 380)
        let panelSize = subviews[1].sizeThatFits(.init(width: panelWidth, height: nil))
        let gap: CGFloat = compact ? 8 : 16
        let availableHeight = max(0, bounds.height - panelSize.height - gap)
        let previewWidth = min(compact ? 280 : 300, bounds.width, availableHeight * 16 / 9)
        let previewHeight = previewWidth * 9 / 16
        let totalHeight = previewHeight + gap + panelSize.height
        let top = bounds.minY + max(0, (bounds.height - totalHeight) / 2)
        subviews[0].place(at: CGPoint(x: bounds.midX, y: top), anchor: .top,
                          proposal: .init(width: previewWidth, height: previewHeight))
        subviews[1].place(at: CGPoint(x: bounds.midX, y: top + previewHeight + gap), anchor: .top,
                          proposal: .init(width: panelWidth, height: panelSize.height))
    }
}
#endif
