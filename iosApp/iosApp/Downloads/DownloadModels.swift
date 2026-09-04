import Foundation

// MARK: - Capability (GET /api/v1/downloads/capability)

/// Server-advertised download feature gate. Fetched at login + profile
/// switch; the UI is hidden when `enabled`/`downloadAllowed` is false.
/// Mirrors §3 of the server downloads API guide.
struct DownloadCapability: Codable, Hashable, Sendable {
    let enabled: Bool
    let downloadAllowed: Bool
    let qualityPresets: [String]
    let transcodeEnabled: Bool
    let transcodeUserAllowed: Bool
    let seasonDownload: Bool
    let seriesMonitoring: Bool
    let monitoringModes: [String]

    /// Downloads are usable at all only when the feature is on AND this
    /// user is allowed to download.
    var isUsable: Bool { enabled && downloadAllowed }

    /// Compatibility alias for stores written before the server renamed
    /// public download choices from formats to quality presets.
    var formats: [String] { qualityPresets }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case downloadAllowed
        case qualityPresets
        case formats
        case transcodeEnabled
        case transcodeUserAllowed
        case seasonDownload
        case seriesMonitoring
        case monitoringModes
    }

    init(
        enabled: Bool,
        downloadAllowed: Bool,
        qualityPresets: [String],
        transcodeEnabled: Bool,
        transcodeUserAllowed: Bool,
        seasonDownload: Bool,
        seriesMonitoring: Bool,
        monitoringModes: [String]
    ) {
        self.enabled = enabled
        self.downloadAllowed = downloadAllowed
        self.qualityPresets = qualityPresets
        self.transcodeEnabled = transcodeEnabled
        self.transcodeUserAllowed = transcodeUserAllowed
        self.seasonDownload = seasonDownload
        self.seriesMonitoring = seriesMonitoring
        self.monitoringModes = monitoringModes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        downloadAllowed = try container.decode(Bool.self, forKey: .downloadAllowed)
        qualityPresets = try container.decodeIfPresent([String].self, forKey: .qualityPresets)
            ?? container.decodeIfPresent([String].self, forKey: .formats)
            ?? [DownloadFormat.original.rawValue]
        transcodeEnabled = try container.decodeIfPresent(Bool.self, forKey: .transcodeEnabled) ?? false
        transcodeUserAllowed = try container.decodeIfPresent(Bool.self, forKey: .transcodeUserAllowed) ?? false
        seasonDownload = try container.decodeIfPresent(Bool.self, forKey: .seasonDownload) ?? false
        seriesMonitoring = try container.decodeIfPresent(Bool.self, forKey: .seriesMonitoring) ?? false
        monitoringModes = try container.decodeIfPresent([String].self, forKey: .monitoringModes) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(downloadAllowed, forKey: .downloadAllowed)
        try container.encode(qualityPresets, forKey: .qualityPresets)
        try container.encode(transcodeEnabled, forKey: .transcodeEnabled)
        try container.encode(transcodeUserAllowed, forKey: .transcodeUserAllowed)
        try container.encode(seasonDownload, forKey: .seasonDownload)
        try container.encode(seriesMonitoring, forKey: .seriesMonitoring)
        try container.encode(monitoringModes, forKey: .monitoringModes)
    }
}

/// Public quality presets offered for a managed download. Only values that
/// appear in `DownloadCapability.qualityPresets` may be requested.
enum DownloadFormat: String, Codable, CaseIterable, Sendable {
    case original
    case twentyMbps = "20mbps"
    case tenMbps = "10mbps"
    case fiveMbps = "5mbps"
    case twoMbps = "2mbps"
    case oneMbps = "1mbps"

    var displayName: String {
        switch self {
        case .original: return "Original"
        case .twentyMbps: return "20 Mbps"
        case .tenMbps: return "10 Mbps"
        case .fiveMbps: return "5 Mbps"
        case .twoMbps: return "2 Mbps"
        case .oneMbps: return "1 Mbps"
        }
    }
}

// MARK: - Download row (POST/GET /api/v1/downloads)

