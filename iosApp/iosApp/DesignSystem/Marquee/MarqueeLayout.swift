import SwiftUI

extension View {
    /// First-run screens draw over the shared backdrop, so the navigation
    /// container must not paint its own background or bar. iOS only: tvOS
    /// and macOS stacks don't draw one.
    func marqueeTransparentNavigation() -> some View {
        #if os(iOS)
        self
            .containerBackground(.clear, for: .navigation)
            .toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}

#if !os(tvOS)

// MARK: - Stage (iPhone, iPad, Mac)

/// A first-run screen: transparent over the shared backdrop, a scrim for
/// legibility, and content anchored to the bottom like a streaming app's
/// welcome screen. The column scrolls, so large text sizes push the title up
/// instead of clipping controls.
struct MarqueeStage<TopBar: View, Content: View>: View {
    var scrim: MarqueeScrimStyle = .bottom
    var frostStart: CGFloat? = 0.42
    var maxWidth: CGFloat = 440
    /// Screens without text fields keep their layout while another screen's
    /// keyboard slides away.
    var avoidsKeyboard: Bool = true
    /// What the back button does. When set, swiping right anywhere on the
    /// page does the same on iPhone and iPad.
    var onBack: (() -> Void)?
    @ViewBuilder var topBar: () -> TopBar
    @ViewBuilder var content: () -> Content

    #if os(iOS)
    /// Room kept for the keyboard. It only grows while the keyboard is up and
    /// shrinks once the keyboard has stayed away briefly; see `keyboardChanged`.
    @State private var keyboardInset: CGFloat = 0
    @State private var fullHeight: CGFloat = 0
    @State private var roomAboveKeyboard: CGFloat = 0
    @State private var collapse: Task<Void, Never>?
    #endif

    var body: some View {
        stage
            .background { MarqueeScrim(style: scrim, frostStart: frostStart) }
            .preferredColorScheme(.dark)
    }

    #if os(iOS)
    // The column ignores the keyboard and keeps its own room for it
    // (`keyboardChanged`) instead of following the system's avoidance frame
    // by frame. An empty sibling still avoids the keyboard; the difference in
    // height is how far the keyboard overlaps.
    private var stage: some View {
        ZStack {
            Color.clear
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    roomAboveKeyboard = $0
                    keyboardChanged()
                }
            column
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    fullHeight = $0
                    keyboardChanged()
                }
                .ignoresSafeArea(.keyboard)
                // Only the column slides; the scrim stays put over the backdrop.
                .marqueeSwipeBack(onBack)
        }
    }
    #else
    private var stage: some View { column }
    #endif

    // The top bar sits above the scroll area rather than floating over it, so
    // a tall column (keyboard up, large text) scrolls out of view instead of
    // sliding under the wordmark or back button.
    private var column: some View {
        VStack(spacing: 0) {
            topBar()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 8)

            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer(minLength: 0)
                        content()
                    }
                    .frame(maxWidth: maxWidth)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geo.size.height, alignment: .bottom)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                // Keep the bottom (the primary action) in view when the
                // keyboard room changes.
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .scrollIndicators(.hidden)
            }
            #if os(iOS)
            .padding(.bottom, keyboardInset)
            #endif
        }
    }

    #if os(iOS)
    /// Moving focus between a text field and a secure field changes the
    /// keyboard: the secure keyboard drops the dictation row, and a
    /// third-party keyboard is swapped for the system one (iOS never allows
    /// them in password fields), sometimes passing through no keyboard at
    /// all. Following each change drops the form and jumps it back. So the
    /// room only grows while the keyboard is up, and shrinks once the
    /// keyboard has stayed away briefly.
    private func keyboardChanged() {
        guard avoidsKeyboard, fullHeight > 0, roomAboveKeyboard > 0 else { return }
        let overlap = max(0, (fullHeight - roomAboveKeyboard).rounded())
        if overlap > keyboardInset {
            collapse?.cancel()
            collapse = nil
            withAnimation(.easeOut(duration: 0.25)) { keyboardInset = overlap }
        } else if overlap == 0, keyboardInset > 0, collapse == nil {
            collapse = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.25)) { keyboardInset = 0 }
                collapse = nil
            }
        } else if overlap > 0 {
            // Back before the collapse fired: keep the room.
            collapse?.cancel()
            collapse = nil
        }
    }
    #endif
}

#if os(iOS)
// MARK: - Swipe back

extension View {
    /// Swipe right from anywhere on the page to go back, alongside the back
    /// button. The page follows the finger and either slides away or springs
    /// back. A horizontal drag is needed to start, so vertical scrolling,
    /// taps and text editing are unaffected. VoiceOver's escape gesture
    /// (two-finger Z) does the same. Nil leaves the view unchanged.
    @ViewBuilder
    func marqueeSwipeBack(_ action: (() -> Void)?) -> some View {
        if let action {
            modifier(MarqueeSwipeBack(action: action))
        } else {
            self
        }
    }
}

