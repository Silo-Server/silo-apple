import Foundation

/// Maps API item shapes onto the flat `OverlayData` bag the renderer
/// reads. Each `.from(...)` factory pulls only the fields the registry
/// uses; everything else stays in the original item and is ignored.
///
/// Server-side overlays (resolution/HDR/audio/…) are sourced from
/// `OverlaySummary`. Ratings, metadata, and ribbons come from item
/// top-level fields. Anything missing falls through to `nil` and the
/// registry's `getValue` returns `nil`, hiding the badge.
extension OverlayData {

    static func from(_ item: BrowseItem) -> OverlayData {
        var data = OverlayData()
        applySummary(item.overlaySummary, into: &data)
        data.ratingImdb        = item.ratingImdb
        data.ratingTmdb        = item.ratingTmdb
        data.ratingRtCritic    = item.ratingRtCritic
        data.ratingRtAudience  = item.ratingRtAudience
        data.contentRating     = item.contentRating
        data.year              = item.year
        data.runtime           = item.runtime
        data.originalLanguage  = item.originalLanguage
        data.studio            = firstNonEmpty(item.studios)
        data.network           = firstNonEmpty(item.networks)
        data.showStatus        = item.showStatus
        return data
    }

    static func from(_ item: SectionItem) -> OverlayData {
        var data = OverlayData()
        applySummary(item.overlaySummary, into: &data)
        data.ratingImdb        = item.ratingImdb
        data.ratingTmdb        = item.ratingTmdb
        data.ratingRtCritic    = item.ratingRtCritic
        data.ratingRtAudience  = item.ratingRtAudience
        data.contentRating     = item.contentRating
        data.year              = item.year
        data.runtime           = item.runtime
        data.originalLanguage  = item.originalLanguage
        data.studio            = firstNonEmpty(item.studios)
        data.network           = firstNonEmpty(item.networks)
        data.showStatus        = item.showStatus
        return data
    }

    static func from(_ detail: ItemDetail) -> OverlayData {
        var data = OverlayData()
        applySummary(detail.overlaySummary, into: &data)
        data.ratingImdb        = detail.ratingImdb
        data.ratingTmdb        = detail.ratingTmdb
        data.ratingRtCritic    = detail.ratingRtCritic
        data.ratingRtAudience  = detail.ratingRtAudience
        data.contentRating     = detail.contentRating
        data.year              = detail.year
        data.runtime           = detail.runtime
        data.originalLanguage  = detail.originalLanguage
        data.studio            = firstNonEmpty(detail.studios)
        data.network           = firstNonEmpty(detail.networks)
        data.showStatus        = detail.showStatus
        return data
    }

    private static func applySummary(_ summary: OverlaySummary?, into data: inout OverlayData) {
        guard let summary else { return }
        data.resolution     = summary.resolution
        data.hdr            = summary.hdr
        data.audio          = summary.audio
        data.audioChannels  = summary.audioChannels
        data.videoCodec     = summary.videoCodec
        data.container      = summary.container
        data.aspectRatio    = summary.aspectRatio
        data.releaseType    = summary.releaseType
        data.edition        = summary.edition
        data.multiAudio     = summary.multiAudio
        data.multiSub       = summary.multiSub
    }

    private static func firstNonEmpty(_ values: [String]?) -> String? {
        values?.first { !$0.isEmpty }
    }
}