/// A managed device download row as returned by create/list. Field
/// reference: §5 of the server downloads API guide.
struct ServerDownloadRow: Decodable, Hashable, Sendable {
    let id: String
    let contentId: String
    let episodeId: String?
    let batchId: String?
    let deviceId: String?
    let mediaFileId: Int
    let fileSize: Int64?
    let bytesSent: Int64?
    let kind: String?
    let status: String
    let quality: String
    let effectiveQuality: String?
    let deliveryFormat: String?
    let targetBitrateKbps: Int?
    let revision: Int?
    let createdAt: Date?
    let completedAt: Date?

    /// Compatibility alias for local code that still names the stored
    /// requested quality `format`.
    var format: String { quality }

    private enum CodingKeys: String, CodingKey {
        case id
        case contentId
        case episodeId
        case batchId
        case deviceId
        case mediaFileId
        case fileSize
        case bytesSent
        case kind
        case status
        case quality
        case format
        case effectiveQuality
        case deliveryFormat
        case targetBitrateKbps
        case revision
        case createdAt
        case completedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        contentId = try container.decode(String.self, forKey: .contentId)
        episodeId = try container.decodeIfPresent(String.self, forKey: .episodeId)
        batchId = try container.decodeIfPresent(String.self, forKey: .batchId)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        mediaFileId = try container.decodeIfPresent(Int.self, forKey: .mediaFileId) ?? 0
        fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize)
        bytesSent = try container.decodeIfPresent(Int64.self, forKey: .bytesSent)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        status = try container.decode(String.self, forKey: .status)
        quality = try container.decodeIfPresent(String.self, forKey: .quality)
            ?? container.decodeIfPresent(String.self, forKey: .format)
            ?? DownloadFormat.original.rawValue
        effectiveQuality = try container.decodeIfPresent(String.self, forKey: .effectiveQuality)
        deliveryFormat = try container.decodeIfPresent(String.self, forKey: .deliveryFormat)
        targetBitrateKbps = try container.decodeIfPresent(Int.self, forKey: .targetBitrateKbps)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}

/// Single-item create returns a bare row; series/season create returns a
/// `{ "downloads": [...] }` batch. We attempt the batch shape first and
/// fall back to the single row.
struct ServerDownloadsResponse: Decodable, Sendable {
    let downloads: [ServerDownloadRow]
}

/// Body for `POST /api/v1/downloads`.
struct CreateDownloadRequest: Encodable, Sendable {
    let contentId: String
    let episodeId: String?
    let fileId: Int?
    let quality: String
    let series: Bool?
    let seasonNumber: Int?
    let caps: DownloadCaps?
}

/// Device decode capability used to decide whether `original` can be served
/// directly or should fall back to a compatibility artifact.
struct DownloadCaps: Encodable, Sendable {
    let clientFeatures: [String]
    let videoEvidence: String
    let codecsVideo: [String]
    let codecsAudio: [String]
    let audioPassthroughCodecs: [String]?
    let containers: [String]
    let maxResolution: String?
    let hdr: Bool
    let videoDecode: [PlaybackV3VideoDecodeCapability]

    /// Decode caps for the current Apple platform. The legacy flat video list
    /// contains hardware codecs only, so a server that ignores the additive
    /// detailed fields fails safely. New servers use `videoDecode` plus the
    /// feature opt-in to qualify bounded Aether software originals.
    ///
    /// Downloads are persistent artifacts, so HDR here is the device's
    /// maximum decode capability rather than the active display route:
    /// output-dependent HDR eligibility belongs to playback negotiation.
    /// Passthrough is this surface's own claim, since a download is decided
    /// long before there is an output route to ask.
    static func current() -> DownloadCaps {
        let isSimulator = AppleDecodeCapabilities.isSimulator
        return DownloadCaps(
            clientFeatures: [PlaybackProtocolV3.softwareVideoDecodeFeature],
            videoEvidence: PlaybackProtocolV3.Evidence.platformAttested,
            codecsVideo: AppleDecodeCapabilities.hardwareVideoCodecs,
            codecsAudio: AppleDecodeCapabilities.audioCodecs,
            audioPassthroughCodecs: isSimulator ? [] : ["ac3", "eac3"],
            containers: AppleDecodeCapabilities.containers,
            // Old servers understand only this coarse field. Keep it at the
            // software ceiling; a new server uses the detailed hardware entry
            // to preserve safe 4K originals on physical devices.
            maxResolution: "1080p",
            hdr: !isSimulator,
            videoDecode: AppleDecodeCapabilities.playbackV3VideoDecodeAttestation()
        )
    }
}

