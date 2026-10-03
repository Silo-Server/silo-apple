import SwiftUI

/// Warm palette for profile tiles. The tint is the primary identity signal
/// — users recognize their profile by color before they recognize the
/// emoji. Saturation is kept under ~70% so the tiles read as "paper" in
/// front of pure-black, not as neon chips.
enum ProfileTilePalette {
    static let colors: [Color] = [
        Color(red: 0.850, green: 0.460, blue: 0.380),  // coral
        Color(red: 0.400, green: 0.560, blue: 0.720),  // slate blue
        Color(red: 0.690, green: 0.540, blue: 0.400),  // warm tan
        Color(red: 0.460, green: 0.620, blue: 0.520),  // sage
        Color(red: 0.780, green: 0.480, blue: 0.520),  // dusty rose
        Color(red: 0.560, green: 0.480, blue: 0.720),  // lavender
        Color(red: 0.360, green: 0.580, blue: 0.620),  // teal
        Color(red: 0.780, green: 0.640, blue: 0.380),  // amber
    ]

    /// Stable derivation from profile id. `hashValue` varies per-launch under
    /// some Swift versions but within a single launch it's consistent, which
    /// is enough — the screen regenerates each session.
    static func tint(for profileId: String) -> Color {
        var h: UInt64 = 5381
        for byte in profileId.utf8 {
            h = ((h << 5) &+ h) &+ UInt64(byte)
        }
        return colors[Int(h % UInt64(colors.count))]
    }
}

#if os(tvOS)
private let tileSize: CGFloat = 220
private let emojiSize: CGFloat = 110
private let initialSize: CGFloat = 96
private let nameSize: CGFloat = 30
private let metaSize: CGFloat = 20
private let nameSpacing: CGFloat = 26
private let focusScale: CGFloat = 1.12
private let lockSize: CGFloat = 56
private let kidsFont: CGFloat = 18
#else
private let tileSize: CGFloat = 92
private let emojiSize: CGFloat = 46
private let initialSize: CGFloat = 38
private let nameSize: CGFloat = 15
private let metaSize: CGFloat = 12
private let nameSpacing: CGFloat = 10
private let focusScale: CGFloat = 1.0
private let lockSize: CGFloat = 30
private let kidsFont: CGFloat = 11
#endif

