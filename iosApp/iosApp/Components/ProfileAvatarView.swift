import SwiftUI

struct ProfileAvatarView: View {
    let avatar: String?
    let name: String
    var size: CGFloat
    var backgroundColor: Color = .siloSurfaceVariant
    var textColor: Color = .siloOnSurface

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)
                .frame(width: size, height: size)

            if let imageURL = resolvedImageURL {
                AsyncImageView(url: imageURL, contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else if let displayAvatar = displayAvatarText {
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
        .frame(width: size, height: size)
    }

    private var displayAvatarText: String? {
        guard let trimmedAvatar = avatar?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedAvatar.isEmpty,
              !ProfileAvatarResolver.isImage(trimmedAvatar) else {
            return nil
        }
        return trimmedAvatar
    }

    private var resolvedImageURL: String? {
        guard let trimmedAvatar = avatar?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedAvatar.isEmpty,
              ProfileAvatarResolver.isImage(trimmedAvatar) else {
            return nil
        }
        return ProfileAvatarResolver.imageURL(for: trimmedAvatar, size: 256)
    }

    private var fontSize: CGFloat {
        size * 0.45
    }
}