// MARK: - Offline manifest (GET /api/v1/downloads/{id}/manifest)

/// The offline playback bundle for one download. Stable and
/// presigned-URL-free — persisted on disk and read offline indefinitely.
/// Reuses `TimeRange` and `VersionChapter` from the online model layer so
/// the player's chapters / skip-intro logic works unchanged. Mirrors
/// §6 of the server downloads API guide.
struct OfflineManifest: Codable, Hashable, Sendable {
    let downloadId: String
    let contentId: String
    let episodeId: String?
    let type: String          // "movie" | "episode"
    let revision: Int?
    let quality: String
    let effectiveQuality: String?
    let deliveryFormat: String?
    let targetBitrateKbps: Int?
    let mediaFileId: Int
    let fileSize: Int64?

    let title: String
    let year: Int?
    let overview: String?
    let runtime: Int?
    let contentRating: String?
    let genres: [String]?
    let seriesId: String?
    let seriesTitle: String?
    let seasonNumber: Int?
    let episodeNumber: Int?

    let posterThumbhash: String?
    let backdropThumbhash: String?
    let artworkUrls: ArtworkUrls?

    let container: String?
    let codecVideo: String?
    let codecAudio: String?
    let resolution: String?
    let hdr: Bool?
    let durationSeconds: Double?
    let selectedAudioTrackIndex: Int?
    let audioTracks: [OfflineAudioTrack]?

    let chapters: [VersionChapter]?
    let intro: TimeRange?
    let credits: TimeRange?
    let recap: TimeRange?
    let preview: TimeRange?

    let subtitles: [OfflineSubtitle]?
    let stableIdentity: StableIdentity?
    let integrity: OfflineIntegrity?

    let manifestVersion: Int?
    let generatedAt: Date?

    /// Compatibility alias for code paths and saved manifests that used
    /// the former public `format` name.
    var format: String { quality }

    private enum CodingKeys: String, CodingKey {
        case downloadId
        case contentId
        case episodeId
        case type
        case revision
        case quality
        case format
        case effectiveQuality
        case deliveryFormat
        case targetBitrateKbps
        case mediaFileId
        case fileSize
        case title
        case year
        case overview
        case runtime
        case contentRating
        case genres
        case seriesId
        case seriesTitle
        case seasonNumber
        case episodeNumber
        case posterThumbhash
        case backdropThumbhash
        case artworkUrls
        case container
        case codecVideo
        case codecAudio
        case resolution
        case hdr
        case durationSeconds
        case selectedAudioTrackIndex
        case audioTracks
        case chapters
        case intro
        case credits
        case recap
        case preview
        case subtitles
        case stableIdentity
        case integrity
        case manifestVersion
        case generatedAt
    }

