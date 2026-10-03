#if os(tvOS)
import SwiftUI

// MARK: - Match code

/// The code a person compares between the TV and their phone. Codes are
/// server-generated and may be longer than four characters, so tiles shrink to
/// keep the row inside the card.
struct MarqueeCodeTiles: View {
    let code: String
    var maxWidth: CGFloat = 520

    var body: some View {
        let characters = Array(code.uppercased())
        let gap: CGFloat = 14
        let gaps = gap * CGFloat(max(characters.count - 1, 0))
        let tileWidth = min(84, (maxWidth - gaps) / CGFloat(max(characters.count, 1)))

        HStack(spacing: gap) {
            ForEach(Array(characters.enumerated()), id: \.offset) { _, character in
                let isSeparator = character == "-" || character == " "
                Text(character == "-" ? "–" : isSeparator ? " " : String(character))
                    .font(.system(size: tileWidth * 0.66, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSeparator ? Color.siloOnSurface.opacity(0.4) : Color.siloOnSurface)
                    .frame(width: isSeparator ? tileWidth * 0.45 : tileWidth, height: tileWidth * 1.24)
                    .background {
                        if !isSeparator {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(characters.map(String.init).joined(separator: ", "))
    }
}

// MARK: - Hand-off dots

/// Pulsing dots between two marks while something happens on the phone.
struct MarqueeWaitingDots: View {
    var count: Int = 5
    var size: CGFloat = 12
    @State private var phase = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: size) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(Color.siloOnSurface.opacity(index <= phase ? 0.9 : 0.22))
                    .frame(width: size, height: size)
            }
        }
        .task {
            guard !reduceMotion else { phase = count / 2; return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(280))
                phase = (phase + 1) % (count + 1)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Setup steps

/// How to set this TV up from a phone: three numbered steps, one action
/// each, with a small picture of exactly that action. Short titles only, so
/// they read from across the room.
struct MarqueeTVSetupSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            step(1, "Open Silo on your phone") { SetupAppIcon() }
            step(2, "Tap Set Up") { SetupCardPicture() }
            step(3, "Finish on your phone") { SetupDonePicture() }
        }
        .frame(width: 700, alignment: .leading)
    }

    private func step(_ number: Int, _ title: String, @ViewBuilder picture: () -> some View) -> some View {
        HStack(spacing: 34) {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
                .frame(width: 168, height: 168)
                .overlay { picture() }
                .overlay(alignment: .topLeading) {
                    Text("\(number)")
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundStyle(.black)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.siloOnSurface))
                        .shadow(color: .black.opacity(0.5), radius: 7, y: 6)
                        .offset(x: -16, y: -16)
                }
            Text(title)
                .font(.system(size: 38, weight: .bold))
                .kerning(-0.4)
                .foregroundStyle(Color.siloOnSurface)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(number): \(title)")
    }
}

/// The Silo app icon: the three-bar mark on black.
private struct SetupAppIcon: View {
    var body: some View {
        VStack(spacing: 3) {
            ForEach([Color.siloBrandBlue, .siloBrandRed, .siloBrandOrange], id: \.self) { color in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color)
                    .modifier(SkewY(angle: .degrees(-18)))
            }
        }
        .frame(width: 26, height: 56)
        .frame(width: 92, height: 92)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
    }
}

/// The setup card Silo shows on a nearby phone, with its Set Up button ringed.
private struct SetupCardPicture: View {
    var body: some View {
        VStack(spacing: 8) {
            Capsule().fill(Color.white.opacity(0.3)).frame(width: 80, height: 8)
            Capsule().fill(Color.white.opacity(0.16)).frame(width: 56, height: 8)
            Text("Set Up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(Capsule().fill(Color.siloOnSurface))
                .overlay(Capsule().strokeBorder(Color.siloBrandOrange.opacity(0.85), lineWidth: 4).padding(-4))
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: 128)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(white: 0.15).opacity(0.95)))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

/// A green check: the rest happens on the phone.
private struct SetupDonePicture: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 44, weight: .bold))
            .foregroundStyle(Color.siloSuccess)
            .frame(width: 96, height: 96)
            .background(Circle().fill(Color.siloSuccess.opacity(0.16)))
            .overlay(Circle().strokeBorder(Color.siloSuccess, lineWidth: 3))
    }
}

/// Slants a view vertically about its center, like CSS `skewY`.
private struct SkewY: GeometryEffect {
    var angle: Angle

    func effectValue(size: CGSize) -> ProjectionTransform {
        let slope = CGFloat(tan(angle.radians))
        return ProjectionTransform(CGAffineTransform(a: 1, b: slope, c: 0, d: 1, tx: 0, ty: -size.width / 2 * slope))
    }
}

// MARK: - Card states

/// A large symbol in a glass circle, for card states without a QR or code.
struct MarqueeTVCardSymbol: View {
    let systemImage: String
    var tint: Color = .siloOnSurface
    var size: CGFloat = 112

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.white.opacity(0.08)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.14)))
            .accessibilityHidden(true)
    }
}

/// Body copy at TV size, secondary ink.
struct MarqueeTVBody: View {
    let text: String
    let size: CGFloat

    init(_ text: String, size: CGFloat = MarqueeMetrics.leadFont) {
        self.text = text
        self.size = size
    }

    var body: some View {
        Text(text)
            .font(.system(size: size))
            .foregroundStyle(Color.siloOnSurface.opacity(0.62))
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Focus helpers

extension View {
    /// Gives a page its first focus when nothing holds it. `defaultFocus`
    /// alone leaves a freshly launched setup screen with no focus at all, so
    /// the remote does nothing until a swipe. Never overrides a focus the
    /// person or the page already set.
    func marqueeTVSeedFocus<F: Hashable>(_ focus: FocusState<F?>.Binding, _ value: F) -> some View {
        task {
            await Task.yield()
            if focus.wrappedValue == nil { focus.wrappedValue = value }
        }
    }

    /// Moves focus after Done on the system keyboard. Each field's
    /// `onSubmit` sets `pending` to where focus goes next. While the keyboard
    /// is up nothing in the page has focus; closing it hands focus back to a
    /// field (after Next chains keyboards, the first one), and moving earlier
    /// gets overwritten. So the first focus that returns takes `pending`.
    func marqueeTVFocusAfterKeyboard<F: Hashable>(_ focus: FocusState<F?>.Binding, pending: Binding<F?>) -> some View {
        modifier(FocusAfterKeyboard(focus: focus, pending: pending))
    }
}

private struct FocusAfterKeyboard<F: Hashable>: ViewModifier {
    var focus: FocusState<F?>.Binding
    @Binding var pending: F?

    func body(content: Content) -> some View {
        content
            .onChange(of: focus.wrappedValue) { _, current in
                guard current != nil, let next = pending else { return }
                pending = nil
                focus.wrappedValue = next
            }
            .task(id: pending) {
                guard pending != nil else { return }
                // Submitted without the full-screen keyboard: focus never
                // left, so move now. A newer submit cancels this task; only
                // the current one may act on `pending`.
                await Task.yield()
                guard !Task.isCancelled else { return }
                if focus.wrappedValue != nil, let next = pending {
                    pending = nil
                    focus.wrappedValue = next
                    return
                }
                // A keyboard that never hands focus back must not make a
                // later, deliberate move jump away.
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard !Task.isCancelled else { return }
                pending = nil
            }
    }
}
#endif
