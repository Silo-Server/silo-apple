import SwiftUI

// MARK: - Scene state
//
// One backdrop sits behind the whole first-run flow and survives screen
// changes, so screens never cut it. Screens describe where the flow is
// through this shared scene; the backdrop moves between those states.

@MainActor
@Observable
final class MarqueeScene {
    static let shared = MarqueeScene()

    enum Focus: Equatable {
        /// Server and sign-in screens.
        case account
        /// Profile selection and PIN.
        case profiles
    }

    /// False until a server is confirmed.
    private(set) var serverConfirmed = false
    /// The confirmed server's accent, clamped to a dark, low-saturation tint.
    private(set) var accent: Color?
    var focus: Focus = .account
    /// Overrides the accent tint on screens that are about one person (PIN,
    /// a pressed profile).
    var personalTint: Color?

    /// Where the flow is, as a value the backdrop moves through: 0 choosing
    /// a server, 1 signing in, 2 choosing a profile.
    var stage: Double {
        guard serverConfirmed else { return 0 }
        return focus == .profiles ? 2 : 1
    }

    /// Applies a confirmed server's branding. Called after the server answers,
    /// and again from the saved copy on relaunch so the backdrop never jumps.
    func showServer(_ branding: ServerBranding?) {
        serverConfirmed = true
        accent = branding?.accentColor.flatMap(Self.clampedAccent)
    }

    /// The active server's last known branding, without a network round trip.
    func showActiveServer() {
        showServer(ServerBrandingCache.branding(for: AuthService.shared.serverUrl))
    }

    /// Back to the pre-connect state (sign out, change server).
    func showGeneric() {
        serverConfirmed = false
        accent = nil
        focus = .account
        personalTint = nil
    }

    /// Admin-chosen accents can be anything; keep the tint dark enough that
    /// form text over it stays legible.
    static func clampedAccent(_ hex: String) -> Color? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^#?[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil else { return nil }
        #if canImport(UIKit)
        let base = UIColor(Color(hex: trimmed.hasPrefix("#") ? trimmed : "#" + trimmed))
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        guard base.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha) else { return nil }
        return Color(hue: hue, saturation: min(sat, 0.7), brightness: min(max(bri, 0.45), 0.8))
        #else
        let base = NSColor(Color(hex: trimmed.hasPrefix("#") ? trimmed : "#" + trimmed)).usingColorSpace(.sRGB)
        guard let base else { return nil }
        return Color(
            hue: base.hueComponent,
            saturation: min(base.saturationComponent, 0.7),
            brightness: min(max(base.brightnessComponent, 0.45), 0.8)
        )
        #endif
    }
}

// MARK: - Backdrop

/// Brand light plus tint. Place it once, behind the first-run navigation, and
/// make screens transparent over it.
struct MarqueeBackdrop: View {
    private var scene = MarqueeScene.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                BrandLightLayer(stage: scene.stage, drifts: drifts)
                    #if os(tvOS)
                    // TV copy sits on the left under the darkest scrim; pool
                    // the light on the right, behind the card.
                    .scaleEffect(x: -1, y: 1)
                    #endif
                    // Moving forward reads as the light moving, not a crossfade.
                    .animation(reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 1.4), value: scene.stage)
                if let tint = scene.personalTint ?? scene.accent {
                    RadialGradient(
                        colors: [tint.opacity(0.32), tint.opacity(0)],
                        center: UnitPoint(x: 0.5, y: 0.16),
                        startRadius: 0,
                        endRadius: max(geo.size.width, geo.size.height) * 0.7
                    )
                    .transition(.opacity)
                }
                MarqueeGrain()
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 0.6), value: scene.personalTint)
        .animation(.easeInOut(duration: 0.6), value: scene.accent)
    }

    private var drifts: Bool {
        !reduceMotion && !DevicePower.isLowPowerAppleTV
    }
}

// MARK: - Brand light

/// Interpolates between per-stage values (0 server, 1 sign-in, 2 profiles).
private func staged<T>(_ values: [T], _ stage: Double, _ mix: (T, T, Double) -> T) -> T {
    let s = min(max(stage, 0), Double(values.count - 1))
    let i = min(Int(s), values.count - 2)
    return mix(values[i], values[i + 1], s - Double(i))
}

private extension Color {
    func dimmed(_ amount: Double) -> Color { mix(with: .black, by: amount) }
}

/// The mark's three colors as slow pools of light over black: one cool pool
/// while choosing a server, all three once it answers, and a warm room that
/// reaches lower behind the profiles.
struct BrandLightLayer: View, Animatable {
    var stage: Double
    var drifts: Bool

    var animatableData: Double {
        get { stage }
        set { stage = newValue }
    }