    init(from decoder: Decoder) throws {
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        downloadId = try keyed.decode(String.self, forKey: .downloadId)
        contentId = try keyed.decode(String.self, forKey: .contentId)
        episodeId = try keyed.decodeIfPresent(String.self, forKey: .episodeId)
        type = try keyed.decode(String.self, forKey: .type)
        revision = try keyed.decodeIfPresent(Int.self, forKey: .revision)
        quality = try keyed.decodeIfPresent(String.self, forKey: .quality)
            ?? keyed.decodeIfPresent(String.self, forKey: .format)
            ?? DownloadFormat.original.rawValue
        effectiveQuality = try keyed.decodeIfPresent(String.self, forKey: .effectiveQuality)
        deliveryFormat = try keyed.decodeIfPresent(String.self, forKey: .deliveryFormat)
        targetBitrateKbps = try keyed.decodeIfPresent(Int.self, forKey: .targetBitrateKbps)
        mediaFileId = try keyed.decodeIfPresent(Int.self, forKey: .mediaFileId) ?? 0
        fileSize = try keyed.decodeIfPresent(Int64.self, forKey: .fileSize)
        title = try keyed.decode(String.self, forKey: .title)
        year = try keyed.decodeIfPresent(Int.self, forKey: .year)
        overview = try keyed.decodeIfPresent(String.self, forKey: .overview)
        runtime = try keyed.decodeIfPresent(Int.self, forKey: .runtime)
        contentRating = try keyed.decodeIfPresent(String.self, forKey: .contentRating)
        genres = try keyed.decodeIfPresent([String].self, forKey: .genres)
        seriesId = try keyed.decodeIfPresent(String.self, forKey: .seriesId)
        seriesTitle = try keyed.decodeIfPresent(String.self, forKey: .seriesTitle)
        seasonNumber = try keyed.decodeIfPresent(Int.self, forKey: .seasonNumber)
        episodeNumber = try keyed.decodeIfPresent(Int.self, forKey: .episodeNumber)
        posterThumbhash = try keyed.decodeIfPresent(String.self, forKey: .posterThumbhash)
        backdropThumbhash = try keyed.decodeIfPresent(String.self, forKey: .backdropThumbhash)
        artworkUrls = try keyed.decodeIfPresent(ArtworkUrls.self, forKey: .artworkUrls)
        container = try keyed.decodeIfPresent(String.self, forKey: .container)
        codecVideo = try keyed.decodeIfPresent(String.self, forKey: .codecVideo)
        codecAudio = try keyed.decodeIfPresent(String.self, forKey: .codecAudio)
        resolution = try keyed.decodeIfPresent(String.self, forKey: .resolution)
        hdr = try keyed.decodeIfPresent(Bool.self, forKey: .hdr)
        durationSeconds = try keyed.decodeIfPresent(Double.self, forKey: .durationSeconds)
        selectedAudioTrackIndex = try keyed.decodeIfPresent(Int.self, forKey: .selectedAudioTrackIndex)
        audioTracks = try keyed.decodeIfPresent([OfflineAudioTrack].self, forKey: .audioTracks)
        chapters = try keyed.decodeIfPresent([VersionChapter].self, forKey: .chapters)
        intro = try keyed.decodeIfPresent(TimeRange.self, forKey: .intro)
        credits = try keyed.decodeIfPresent(TimeRange.self, forKey: .credits)
        recap = try keyed.decodeIfPresent(TimeRange.self, forKey: .recap)
        preview = try keyed.decodeIfPresent(TimeRange.self, forKey: .preview)
        subtitles = try keyed.decodeIfPresent([OfflineSubtitle].self, forKey: .subtitles)
        stableIdentity = try keyed.decodeIfPresent(StableIdentity.self, forKey: .stableIdentity)
        integrity = try keyed.decodeIfPresent(OfflineIntegrity.self, forKey: .integrity)
        manifestVersion = try keyed.decodeIfPresent(Int.self, forKey: .manifestVersion)
        generatedAt = try keyed.decodeIfPresent(Date.self, forKey: .generatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var keyed = encoder.container(keyedBy: CodingKeys.self)
        try keyed.encode(downloadId, forKey: .downloadId)
        try keyed.encode(contentId, forKey: .contentId)
        try keyed.encodeIfPresent(episodeId, forKey: .episodeId)
        try keyed.encode(type, forKey: .type)
        try keyed.encodeIfPresent(revision, forKey: .revision)
        try keyed.encode(quality, forKey: .quality)
        try keyed.encodeIfPresent(effectiveQuality, forKey: .effectiveQuality)
        try keyed.encodeIfPresent(deliveryFormat, forKey: .deliveryFormat)
        try keyed.encodeIfPresent(targetBitrateKbps, forKey: .targetBitrateKbps)
        try keyed.encode(mediaFileId, forKey: .mediaFileId)
        try keyed.encodeIfPresent(fileSize, forKey: .fileSize)
        try keyed.encode(title, forKey: .title)
        try keyed.encodeIfPresent(year, forKey: .year)
        try keyed.encodeIfPresent(overview, forKey: .overview)
        try keyed.encodeIfPresent(runtime, forKey: .runtime)
        try keyed.encodeIfPresent(contentRating, forKey: .contentRating)
        try keyed.encodeIfPresent(genres, forKey: .genres)
        try keyed.encodeIfPresent(seriesId, forKey: .seriesId)
        try keyed.encodeIfPresent(seriesTitle, forKey: .seriesTitle)
        try keyed.encodeIfPresent(seasonNumber, forKey: .seasonNumber)
        try keyed.encodeIfPresent(episodeNumber, forKey: .episodeNumber)
        try keyed.encodeIfPresent(posterThumbhash, forKey: .posterThumbhash)
        try keyed.encodeIfPresent(backdropThumbhash, forKey: .backdropThumbhash)
        try keyed.encodeIfPresent(artworkUrls, forKey: .artworkUrls)
        try keyed.encodeIfPresent(container, forKey: .container)
        try keyed.encodeIfPresent(codecVideo, forKey: .codecVideo)
        try keyed.encodeIfPresent(codecAudio, forKey: .codecAudio)
        try keyed.encodeIfPresent(resolution, forKey: .resolution)
        try keyed.encodeIfPresent(hdr, forKey: .hdr)
        try keyed.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try keyed.encodeIfPresent(selectedAudioTrackIndex, forKey: .selectedAudioTrackIndex)
        try keyed.encodeIfPresent(audioTracks, forKey: .audioTracks)
        try keyed.encodeIfPresent(chapters, forKey: .chapters)
        try keyed.encodeIfPresent(intro, forKey: .intro)
        try keyed.encodeIfPresent(credits, forKey: .credits)
        try keyed.encodeIfPresent(recap, forKey: .recap)
        try keyed.encodeIfPresent(preview, forKey: .preview)
        try keyed.encodeIfPresent(subtitles, forKey: .subtitles)
        try keyed.encodeIfPresent(stableIdentity, forKey: .stableIdentity)
        try keyed.encodeIfPresent(integrity, forKey: .integrity)
        try keyed.encodeIfPresent(manifestVersion, forKey: .manifestVersion)
        try keyed.encodeIfPresent(generatedAt, forKey: .generatedAt)
    }

    struct ArtworkUrls: Codable, Hashable, Sendable {
        let poster: String?
        let backdrop: String?
        let logo: String?
    }
}

/// An audio track described by an offline manifest.
///
/// `index` is the ordinal within this list, not the ffmpeg stream index — the
/// server writes the loop counter and drops the probed index, so it must never
/// be handed to code that means "stream index" by it.
///
/// `title` is already the server's collapse of the cleaned title and the raw
/// embedded title, so the two cannot be told apart again on this side.
struct OfflineAudioTrack: Codable, Hashable, Sendable {
    let index: Int?
    let title: String?
    let language: String?
    let codec: String?
    let layout: String?
    let channels: Int?
    let bitrate: Int?
    let sampleRate: Int?
    let isDefault: Bool?

