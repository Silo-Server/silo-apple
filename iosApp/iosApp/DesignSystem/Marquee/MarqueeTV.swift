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

// MARK: - Mini iPhone

/// The setup card as it appears in Silo on a nearby iPhone, drawn small on
/// the TV so people know what to look for.
struct MarqueeMiniPhone: View {
    let tvName: String

    var body: some View {
        ZStack(alignment: .bottom) {
            // The iPhone app's own backdrop, still, as it looks behind the
            // setup card.
            BrandLightLayer(stage: 1, drifts: false)
                .clipShape(RoundedRectangle(cornerRadius: 50, style: .continuous))

            VStack(spacing: 0) {
                Image(systemName: "appletv")
                    .font(.system(size: 26))
                    .frame(width: 60, height: 60)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.14)))
                Text("Set Up \(tvName)")
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 14)
                Text("Sign this Apple TV in with your Silo account.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.siloOnSurface.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                Capsule()
                    .fill(Color.siloOnSurface)
                    .frame(height: 46)
                    .overlay(Text("Set Up").font(.system(size: 18, weight: .semibold)).foregroundStyle(.black))
                    .padding(.top, 16)
                Text("Not Now")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.siloOnSurface.opacity(0.62))
                    .frame(height: 40)
            }
            .foregroundStyle(Color.siloOnSurface)
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 10)
            .background(RoundedRectangle(cornerRadius: 40, style: .continuous).fill(Color(white: 0.18).opacity(0.96)))
            .padding(10)
        }
        .frame(width: 280, height: 560)
        .clipShape(RoundedRectangle(cornerRadius: 50, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 50, style: .continuous).strokeBorder(Color(white: 0.12), lineWidth: 8))
        .shadow(color: .black.opacity(0.8), radius: 40, y: 20)
        .accessibilityHidden(true)
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
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: MarqueeMetrics.leadFont))
            .foregroundStyle(Color.siloOnSurface.opacity(0.62))
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
