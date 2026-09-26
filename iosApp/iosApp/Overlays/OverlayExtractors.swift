import Foundation

/// An API item shape that carries the fields the overlay badges read.
/// `BrowseItem`, `SectionItem` and `ItemDetail` declare them with the same
/// names and types, so one mapper serves all three.
protocol OverlayDataSource {
    var overlaySummary: OverlaySummary? { get }
    var ratingImdb: Double? { get }
    var ratingTmdb: Double? { get }
    var ratingRtCritic: Int? { get }
    var ratingRtAudience: Int? { get }
    var contentRating: String? { get }
    var year: Int? { get }
    var runtime: Int? { get }
    var originalLanguage: String? { get }
    var studios: [String]? { get }
    var networks: [String]? { get }
    var showStatus: String? { get }
}

extension BrowseItem: OverlayDataSource {}
extension SectionItem: OverlayDataSource {}
extension ItemDetail: OverlayDataSource {}

/// Maps API item shapes onto the flat `OverlayData` bag the renderer
/// reads. `from(_:)` pulls only the fields the registry uses; everything
/// else stays in the original item and is ignored.
///
/// Server-side overlays (resolution/HDR/audio/…) are sourced from
/// `OverlaySummary`. Ratings, metadata, and ribbons come from item
/// top-level fields. Anything missing falls through to `nil` and the
/// registry's `getValue` returns `nil`, hiding the badge.
extension OverlayData {

    static func from(_ item: some OverlayDataSource) -> OverlayData {
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