    private enum CodingKeys: String, CodingKey {
        case index
        case title
        case language
        case codec
        case layout
        case channels
        case bitrate
        // Wire key is `sample_rate`; the API decoder's `.convertFromSnakeCase`
        // has already rewritten it by the time these keys are matched, and the
        // bare on-disk coder round-trips this camelCase form unchanged.
        case sampleRate
        case isDefault = "default"
    }
}

/// A subtitle attached to an offline download. `fetchUrl` is taken
/// verbatim from the manifest and resolved against this server's API
/// origin (`external:{index}` or `downloaded:{id}`).
struct OfflineSubtitle: Codable, Hashable, Sendable {
    let language: String?
    let format: String?
    let forced: Bool?
    let hearingImpaired: Bool?
    let external: Bool?
    let fetchUrl: String
    let fileSize: Int64?
}

/// Rescan-stable identity mirroring the watch-state identity. Used to
/// re-resolve a download whose `content_id` changed on the server.
struct StableIdentity: Codable, Hashable, Sendable {
    let stableType: String?
    let providerIds: [String: String]?
    let season: Int?
    let episode: Int?
}

struct OfflineIntegrity: Codable, Hashable, Sendable {
    let expectedBytes: Int64?
    let mediaFileHash: String?
    let metadataEtag: String?
}

// MARK: - Subscriptions (series monitoring)

/// A series-monitoring subscription as returned by the server.
struct ServerSubscription: Codable, Hashable, Sendable {
    let id: String
    let seriesId: String
    let mode: String
    let targetSeason: Int?
    let seasonNumbers: [Int]?
    let deleteWatched: Bool
    let maxStorageBytes: Int64
    let active: Bool
    let createdAt: Date?
    let updatedAt: Date?
}

/// Subscription modes the client may request. Filtered against
/// `DownloadCapability.monitoringModes`.
enum SubscriptionMode: String, Codable, CaseIterable, Sendable {
    case all
    case future
    case latestSeason = "latest_season"
    case specificSeasons = "specific_seasons"

