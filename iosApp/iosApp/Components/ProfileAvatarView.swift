import SwiftUI

struct ProfileAvatarView: View {
    let avatar: String?
    /// Server-resolved avatar URL (`avatar_url`). When present it wins over
    /// the client-side resolution of ``avatar``, which cannot resolve opaque
    /// `upload:` refs. Absolute URLs are used verbatim; a leading-slash path
    /// is resolved against the active server.
    var imageUrl: String? = nil
    let name: String
    var size: CGFloat
    var backgroundColor: Color = .siloSurfaceVariant
    var textColor: Color = .siloOnSurface
    @State private var loadedImageURL: String?

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)
                .frame(width: size, height: size)

            // Keep the fallback visible while loading or after an error, then
            // remove it once the image succeeds. Leaving it permanently under
            // transparent avatar artwork makes the initial show through.
            if resolvedImageURL == nil || loadedImageURL != resolvedImageURL {
                fallbackAvatar
            }

            if let imageURL = resolvedImageURL {
                AsyncImageView(
                    url: imageURL,
                    contentMode: .fill,
                    placeholderStyle: .clear,
                    onImageLoaded: { loadedImageURL = imageURL }
                )
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .id(imageURL)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var fallbackAvatar: some View {
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
                .foregroundColor(.siloSecondaryText)
        }
    }

    private var displayAvatarText: String? {
        guard let trimmedAvatar = avatar?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedAvatar.isEmpty,
              !trimmedAvatar.lowercased().hasPrefix("upload:"),
              !ProfileAvatarResolver.isImage(trimmedAvatar) else {
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
              ProfileAvatarResolver.isImage(trimmedAvatar) else {
            return nil
        }

        return ProfileAvatarResolver.imageURL(for: trimmedAvatar)
    }

    private var fontSize: CGFloat {
        size * 0.45
    }
}
