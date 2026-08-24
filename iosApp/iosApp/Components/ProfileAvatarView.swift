import SwiftUI

struct ProfileAvatarView: View {
    private static let diceBearPresetPrefix = "preset:dicebear:"
    private static let diceBearBaseURL = "https://api.dicebear.com/9.x"

    let avatar: String?
    /// Server-resolved avatar URL (`avatar_url`). When present it wins over
    /// the client-side resolution of ``avatar``, which cannot resolve opaque
    /// `upload:` refs. Absolute URLs are used verbatim; a leading-slash path
    /// is resolved against the active server.
    var imageUrl: String? = nil
    let name: String
    var size: CGFloat
    var backgroundColor: Color = .continuumSurfaceVariant
    var textColor: Color = .continuumOnSurface

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)
                .frame(width: size, height: size)

            // The text/initial fallback is layered beneath the image so that a
            // failed load — e.g. an expired presigned `avatar_url` — degrades
            // to it instead of an error placeholder: `.clear` style renders
            // nothing on both the loading and error branches.
            if let displayAvatar = displayAvatarText {
                Text(displayAvatar)
                    .font(.system(size: fontSize))
            } else if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased())
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundColor(textColor)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.36))
                    .foregroundColor(.continuumSecondaryText)
            }

            if let imageURL = resolvedImageURL {
                AsyncImageView(url: imageURL, contentMode: .fill, placeholderStyle: .clear)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
    }

    private var displayAvatarText: String? {
        guard let trimmedAvatar = avatar?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedAvatar.isEmpty,
              !trimmedAvatar.lowercased().hasPrefix("upload:"),
              !isImageAvatar(trimmedAvatar) else {
            return nil
        }
        return trimmedAvatar
    }

    private var resolvedServerImageURL: String? {
        ProfileAvatarResolver.serverResolvedImageURL(imageUrl)
    }

    private var resolvedImageURL: String? {
        if let serverURL = resolvedServerImageURL { return serverURL }

        guard let trimmedAvatar = avatar?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedAvatar.isEmpty,
              isImageAvatar(trimmedAvatar) else {
            return nil
        }

        if let diceBearURL = resolveDiceBearPresetURL(trimmedAvatar) {
            return diceBearURL
        }

        let lowercased = trimmedAvatar.lowercased()
        if lowercased.hasPrefix("http://")
            || lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("data:image/")
            || lowercased.hasPrefix("content://")
            || lowercased.hasPrefix("file://") {
            return trimmedAvatar
        }

        if trimmedAvatar.hasPrefix("/") || trimmedAvatar.contains("/") {
            let serverURL = ServerRegistry.shared.activeServerUrl
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !serverURL.isEmpty else { return nil }
            if trimmedAvatar.hasPrefix("/") {
                return serverURL + trimmedAvatar
            }
            return serverURL + "/" + trimmedAvatar.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        return trimmedAvatar
    }

    private var fontSize: CGFloat {
        size * 0.45
    }

    private func isImageAvatar(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.hasPrefix(Self.diceBearPresetPrefix)
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

    private func resolveDiceBearPresetURL(_ value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedValue.lowercased().hasPrefix(Self.diceBearPresetPrefix) else {
            return nil
        }

        let parts = trimmedValue.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }

        let style = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = String(parts[3]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !style.isEmpty, !seed.isEmpty else { return nil }

        let encodedStyle = style.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? style
        let encodedSeed = seed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? seed
        return "\(Self.diceBearBaseURL)/\(encodedStyle)/png?seed=\(encodedSeed)&size=256"
    }
}