    var body: some View {
        if drifts {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                mesh(phase: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            mesh(phase: 0)
        }
    }

    private static let blue = Color.siloBrandBlue
    private static let red = Color.siloBrandRed
    private static let orange = Color.siloBrandOrange

    /// Row-major 3×3 mesh colors for each stage.
    private static let palettes: [[Color]] = [
        [
            blue.dimmed(0.46), blue.dimmed(0.7), red.dimmed(0.8),
            blue.dimmed(0.8), blue.dimmed(0.86), red.dimmed(0.92),
            .black, .black, .black,
        ],
        [
            blue.dimmed(0.5), red.dimmed(0.58), orange.dimmed(0.58),
            blue.dimmed(0.76), red.dimmed(0.74), orange.dimmed(0.82),
            .black, .black, .black,
        ],
        [
            red.dimmed(0.56), orange.dimmed(0.52), blue.dimmed(0.56),
            orange.dimmed(0.7), red.dimmed(0.66), blue.dimmed(0.72),
            blue.dimmed(0.9), red.dimmed(0.9), orange.dimmed(0.92),
        ],
    ]

    private func mesh(phase: TimeInterval) -> some View {
        // Two incommensurate periods so the drift never visibly loops.
        let a = Float(sin(phase / 13.0))
        let b = Float(cos(phase / 19.0))
        let lerp: (Float, Float, Double) -> Float = { $0 + ($1 - $0) * Float($2) }
        let middle = staged([0.42, 0.5, 0.6], stage, lerp)
        let centerX = staged([0.3, 0.55, 0.5], stage, lerp)
        let colors = (0..<9).map { index in
            staged(Self.palettes.map { $0[index] }, stage) { $0.mix(with: $1, by: $2) }
        }

        return MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5 + 0.12 * a, 0], [1, 0],
                [0, middle + 0.06 * b], [centerX + 0.1 * b, middle - 0.08 * a], [1, middle - 0.06 * a],
                [0, 1], [0.5 - 0.1 * b, 1], [1, 1],
            ],
            colors: colors
        )
    }
}

// MARK: - Grain

/// Fine noise over the light: hides banding in near-black ramps and gives it
/// a filmic texture.
struct MarqueeGrain: View {
    private static let tile: Image? = {
        let side = 96
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        var state: UInt32 = 0x9E37_79B9
        for pixel in 0..<(side * side) {
            state = state &* 1_664_525 &+ 1_013_904_223
            let value = UInt8(truncatingIfNeeded: state >> 24)
            // Premultiplied white: color equals alpha.
            bytes[pixel * 4] = value
            bytes[pixel * 4 + 1] = value
            bytes[pixel * 4 + 2] = value
            bytes[pixel * 4 + 3] = value
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        return Image(decorative: image, scale: 2)
    }()

    var body: some View {
        if let tile = Self.tile {
            Rectangle()
                .fill(ImagePaint(image: tile))
                .opacity(0.045)
        }
    }
}

// MARK: - Scrims

/// Darkening laid over the backdrop by each screen so text always sits on at least
/// 86% black. Screens choose the shape that fits their layout.
enum MarqueeScrimStyle {
    /// Phone and narrow windows: content anchored to the bottom.
    case bottom
    /// Same, darker higher up, for screens with more controls.
    case bottomDeep
    /// Profiles and PIN: lighter, ambient.
    case ambient
    /// TV and wide windows: copy on the left, art on the right.
    case leading
}

struct MarqueeScrim: View {
    let style: MarqueeScrimStyle
    /// Where the frosted band begins, as a fraction of the height. Nil for none.
    var frostStart: CGFloat?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geo in
            ZStack {
                gradient
                if let frostStart {
                    // A soft extra darkening where the controls sit. A system
                    // material here reads grey over black, so this stays a
                    // plain black band.
                    Color.black
                        .opacity(reduceTransparency ? 0.85 : 0.35)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: frostStart),
                                    .init(color: .black, location: min(1, frostStart + 130 / max(geo.size.height, 1))),
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var gradient: some View {
        switch style {
        case .bottom:
            LinearGradient(stops: [
                .init(color: .black.opacity(0.62), location: 0),
                .init(color: .black.opacity(0.08), location: 0.15),
                .init(color: .black.opacity(0.25), location: 0.34),
                .init(color: .black.opacity(0.86), location: 0.58),
                .init(color: .black, location: 0.8),
            ], startPoint: .top, endPoint: .bottom)
        case .bottomDeep:
            LinearGradient(stops: [
                .init(color: .black.opacity(0.62), location: 0),
                .init(color: .black.opacity(0.2), location: 0.14),
                .init(color: .black.opacity(0.55), location: 0.32),
                .init(color: .black.opacity(0.92), location: 0.5),
                .init(color: .black, location: 0.7),
            ], startPoint: .top, endPoint: .bottom)
        case .ambient:
            LinearGradient(stops: [
                .init(color: .black.opacity(0.35), location: 0),
                .init(color: .black.opacity(0.2), location: 0.25),
                .init(color: .black.opacity(0.75), location: 0.55),
                .init(color: .black, location: 0.78),
            ], startPoint: .top, endPoint: .bottom)
        case .leading:
            ZStack {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.8), location: 0),
                    .init(color: .black.opacity(0.55), location: 0.3),
                    .init(color: .black.opacity(0.2), location: 0.58),
                    .init(color: .black.opacity(0.1), location: 0.8),
                    .init(color: .black.opacity(0.3), location: 1),
                ], startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.5), location: 0),
                    .init(color: .clear, location: 0.35),
                ], startPoint: .bottom, endPoint: .top)
            }
        }
    }
}
