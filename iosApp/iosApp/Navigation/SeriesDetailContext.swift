import Foundation

/// Selection carried into the single Series page from a season or episode link.
struct SeriesDetailContext: Hashable {
    let seriesContentId: String
    let episodeContentId: String?
    let seasonNumber: Int?

    init(seriesContentId: String, episodeContentId: String?, seasonNumber: Int?) {
        self.seriesContentId = seriesContentId
        self.episodeContentId = episodeContentId
        self.seasonNumber = seasonNumber
    }

    init?(item: SectionItem) {
        guard item.type.lowercased() == "episode" || item.episodeNumber != nil,
              let seriesId = Self.parentID(item.seriesId, childID: item.contentId) else { return nil }
        self.init(seriesContentId: seriesId, episodeContentId: item.contentId, seasonNumber: item.seasonNumber)
    }

    init?(detail: ItemDetail) {
        guard detail.type == "episode" || detail.type == "season",
              let seriesId = Self.parentID(detail.seriesId, childID: detail.contentId) else { return nil }
        self.init(
            seriesContentId: seriesId,
            episodeContentId: detail.type == "episode" ? detail.contentId : nil,
            seasonNumber: detail.seasonNumber
        )
    }

    private static func parentID(_ value: String?, childID: String) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value != childID else { return nil }
        return value
    }
}