/// One person in "Who's watching?": a round avatar like the cast rows on
/// detail pages, with lock and KIDS badges riding on the circle.
struct ProfileTile: View {
    let profile: UserProfile
    var isRemembered: Bool = false
    /// Avatar diameter. The picker sizes avatars to the household; badges
    /// and text scale with it.
    var size: CGFloat = tileSize
    /// Reports touch-down and release so the picker can tint the backdrop
    /// while a finger rests on a profile.
    var onPressChange: (Bool) -> Void = { _ in }
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        ProfileTilePalette.tint(for: profile.id)
    }

    private var scale: CGFloat { size / tileSize }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                avatar
                    .frame(width: size, height: size)
                    .overlay(alignment: .bottomTrailing) {
                        if profile.hasPin { lockBadge }
                    }
                    .overlay(alignment: .topTrailing) {
                        if profile.isChild { kidsBadge }
                    }
                    .background {
                        Circle()
                            .strokeBorder(Color.siloOnSurface, lineWidth: 6)
                            .padding(-12)
                            .opacity(isFocused ? 1 : 0)
                    }
                    .scaleEffect(isFocused && !reduceMotion ? focusScale : 1.0)
                    .shadow(color: .black.opacity(isFocused ? 0.6 : 0), radius: isFocused ? 30 : 0, y: isFocused ? 20 : 0)

                Text(profile.name)
                    .font(.system(size: scaledNameSize(size), weight: .semibold))
                    .foregroundStyle(isFocused ? Color.siloOnSurface : Color.siloOnSurface.opacity(nameOpacity))
                    .lineLimit(1)
                    .padding(.top, isFocused ? nameSpacing + 18 : nameSpacing)

                if isRemembered {
                    Text(rememberedBadgeLabel)
                        .font(.system(size: metaSize))
                        .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                        .lineLimit(1)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(ProfileTileButtonStyle(onPressChange: onPressChange))
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isFocused)
        .focused($isFocused)
        #if os(tvOS)
        .focusEffectDisabled()
        #endif
        .accessibilityLabel(profile.name)
        .accessibilityValue(accessibilityValue)
    }

    private var nameOpacity: Double {
        #if os(tvOS)
        0.62
        #else
        1.0
        #endif
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(
                RadialGradient(
                    colors: [tint.mix(with: .white, by: 0.35), tint, tint.mix(with: .black, by: 0.45)],
                    center: UnitPoint(x: 0.3, y: 0.25),
                    startRadius: 0,
                    endRadius: size * 0.8
                )
            )
            avatarContent
        }
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }

    @ViewBuilder
    private var avatarContent: some View {
        let avatar = profile.avatarEmoji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let serverURL = ProfileAvatarResolver.serverResolvedImageURL(profile.avatarImageUrl) {
            AsyncImageView(url: serverURL, contentMode: .fill)
                .frame(width: size, height: size)
        } else if ProfileAvatarResolver.isImage(avatar) {
            if let url = ProfileAvatarResolver.imageURL(for: avatar) {
                AsyncImageView(url: url, contentMode: .fill)
                    .frame(width: size, height: size)
            } else {
                initialFallback
            }
        } else if !avatar.isEmpty {
            Text(avatar)
                .font(.system(size: emojiSize * scale))
        } else {
            initialFallback
        }
    }

    private var initialFallback: some View {
        Text(initial)
            .font(.system(size: initialSize * scale, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.95))
    }

    private var initial: String {
        let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        return String(trimmed.prefix(1)).uppercased()
    }

    private var lockBadge: some View {
        let lockSize = lockSize * scale
        return Image(systemName: "lock.fill")
            .font(.system(size: lockSize * 0.42, weight: .semibold))
            .foregroundStyle(Color.siloOnSurface.opacity(0.75))
            .frame(width: lockSize, height: lockSize)
            .background(Circle().fill(Color(hex: "#1C1C1E")))
            .overlay(Circle().strokeBorder(Color.black, lineWidth: lockSize * 0.07))
            .offset(x: lockSize * 0.08, y: lockSize * 0.08)
            .accessibilityHidden(true)
    }

    private var kidsBadge: some View {
        let kidsFont = kidsFont * scale
        return Text("KIDS")
            .font(.system(size: kidsFont, weight: .heavy))
            .kerning(0.4)
            .foregroundStyle(.black)
            .padding(.horizontal, kidsFont * 0.75)
            .frame(height: kidsFont * 2)
            .background(Capsule().fill(Color.white))
            .offset(x: kidsFont * 0.5, y: -kidsFont * 0.2)
            .accessibilityHidden(true)
    }

    private var accessibilityValue: String {
        var values: [String] = []
        if isRemembered { values.append(rememberedAccessibilityValue) }
        if profile.hasPin { values.append("PIN protected") }
        if profile.isChild { values.append("Kids profile") }
        return values.joined(separator: ", ")
    }

    private var rememberedBadgeLabel: String {
        #if os(tvOS)
        "Apple TV user"
        #else
        "Last used"
        #endif
    }

    private var rememberedAccessibilityValue: String {
        #if os(tvOS)
        "Paired with this Apple TV user"
        #else
        "Last used"
        #endif
    }
}

/// Draws only the tile itself. `.plain` would add tvOS's square focus platter
/// behind the round avatar; the tile renders its own focus ring instead.
private struct ProfileTileButtonStyle: ButtonStyle {
    var onPressChange: (Bool) -> Void = { _ in }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .marqueePressHaptic(configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in onPressChange(pressed) }
    }
}

/// Names grow more slowly than avatars so large avatars keep short labels.
private func scaledNameSize(_ size: CGFloat) -> CGFloat {
    nameSize * (1 + (size / tileSize - 1) * 0.35)
}