private struct MarqueeSwipeBack: ViewModifier {
    let action: () -> Void

    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 1
    @State private var pastThreshold = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(x: reduceMotion ? 0 : offset)
            .opacity(1 - 0.6 * progress)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max($0, 1) }
            // Gaps between controls count too, not only drawn content.
            .contentShape(.rect)
            .gesture(BackSwipeRecognizer(changed: changed, ended: ended))
            .sensoryFeedback(.impact(weight: .light), trigger: pastThreshold) { _, isPast in isPast }
            .accessibilityAction(.escape, action)
    }

    private var progress: CGFloat { min(max(offset / width, 0), 1) }
    private var threshold: CGFloat { width * 0.3 }

    private func changed(_ translation: CGFloat) {
        offset = max(0, translation)
        pastThreshold = offset > threshold
    }

    /// A short flick counts as well as a long drag; flicking back left
    /// cancels either.
    private func ended(translation: CGFloat, velocity: CGFloat, cancelled: Bool) {
        pastThreshold = false
        let commits = !cancelled && velocity > -150 && (translation > threshold || velocity > 700)
        guard commits else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { offset = 0 }
            return
        }
        // The page slides off while the previous one fades in behind it.
        withAnimation(.easeOut(duration: 0.22)) { offset = width }
        action()
        // Normally the page is gone by now; if it stays, bring it back.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { offset = 0 }
        }
    }
}

/// A one-finger pan that only begins when the finger moves mostly rightward.
/// It recognizes alongside scroll views so a slightly diagonal swipe still
/// works on pages that scroll.
private struct BackSwipeRecognizer: UIGestureRecognizerRepresentable {
    let changed: (CGFloat) -> Void
    let ended: (_ translation: CGFloat, _ velocity: CGFloat, _ cancelled: Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        let velocity = recognizer.velocity(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed: changed(translation)
        case .ended: ended(translation, velocity, false)
        case .cancelled, .failed: ended(translation, velocity, true)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.x > 0 && velocity.x > abs(velocity.y) * 1.5
        }

        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            other.view is UIScrollView
        }
    }
}
#endif

extension MarqueeStage where TopBar == EmptyView {
    init(
        scrim: MarqueeScrimStyle = .bottom,
        frostStart: CGFloat? = 0.42,
        maxWidth: CGFloat = 440,
        avoidsKeyboard: Bool = true,
        onBack: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.scrim = scrim
        self.frostStart = frostStart
        self.maxWidth = maxWidth
        self.avoidsKeyboard = avoidsKeyboard
        self.onBack = onBack
        self.topBar = { EmptyView() }
        self.content = content
    }
}

/// Back button on the left, an accessory (server chip) on the right.
struct MarqueeTopBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            leading()
            Spacer(minLength: 12)
            trailing()
        }
        .frame(minHeight: 44)
    }
}

#else

// MARK: - TV layout

/// Apple TV first-run screen: backdrop full-bleed under a leading scrim, copy on
/// the left at 88 pt, and the action card on the right in glass. Each side is
/// its own focus section.
struct MarqueeTVScreen<Copy: View, Card: View, Accessory: View>: View {
    var scrim: MarqueeScrimStyle = .leading
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var copy: () -> Copy
    @ViewBuilder var card: () -> Card

    var body: some View {
        ZStack {
            MarqueeScrim(style: scrim)
            VStack(spacing: 0) {
                HStack {
                    SiloWordmarkView(width: 150)
                    Spacer(minLength: 0)
                    accessory()
                }
                .frame(height: 64)

                HStack(alignment: .center, spacing: 80) {
                    VStack(alignment: .leading, spacing: 0) {
                        copy()
                    }
                    .frame(width: 900, alignment: .leading)
                    .focusSection()

                    Spacer(minLength: 0)

                    card()
                        .focusSection()
                }
                .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 60)
        }
        .ignoresSafeArea()
    }
}

extension MarqueeTVScreen where Accessory == EmptyView {
    init(
        scrim: MarqueeScrimStyle = .leading,
        @ViewBuilder copy: @escaping () -> Copy,
        @ViewBuilder card: @escaping () -> Card
    ) {
        self.scrim = scrim
        self.accessory = { EmptyView() }
        self.copy = copy
        self.card = card
    }
}

/// The right-hand glass card on TV screens.
struct MarqueeTVCard<Content: View>: View {
    var width: CGFloat = 640
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .multilineTextAlignment(.center)
            .padding(52)
            .frame(width: width)
            .background {
                RoundedRectangle(cornerRadius: 40, style: .continuous)
                    .fill(Color(white: 0.12).opacity(0.72))
                    .overlay(
                        RoundedRectangle(cornerRadius: 40, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .siloGlass(in: RoundedRectangle(cornerRadius: 40, style: .continuous))
            }
            .shadow(color: .black.opacity(0.55), radius: 40, y: 24)
    }
}

/// Small status capsule ("Looking for a phone or tablet…").
struct MarqueeTVStatusChip: View {
    let text: String
    var showsSpinner: Bool = false
    var systemImage: String?

    var body: some View {
        HStack(spacing: 14) {
            if showsSpinner {
                ProgressView().scaleEffect(0.8)
            } else if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(Color.siloOnSurface.opacity(0.62))
        .padding(.horizontal, 22)
        .frame(height: 52)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.08))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        )
    }
}

#endif
