import SwiftUI

/// Next Up supplies geometry, never another video view. Moving a shared
/// AVPlayerLayer between two representables lets an outgoing view steal or
/// detach the incoming view's picture during a SwiftUI transition.
struct PlayerPreviewBoundsKey: PreferenceKey {
    struct Value {
        var bounds: Anchor<CGRect>?
        var viewport: Anchor<CGRect>?
    }

    static var defaultValue: Value { Value() }

    static func reduce(value: inout Value, nextValue: () -> Value) {
        let next = nextValue()
        value.bounds = next.bounds ?? value.bounds
        value.viewport = next.viewport ?? value.viewport
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

/// The preview and primary actions never live inside a scroll view on mobile.
/// Only the optional On Deck shelf scrolls. Wide screens put actions on the
/// right; narrow screens cap the preview so it cannot push Play Now below them.
struct PlayerNextUpMobileLayout<Preview: View, Panel: View, Extras: View>: View {
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let panel: () -> Panel
    @ViewBuilder let extras: () -> Extras

    var body: some View {
        GeometryReader { proxy in
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
                    panel().frame(maxWidth: sideBySide ? 420 : .infinity)
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
        }
    }
}