    var displayName: String {
        switch self {
        case .all: return "All Seasons"
        case .future: return "New Episodes Only"
        case .latestSeason: return "Latest Season & Newer"
        case .specificSeasons: return "Specific Seasons"
        }
    }
}

struct CreateSubscriptionRequest: Encodable, Sendable {
    let seriesId: String
    let mode: String
    let seasonNumbers: [Int]?
    let deleteWatched: Bool
    let maxStorageBytes: Int64
}

struct UpdateSubscriptionRequest: Encodable, Sendable {
    let mode: String?
    let seasonNumbers: [Int]?
    let deleteWatched: Bool?
    let maxStorageBytes: Int64?
    let active: Bool?
}

struct CreateSubscriptionResponse: Codable, Sendable {
    let subscription: ServerSubscription
    let registered: Int
}

struct SubscriptionsListResponse: Codable, Sendable {
    let subscriptions: [ServerSubscription]
}

struct SubscriptionSyncResponse: Codable, Sendable {
    let registered: Int
}

// MARK: - Progress reconciliation

/// `GET /api/v1/progress?since={cursor}` delta response. §5.2.
struct ProgressPullResponse: Codable, Sendable {
    let progress: [ProgressPullItem]
    let nextCursor: String?
}

struct ProgressPullItem: Codable, Sendable {
    let mediaItemId: String
    let positionSeconds: Double
    let durationSeconds: Double
    let completed: Bool
    let updatedAt: Date?
}

// MARK: - Local persistence types

/// Client-side lifecycle of a managed download, layered on top of the
/// server's row status. The server owns `ready`/`preparing`/`revoked`/
/// `failed`; the client owns the local fetch progression below.
enum LocalDownloadStatus: String, Codable, Sendable {
    /// `POST /downloads` registered; awaiting the asset pipeline.
    case registering
    /// Server is producing a remux/transcode artifact (`preparing`).
    case preparing
    /// Server row is `ready`; queued behind the concurrency cap.
    case queued
    /// Background `URLSession` task is transferring the media file.
    case downloading
    /// User-suspended transfer. The task was cancelled with resume data
    /// (persisted next to the media, see `DownloadRecord.resumeDataFilename`)
    /// so the transfer can continue without refetching completed ranges.
    /// Only an explicit user resume leaves this state — the pipeline and
    /// server reconciliation must never auto-restart it.
    case paused
    /// Media file is local; fetching manifest/artwork/subtitles.
    case fetchingAssets
    /// Everything is on disk and playable offline.
    case completed
    /// Unrecoverable failure; see `lastError`.
    case failed
    /// Server revoked future serves (409). An already-downloaded file
    /// stays playable.
    case revoked

    var isTerminalSuccess: Bool { self == .completed }
    /// `paused` counts as active so it stays in the in-progress UI, but the
    /// pipeline only ever starts `.queued` records — pausing both surfaces
    /// the row and blocks any automatic restart.
    var isActive: Bool {
        switch self {
        case .registering, .preparing, .queued, .downloading, .paused, .fetchingAssets:
            return true
        case .completed, .failed, .revoked:
            return false
        }
    }
}

/// The single local source of truth for one managed download. On-disk
/// paths are stored as **relative filenames** (the app-container path can
/// change between launches) and rebuilt against the current container via
/// `DownloadFilePaths`.
struct DownloadRecord: Codable, Identifiable, Hashable, Sendable {
    let id: String                       // server download id
    var contentId: String                // mutable: may be re-resolved via stableIdentity
    let episodeId: String?
    let batchId: String?
    var mediaFileId: Int
    var format: String
    var effectiveQuality: String? = nil
    var deliveryFormat: String? = nil
    var targetBitrateKbps: Int? = nil
    var revision: Int? = nil
    var serverStatus: String
    var localStatus: LocalDownloadStatus
    var fileSize: Int64
    var bytesDownloaded: Int64

