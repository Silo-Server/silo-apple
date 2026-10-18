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

    /// djb2 over the id's UTF-8, so a profile keeps its tint across launches.
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

    private var scale: CGFloat { size / tileSize }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                ProfileAvatar(profile: profile, serverURL: ServerRegistry.shared.activeServerUrl, size: size)
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

/// One profile's round avatar as Who's Watching draws it: the profile's tint
/// as a lit sphere, with its picture, emoji, or initial. The user cards draw
/// it too, for profiles of a server that need not be the active one, so a
/// server-relative picture loads from `serverURL`.
struct ProfileAvatar: View {
    /// The profile's ID, which picks its tint.
    let id: String
    let name: String
    let avatarEmoji: String?
    let avatarImageUrl: String?
    /// The address of the server the profile belongs to.
    let serverURL: String?
    let size: CGFloat
    /// The initial's size as a share of the diameter; nil draws it as Who's
    /// Watching does. The user cards keep their slightly larger initial.
    var initialScale: CGFloat? = nil
    /// The emoji or initial shows until the picture has loaded, and stays
    /// when it can't load (the user cards on iPhone, iPad and Mac).
    /// Otherwise the picture's own placeholder shows meanwhile.
    var showsFallbackUntilLoaded = false

    @State private var loadedURL: String?

    var body: some View {
        let tint = ProfileTilePalette.tint(for: id)
        let imageURL = ProfileAvatarResolver.imageURL(avatarImageUrl: avatarImageUrl, avatarEmoji: avatarEmoji,
                                                      serverURL: serverURL)
        ZStack {
            Circle().fill(
                RadialGradient(
                    colors: [tint.mix(with: .white, by: 0.35), tint, tint.mix(with: .black, by: 0.45)],
                    center: UnitPoint(x: 0.3, y: 0.25),
                    startRadius: 0,
                    endRadius: size * 0.8
                )
            )
            if let imageURL {
                if showsFallbackUntilLoaded {
                    if loadedURL != imageURL { fallback }
                    AsyncImageView(
                        url: imageURL,
                        contentMode: .fill,
                        placeholderStyle: .clear,
                        onImageLoaded: { loadedURL = imageURL }
                    )
                    .frame(width: size, height: size)
                    .id(imageURL)
                } else {
                    AsyncImageView(url: imageURL, contentMode: .fill)
                        .frame(width: size, height: size)
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }

    @ViewBuilder
    private var fallback: some View {
        if let emoji = ProfileAvatarResolver.emoji(avatarEmoji) {
            Text(emoji)
                .font(.system(size: size * (emojiSize / tileSize)))
        } else {
            Text(ProfileAvatarResolver.initial(of: name))
                .font(.system(size: size * (initialScale ?? initialSize / tileSize), weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
        }
    }
}

extension ProfileAvatar {
    init(profile: UserProfile, serverURL: String?, size: CGFloat) {
        self.init(id: profile.id, name: profile.name, avatarEmoji: profile.avatarEmoji,
                  avatarImageUrl: profile.avatarImageUrl, serverURL: serverURL, size: size)
    }

    init(profile: SavedSignInProfile, serverURL: String?, size: CGFloat, initialScale: CGFloat? = nil,
         showsFallbackUntilLoaded: Bool = false) {
        self.init(id: profile.id, name: profile.name, avatarEmoji: profile.avatarEmoji,
                  avatarImageUrl: profile.avatarImageUrl, serverURL: serverURL, size: size,
                  initialScale: initialScale, showsFallbackUntilLoaded: showsFallbackUntilLoaded)
    }
}

/// Turns a profile's avatar ref or `avatar_url` into a loadable image URL.
enum ProfileAvatarResolver {
    /// The picture an avatar loads: the server's `avatar_url`, else an image
    /// reference in `avatarEmoji`, with server-relative paths read on
    /// `serverURL`. Nil draws the emoji or initial.
    static func imageURL(avatarImageUrl: String?, avatarEmoji: String?, serverURL: String?) -> String? {
        if let url = serverResolvedImageURL(avatarImageUrl, serverURL: serverURL) { return url }
        guard let avatar = avatarEmoji?.trimmingCharacters(in: .whitespacesAndNewlines), isImage(avatar) else {
            return nil
        }
        return imageURL(for: avatar, serverURL: serverURL)
    }

    /// An emoji avatar, as opposed to an image reference. An `upload:` ref
    /// is only loadable through `avatar_url`.
    static func emoji(_ value: String?) -> String? {
        guard let avatar = value?.trimmingCharacters(in: .whitespacesAndNewlines), !avatar.isEmpty,
              !isImage(avatar), !avatar.lowercased().hasPrefix("upload:") else { return nil }
        return avatar
    }

    static func initial(of name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        return String(trimmed.prefix(1)).uppercased()
    }

    /// Resolve the server-supplied `avatar_url` against the active server.
    static func serverResolvedImageURL(_ value: String?) -> String? {
        serverResolvedImageURL(value, serverURL: ServerRegistry.shared.activeServerUrl)
    }

    /// Resolve the server-supplied `avatar_url`. Absolute URLs (presigned
    /// upload URLs, DiceBear) are used verbatim; a server-relative path is
    /// prefixed with `serverURL`. Returns nil when absent or when no server
    /// is known for a relative path.
    static func serverResolvedImageURL(_ value: String?, serverURL: String?) -> String? {
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

        guard trimmed.hasPrefix("/"), let base = baseURL(serverURL) else { return nil }
        return base + trimmed
    }

    static func isImage(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.hasPrefix("preset:dicebear:")
            || lowercased.contains("/")
            || lowercased.contains(".png")
            || lowercased.contains(".jpg")
            || lowercased.contains(".jpeg")
            || lowercased.contains(".webp")
            || lowercased.contains(".gif")
            || lowercased.contains(".svg")
            || lowercased.contains(".avif")
    }

    /// An avatar ref's image URL, with paths read on the active server.
    static func imageURL(for value: String) -> String? {
        imageURL(for: value, serverURL: ServerRegistry.shared.activeServerUrl)
    }

    static func imageURL(for value: String, serverURL: String?) -> String? {
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
            guard let base = baseURL(serverURL) else { return nil }
            if value.hasPrefix("/") { return base + value }
            return base + "/" + value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return value
    }

    /// `serverURL` without surrounding whitespace or slashes; nil when empty.
    private static func baseURL(_ serverURL: String?) -> String? {
        let base = (serverURL ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return base.isEmpty ? nil : base
    }

    private static func diceBearURL(for value: String) -> String? {
        guard value.lowercased().hasPrefix("preset:dicebear:") else { return nil }
        let parts = value.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let style = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = String(parts[3]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !style.isEmpty, !seed.isEmpty else { return nil }
        return ProfileAvatarPresets.imageURL(styleId: style, seed: seed)
    }
}
