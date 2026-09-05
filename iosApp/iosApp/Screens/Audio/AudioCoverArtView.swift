import SwiftUI

/// Square audiobook cover with the standard placeholder treatment,
/// shared by the mini player and the full player.
struct AudioCoverArtView: View {
    let urlString: String?
    var cornerRadius: CGFloat = 12

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.siloSurfaceElevated)
            if let urlString, !urlString.isEmpty {
                AsyncImageView(url: urlString, contentMode: .fill)
            } else {
                Image(systemName: "book.closed")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
