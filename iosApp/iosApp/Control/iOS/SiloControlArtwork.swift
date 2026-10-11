#if os(iOS)
import SwiftUI

/// Resolves poster/backdrop artwork for the TV remote from the `contentId`
/// already present in the control playback state — no wire-protocol field needed.
/// Reuses the same item-detail path (cache → API) the detail screen uses.
@MainActor
@Observable
final class SiloControlArtworkResolver {
    private(set) var posterURL: String?
    private(set) var backdropURL: String?
    /// 2:3 artwork for small tiles. An episode's own poster is its 16:9 still,
    /// so episodes use the series poster when one is available.
    private(set) var tilePosterURL: String?
    private var resolvedContentId: String?

    func resolve(contentId: String?) async {
        guard let contentId, !contentId.isEmpty else {
            posterURL = nil
            backdropURL = nil
            tilePosterURL = nil
            resolvedContentId = nil
            return
        }
        guard contentId != resolvedContentId else { return }

        let detail: ItemDetail
        if let cached: ItemDetail = ResponseCache.shared.get(CacheKey.itemDetail(contentId)) {
            detail = cached
        } else {
            // Drop the previous title's artwork while this one loads.
            posterURL = nil
            backdropURL = nil
            tilePosterURL = nil
            resolvedContentId = nil
            do {
                detail = try await SiloAPI.shared.itemDetail(contentId: contentId)
                try Task.checkCancellation()
            } catch {
                // Degrade silently: the remote simply shows the flat background.
                return
            }
        }
        posterURL = detail.posterUrl
        backdropURL = detail.backdropUrl
        tilePosterURL = detail.posterUrl
        resolvedContentId = contentId

        guard SiloMediaType.isEpisode(detail.type),
              let seriesId = detail.seriesId, !seriesId.isEmpty,
              let seriesPoster = await seriesPosterURL(seriesId: seriesId),
              !Task.isCancelled, resolvedContentId == contentId else { return }
        tilePosterURL = seriesPoster
    }

    private func seriesPosterURL(seriesId: String) async -> String? {
        if let cached: ItemDetail = ResponseCache.shared.get(CacheKey.itemDetail(seriesId)) {
            return cached.posterUrl
        }
        return try? await SiloAPI.shared.itemDetail(contentId: seriesId).posterUrl
    }
}

/// Full-bleed blurred-artwork backdrop behind the now-playing content.
/// Falls back to flat OLED black when no artwork is available.
struct SiloControlArtworkBackground: View {
    let urlString: String?

    var body: some View {
        ZStack {
            Color.siloBackground
            if let urlString, !urlString.isEmpty {
                AsyncImageView(url: urlString, contentMode: .fill, placeholderStyle: .clear)
                    .id(urlString)
                    .blur(radius: 40)
                    .opacity(0.45)
                    .clipped()
            }
            Color.siloBackground.opacity(0.55)
        }
        .ignoresSafeArea()
    }
}
#endif
