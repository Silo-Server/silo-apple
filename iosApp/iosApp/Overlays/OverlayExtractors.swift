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

/// Sample-content selector used by the live preview card in the
/// settings UI. Lives next to the sample data it picks so iOS and
/// tvOS settings views can share the same Picker model.
enum OverlaySampleVariant: String, CaseIterable, Identifiable, Hashable {
    case movie, show
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var data: OverlayData {
        switch self {
        case .movie: return .movieSample
        case .show:  return .showSample
        }
    }
}

/// Sample data used by the live preview card in the settings UI.
/// Picked to populate every overlay so users see what their choices do
/// even before they have a real media file open.
extension OverlayData {
    static let movieSample = OverlayData(
        resolution: "2160p",
        hdr: "DV HDR10",
        audio: "Atmos",
        audioChannels: "7.1",
        videoCodec: "H.265",
        container: "MKV",
        aspectRatio: "2.39:1",
        releaseType: "BluRay",
        edition: "Director's Cut",
        multiAudio: true,
        multiSub: true,
        ratingImdb: 8.6,
        ratingTmdb: 8.5,
        ratingRtCritic: 96,
        ratingRtAudience: 89,
        contentRating: "R",
        year: 2014,
        runtime: 169,
        originalLanguage: "en",
        studio: "Paramount Pictures",
        network: nil,
        showStatus: nil,
        imdbTop250: 23,
        rtCertifiedFresh: true
    )

    static let showSample = OverlayData(
        resolution: "1080p",
        hdr: nil,
        audio: "EAC3",
        audioChannels: "5.1",
        videoCodec: "H.264",
        container: "MKV",
        aspectRatio: "16:9",
        releaseType: "WEB-DL",
        edition: nil,
        multiAudio: false,
        multiSub: true,
        ratingImdb: 9.4,
        ratingTmdb: 9.1,
        ratingRtCritic: 95,
        ratingRtAudience: 93,
        contentRating: "TV-MA",
        year: 2008,
        runtime: 49,
        originalLanguage: "en",
        studio: nil,
        network: "AMC",
        showStatus: "Ended",
        imdbTop250: nil,
        rtCertifiedFresh: true
    )
}
