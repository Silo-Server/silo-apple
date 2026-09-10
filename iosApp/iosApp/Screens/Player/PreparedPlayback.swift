import Foundation

struct PreparedPlayback {
    let watchDetail: WatchDetail
    let selectedVersion: FileVersion
    let session: PlaybackSessionResponse
    let activeQualityId: String
    let protocolV3: PreparedPlaybackV3?

    init(
        watchDetail: WatchDetail,
        selectedVersion: FileVersion,
        session: PlaybackSessionResponse,
        activeQualityId: String = ApplePlaybackQuality.autoId,
        protocolV3: PreparedPlaybackV3? = nil
    ) {
        self.watchDetail = watchDetail
        self.selectedVersion = selectedVersion
        self.session = session
        self.activeQualityId = activeQualityId
        self.protocolV3 = protocolV3
    }

    var displayTitle: String {
        if watchDetail.type == "episode" {
            let season = watchDetail.seasonNumber.map { "S\($0)" } ?? nil
            let episode = watchDetail.episodeNumber.map { "E\($0)" } ?? nil
            let episodeTag = [season, episode].compactMap { $0 }.joined()

            if let seriesTitle = watchDetail.seriesTitle, !seriesTitle.isEmpty, !episodeTag.isEmpty {
                return "\(seriesTitle) • \(episodeTag) • \(watchDetail.title)"
            }
        }

        return watchDetail.title
    }

    /// Build the hero-strip metadata bundle for the tvOS overlay. Reads
    /// everything off the already-fetched `WatchDetail` + `FileVersion` so
    /// the overlay doesn't need a second API call — we only transform the
    /// shapes the server already gave us into display strings.
    func playerMetadata(primaryAudioLayout: String? = nil) -> PlayerMetadata {
        let isEpisode = watchDetail.type == "episode"
        let episodeTag: String? = {
            guard isEpisode else { return nil }
            let s = watchDetail.seasonNumber.map { "S\($0)" }
            let e = watchDetail.episodeNumber.map { "E\($0)" }
            let joined = [s, e].compactMap { $0 }.joined(separator: " · ")
            return joined.isEmpty ? nil : joined
        }()

        var badges: [String] = []
        if let resolution = selectedVersion.resolution, !resolution.isEmpty {
            badges.append(PlayerMetadata.badgeLabel(forResolution: resolution))
        }
        if selectedVersion.hdr == true {
            badges.append("HDR")
        }
        if let codec = selectedVersion.codecVideo?.uppercased(), !codec.isEmpty {
            badges.append(codec)
        }
        if let layout = primaryAudioLayout?.uppercased(), !layout.isEmpty {
            badges.append(layout)
        } else if let audioCodec = selectedVersion.codecAudio?.uppercased(), !audioCodec.isEmpty {
            badges.append(audioCodec)
        }

        return PlayerMetadata(
            seriesTitle: isEpisode ? watchDetail.seriesTitle : nil,
            episodeTag: episodeTag,
            primaryTitle: watchDetail.title,
            year: isEpisode ? nil : watchDetail.year,
            overview: watchDetail.overview,
            badges: badges
        )
    }
}

/// Secondary metadata shown in the tvOS player overlay's hero strip.
/// Populated from the playback session at load time via
/// `PreparedPlayback.playerMetadata(primaryAudioLayout:)` — everything here
/// is already fetched as part of `/api/v1/watch/{id}`, so no extra API
/// calls are needed.
struct PlayerMetadata: Equatable {
    /// For episodes: series title, e.g. "Foundation".
    var seriesTitle: String?
    /// For episodes: "S2 · E3" or similar compact tag.
    var episodeTag: String?
    /// Episode display title when the container is a series episode.
    /// For movies, this is the only title and is shown as the hero title.
    var primaryTitle: String
    /// Release year for movies; nil for episodes.
    var year: Int?
    /// Short plot description. Surfaced as secondary text below the title.
    var overview: String?
    /// Tagged media attributes rendered as pills in the hero strip:
    /// "4K" / "HDR" / "DV" / "HEVC" / "5.1" etc.
    var badges: [String]

    static let empty = PlayerMetadata(
        seriesTitle: nil,
        episodeTag: nil,
        primaryTitle: "",
        year: nil,
        overview: nil,
        badges: []
    )

    /// Map raw resolution strings ("1920x1080", "1080p", "2160p") to the
    /// short marketing label shown in the overlay ("4K" / "FHD" / "HD" / "SD").
    static func badgeLabel(forResolution raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("2160") || lower.contains("4k") { return "4K" }
        if lower.contains("1440") { return "QHD" }
        if lower.contains("1080") { return "FHD" }
        if lower.contains("720") { return "HD" }
        if lower.contains("480") { return "SD" }
        return raw.uppercased()
    }
}

enum PlaybackDeliveryStrategy {
    case direct
    case remux
    case transcode

    init(playMethod: String) {
        switch playMethod.lowercased() {
        case "remux":
            self = .remux
        case "transcode":
            self = .transcode
        default:
            self = .direct
        }
    }

    var name: String {
        switch self {
        case .direct:
            return "direct"
        case .remux:
            return "remux"
        case .transcode:
            return "transcode"
        }
    }

    var preservesSourceVideoMetadata: Bool {
        switch self {
        case .direct, .remux:
            return true
        case .transcode:
            return false
        }
    }
}