struct AddProfileTile: View {
    var size: CGFloat = tileSize
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Circle()
                    .fill(Color.white.opacity(isFocused ? 0.14 : 0))
                    .overlay {
                        Circle()
                            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                            .foregroundStyle(Color.white.opacity(isFocused ? 0.7 : 0.25))
                    }
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: size * 0.3, weight: .light))
                            .foregroundStyle(Color.siloOnSurface.opacity(isFocused ? 1 : 0.4))
                    }
                    .frame(width: size, height: size)
                    .background {
                        Circle()
                            .strokeBorder(Color.siloOnSurface, lineWidth: 6)
                            .padding(-12)
                            .opacity(isFocused ? 1 : 0)
                    }
                    .scaleEffect(isFocused && !reduceMotion ? focusScale : 1.0)

                Text("Add profile")
                    .font(.system(size: scaledNameSize(size), weight: .semibold))
                    .foregroundStyle(Color.siloOnSurface.opacity(isFocused ? 1 : 0.62))
                    .padding(.top, isFocused ? nameSpacing + 18 : nameSpacing)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(ProfileTileButtonStyle())
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isFocused)
        .focused($isFocused)
        #if os(tvOS)
        .focusEffectDisabled()
        #endif
        .accessibilityLabel("Add profile")
    }
}

/// Helpers extracted from `ProfileAvatarView` so the tile can render
/// avatars in a tile shape rather than a circle. Kept as a small local
/// utility rather than adjusting the shared view's API surface.
enum ProfileAvatarResolver {
    /// Resolve the server-supplied `avatar_url`. Absolute URLs (presigned
    /// upload URLs, DiceBear) are used verbatim; a server-relative path is
    /// prefixed with the active server URL. Returns nil when absent or when
    /// no active server is known for a relative path.
    static func serverResolvedImageURL(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        let lowercased = trimmed.lowercased()

        // The Nuke pipeline registers no SVG decoder. Legacy presets use an
        // `.svg` extension, while DiceBear uses an `/svg` format path.
        // Decline both and let the caller's raw-ref fallback build a PNG URL.
        // Uploaded avatars are WebP and continue through this path.
        let pathOnly = lowercased.split(separator: "?", maxSplits: 1)[0]
        if pathOnly.hasSuffix(".svg") || pathOnly.hasSuffix("/svg") { return nil }

        if lowercased.hasPrefix("http://")
            || lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("data:image/")
            || lowercased.hasPrefix("file://") {
            return trimmed
        }

        guard trimmed.hasPrefix("/") else { return nil }
        let serverURL = ServerRegistry.shared.activeServerUrl
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !serverURL.isEmpty else { return nil }
        return serverURL + trimmed
    }

    static func isImage(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.hasPrefix("preset:dicebear:")
            || lowercased.hasPrefix("http://")
            || lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("data:image/")
            || lowercased.hasPrefix("content://")
            || lowercased.hasPrefix("file://")
            || lowercased.hasPrefix("/")
            || lowercased.contains("/")
            || lowercased.contains(".png")
            || lowercased.contains(".jpg")
            || lowercased.contains(".jpeg")
            || lowercased.contains(".webp")
            || lowercased.contains(".gif")
            || lowercased.contains(".svg")
            || lowercased.contains(".avif")
    }

    static func imageURL(for value: String) -> String? {
        if let diceBear = diceBearURL(for: value) { return diceBear }

        let lowercased = value.lowercased()
        if lowercased.hasPrefix("http://")
            || lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("data:image/")
            || lowercased.hasPrefix("content://")
            || lowercased.hasPrefix("file://") {
            return value
        }

        if value.hasPrefix("/") || value.contains("/") {
            let serverURL = ServerRegistry.shared.activeServerUrl
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !serverURL.isEmpty else { return nil }
            if value.hasPrefix("/") { return serverURL + value }
            return serverURL + "/" + value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return value
    }

    private static func diceBearURL(for value: String) -> String? {
        guard value.lowercased().hasPrefix("preset:dicebear:") else { return nil }
        let parts = value.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let style = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = String(parts[3]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !style.isEmpty, !seed.isEmpty else { return nil }
        let s = style.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? style
        let d = seed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? seed
        return "https://api.dicebear.com/9.x/\(s)/png?seed=\(d)&size=256"
    }
}
