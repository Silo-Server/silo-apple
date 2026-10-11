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

        let seriesPoster = await seriesPosterURL(for: detail)
        // Marked resolved only once the series lookup finishes, so an
        // interrupted lookup runs again when the task restarts.
        guard !Task.isCancelled else { return }
        if let seriesPoster { tilePosterURL = seriesPoster }
        resolvedContentId = contentId
    }

    private func seriesPosterURL(for detail: ItemDetail) async -> String? {
        guard SiloMediaType.isEpisode(detail.type),
              let seriesId = detail.seriesId, !seriesId.isEmpty else { return nil }
        let key = CacheKey.itemDetail(seriesId)
        let series: ItemDetail
        if let cached: ItemDetail = ResponseCache.shared.get(key) {
            series = cached
        } else {
            let writeToken = ResponseCache.shared.writeToken
            guard let fetched = try? await MetadataRequestPool.shared.itemDetail(contentId: seriesId) else {
                return nil
            }
            ResponseCache.shared.set(fetched, for: key, fetchedAt: writeToken)
            series = fetched
        }
        guard let poster = series.posterUrl, !poster.isEmpty else { return nil }
        return poster
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