    var mediaFilename: String?
    var manifestFilename: String?
    var posterFilename: String?
    var backdropFilename: String?
    var logoFilename: String?
    /// Manifest `fetch_url` → relative on-disk filename.
    var subtitleFilenames: [String: String]
    /// Persisted `cancel(byProducingResumeData:)` blob for a paused
    /// transfer. Default `nil` keeps Codable backward-compatible with
    /// stores written before pause existed.
    var resumeDataFilename: String? = nil

    // Display fields cached so the Downloads list renders before the
    // manifest is fetched and offline.
    var title: String?
    var subtitle: String?                // e.g. "2024" or "S1 · E2"
    var type: String?                    // "movie" | "episode" | "series"
    var seriesId: String?
    /// Cached parent-series title for episode downloads (from the manifest),
    /// so the grouped Downloads UI can label a series card offline.
    var seriesTitle: String? = nil
    /// Structured season/episode numbers, populated from the offline
    /// manifest. Default `nil` keeps the synthesized memberwise init and
    /// Codable backward-compatible with stores written before they existed.
    var seasonNumber: Int? = nil
    var episodeNumber: Int? = nil
    var posterThumbhash: String?
    var container: String?               // media container, drives file ext + engine

    var stableIdentity: StableIdentity?
    var registeredAt: Date
    var downloadedAt: Date?
    var lastError: String?
    var retryCount: Int
    /// `URLSessionDownloadTask.taskIdentifier`, for reconnecting on relaunch.
    var taskIdentifier: Int?

    var isPlayableOffline: Bool {
        (localStatus == .completed || localStatus == .revoked) && mediaFilename != nil
    }

    /// The leaf media item id watch-progress is keyed by: the episode id for
    /// an episode download, otherwise the (movie) content id.
    var leafMediaItemId: String { episodeId ?? contentId }

    var progressFraction: Double {
        guard fileSize > 0 else { return 0 }
        return min(1, max(0, Double(bytesDownloaded) / Double(fileSize)))
    }
}

/// A locally-mirrored subscription with the series title cached for
/// offline display.
struct DownloadSubscription: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let seriesId: String
    var seriesTitle: String?
    var mode: String
    var targetSeason: Int?
    var seasonNumbers: [Int]?
    var deleteWatched: Bool
    var maxStorageBytes: Int64
    var active: Bool

    init(from server: ServerSubscription, seriesTitle: String?) {
        self.id = server.id
        self.seriesId = server.seriesId
        self.seriesTitle = seriesTitle
        self.mode = server.mode
        self.targetSeason = server.targetSeason
        self.seasonNumbers = server.seasonNumbers
        self.deleteWatched = server.deleteWatched
        self.maxStorageBytes = server.maxStorageBytes
        self.active = server.active
    }
}

/// A watch-progress event queued while offline, flushed via
/// `POST /api/v1/sync/progress` on reconnect. `updatedAt` becomes the
/// last-write-wins event time (§5.1).
struct QueuedProgress: Codable, Identifiable, Sendable {
    let id: UUID
    let mediaItemId: String
    let position: Double
    let duration: Double
    let updatedAt: Date
    var attempts: Int
}

/// Last-known resume point for a downloaded item, updated by offline
/// playback and by pulled server deltas. Drives offline resume.
struct LocalProgressEntry: Codable, Sendable {
    var position: Double
    var duration: Double
    var completed: Bool
    var updatedAt: Date
}

/// The entire on-disk store blob for one `(server, profile)` scope.
struct DownloadStoreFile: Codable, Sendable {
    var version: Int
    var records: [String: DownloadRecord]
    var subscriptions: [DownloadSubscription]
    var capability: DownloadCapability?
    var capabilityFetchedAt: Date?
    var progressQueue: [QueuedProgress]
    var progressCursor: String?
    var localProgress: [String: LocalProgressEntry]

    static let currentVersion = 1

    static let empty = DownloadStoreFile(
        version: currentVersion,
        records: [:],
        subscriptions: [],
        capability: nil,
        capabilityFetchedAt: nil,
        progressQueue: [],
        progressCursor: nil,
        localProgress: [:]
    )
}
