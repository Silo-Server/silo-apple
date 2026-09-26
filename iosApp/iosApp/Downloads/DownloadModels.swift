import Foundation

// MARK: - Capability (GET /api/v2/capabilities/downloads)

/// Server-advertised download feature gate, cached in the scope's store.
/// Fetched at login + profile switch; the UI is hidden unless `isUsable`.
struct DownloadCapability: Codable, Hashable, Sendable {
    /// The capability's support state (`available`, `disabled`,
    /// `not_configured` or `unsupported`).
    let state: String
    /// Whether this principal may use downloads right now (false for a
    /// demo-restricted account even when `downloadAllowed` is true).
    let allowed: Bool
    let enabled: Bool
    let downloadAllowed: Bool
    let qualityPresets: [String]
    let transcodeEnabled: Bool
    let transcodeUserAllowed: Bool
    let seasonDownload: Bool
    let seriesMonitoring: Bool
    let monitoringModes: [String]

    /// Downloads are usable only when the capability is available and this
    /// principal may use it.
    var isUsable: Bool { state == "available" && allowed && enabled && downloadAllowed }

    private enum CodingKeys: String, CodingKey {
        case state
        case allowed
        case enabled
        case downloadAllowed
        case qualityPresets
        case transcodeEnabled
        case transcodeUserAllowed
        case seasonDownload
        case seriesMonitoring
        case monitoringModes
    }

    init(_ wire: APIv2DownloadCapability) {
        state = wire.state
        allowed = wire.allowed
        enabled = wire.enabled
        downloadAllowed = wire.downloadAllowed
        qualityPresets = wire.qualityPresets
        transcodeEnabled = wire.transcodeEnabled
        transcodeUserAllowed = wire.transcodeUserAllowed
        seasonDownload = wire.seasonDownload
        seriesMonitoring = wire.seriesMonitoring
        monitoringModes = wire.monitoringModes
    }

    /// Reads the cached copy. A copy cached before `state` and `allowed`
    /// were stored reads as unusable until the next refresh replaces it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        allowed = try container.decodeIfPresent(Bool.self, forKey: .allowed) ?? false
        enabled = try container.decode(Bool.self, forKey: .enabled)
        downloadAllowed = try container.decode(Bool.self, forKey: .downloadAllowed)
        qualityPresets = try container.decode([String].self, forKey: .qualityPresets)
        transcodeEnabled = try container.decode(Bool.self, forKey: .transcodeEnabled)
        transcodeUserAllowed = try container.decode(Bool.self, forKey: .transcodeUserAllowed)
        seasonDownload = try container.decode(Bool.self, forKey: .seasonDownload)
        seriesMonitoring = try container.decode(Bool.self, forKey: .seriesMonitoring)
        monitoringModes = try container.decode([String].self, forKey: .monitoringModes)
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

// MARK: - Download creation (POST /api/v2/downloads)

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

// MARK: - Offline manifest (GET /api/v2/downloads/{id}/manifest)

/// The offline playback bundle for one download. Stable and
/// presigned-URL-free — persisted on disk and read offline indefinitely.
/// Reuses `TimeRange` and `VersionChapter` from the online model layer so
/// the player's chapters / skip-intro logic works unchanged.
///
/// One type serves the wire and the stored `manifest.json`: the API decoder
/// converts the wire's snake_case keys to these coding keys, and the bare
/// store coder writes and reads them unchanged. Renaming a key strands every
/// stored manifest.
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
    /// Opaque; the v2 contract sends a string.
    let mediaFileId: String
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
        mediaFileId = try keyed.decode(String.self, forKey: .mediaFileId)
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

/// `DownloadSubscription`: a series monitor as the v2 server returns it.
/// Every field but `targetSeason` is required by the contract.
struct ServerSubscription: Decodable, Hashable, Sendable {
    let id: String
    let seriesId: String
    let mode: String
    let targetSeason: Int?
    let seasonNumbers: [Int]
    let deleteWatched: Bool
    let maxStorageBytes: Int64
    let active: Bool
    let createdAt: Date
    let updatedAt: Date
    /// The monitor's current validator. PATCH and DELETE send it as
    /// `If-Match`, and a sync names it in its body.
    let etag: String

    /// Whether the monitor can be stored and written: an id, a series and a
    /// validator.
    var isUsable: Bool { !id.isEmpty && !seriesId.isEmpty && !etag.isEmpty }
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

/// `DownloadSubscriptionCreateBody`.
struct CreateSubscriptionRequest: Encodable, Hashable, Sendable {
    let seriesId: String
    let mode: String
    let seasonNumbers: [Int]?
    let deleteWatched: Bool
    let maxStorageBytes: Int64
}

/// `DownloadSubscriptionPatchBody`. A nil field is omitted, never sent as
/// null: the server rejects null monitor fields.
struct UpdateSubscriptionRequest: Encodable, Hashable, Sendable {
    let mode: String?
    let seasonNumbers: [Int]?
    let deleteWatched: Bool?
    let maxStorageBytes: Int64?
    let active: Bool?
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
    var mediaFileId: String
    var format: String
    var effectiveQuality: String? = nil
    var deliveryFormat: String? = nil
    var targetBitrateKbps: Int? = nil
    /// Registry revision of the entry's bytes; status events name it.
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
    /// `URLSessionDownloadTask.taskIdentifier` of the record's live transfer,
    /// used only to cancel or pause that task in this process. Events find
    /// their record by the task's `DownloadTaskTag`, not by this id, and
    /// reconnect re-validates it against the tags of the live tasks.
    var taskIdentifier: Int?
    /// The latest local status event the server has not answered yet. A
    /// retry resends exactly this event.
    var pendingStatusEvent: DownloadStatusEvent? = nil

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

/// The owner of one background transfer: the scope (server and profile)
/// whose store holds its record, and the download id. Every profile and
/// server shares one background session, so each task carries this in its
/// `taskDescription`, and its events reach that scope whichever one is
/// loaded when they arrive.
struct DownloadTaskTag: Hashable, Sendable {
    let serverId: String
    let profileId: String
    let downloadId: String

    init(serverId: String, profileId: String, downloadId: String) {
        self.serverId = serverId
        self.profileId = profileId
        self.downloadId = downloadId
    }

    /// Download ids are server-defined text, so the fields are JSON-encoded
    /// instead of joined with a delimiter.
    private struct Payload: Codable {
        let v: Int
        let server: String
        let profile: String
        let download: String
    }

    private static let payloadVersion = 1

    /// JSON `{"v":1,"server":…,"profile":…,"download":…}`.
    var taskDescription: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let payload = Payload(v: Self.payloadVersion, server: serverId, profile: profileId, download: downloadId)
        guard let data = try? encoder.encode(payload) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Nil for nil, non-JSON, other versions, or empty fields.
    init?(taskDescription: String?) {
        guard let data = taskDescription?.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.v == Self.payloadVersion,
              !payload.server.isEmpty, !payload.profile.isEmpty, !payload.download.isEmpty else { return nil }
        self.init(serverId: payload.server, profileId: payload.profile, downloadId: payload.download)
    }

    /// Attribution for a task an earlier build started without a tag: the
    /// download id from its v2 file URL, the profile from its `X-Profile-Id`
    /// header, and the first server whose file URL for that id has the same
    /// origin and path. Nil when any of them is missing.
    static func attributing(
        requestURL: URL?,
        profileId: String?,
        servers: [(id: String, url: String)]
    ) -> DownloadTaskTag? {
        guard let downloadId = APIv2Client.downloadFileID(requestURL),
              let profileId, !profileId.isEmpty,
              let key = DownloadSessionDelegate.legacyTransferKey(requestURL),
              let server = servers.first(where: {
                  DownloadSessionDelegate.legacyTransferKey(
                      APIv2Client.downloadFileURL(id: downloadId, serverURL: $0.url)
                  ) == key
              }) else { return nil }
        return DownloadTaskTag(serverId: server.id, profileId: profileId, downloadId: downloadId)
    }

    func isOwned(byServerId serverId: String, profileId: String) -> Bool {
        self.serverId == serverId && self.profileId == profileId
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
    /// The monitor's validator when it was last read. Nil for a monitor
    /// stored before validators were kept; writes read it first.
    var etag: String?

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
        self.etag = server.etag
    }
}

/// A watch-progress event queued while offline, uploaded through
/// `POST /api/v2/sync/progress` on reconnect. `updatedAt` becomes the
/// last-write-wins event time.
struct QueuedProgress: Codable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        /// Not sent yet; the next flush uploads it.
        case pending
        /// Handed to the transport. Once its flush has ended without an
        /// answer (or the app stopped mid-flight), the outcome is unknown and
        /// the entry is held: never sent again, only superseded by a newer
        /// event for the same item or discarded.
        case dispatched
    }

    let id: UUID
    let mediaItemId: String
    let position: Double
    let duration: Double
    let updatedAt: Date
    var state: State

    init(id: UUID, mediaItemId: String, position: Double, duration: Double, updatedAt: Date, state: State = .pending) {
        self.id = id
        self.mediaItemId = mediaItemId
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case id, mediaItemId, position, duration, updatedAt, state
    }

    /// Entries written before `state` existed were never claimed for a v2
    /// upload, so they decode as pending.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        mediaItemId = try values.decode(String.self, forKey: .mediaItemId)
        position = try values.decode(Double.self, forKey: .position)
        duration = try values.decode(Double.self, forKey: .duration)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        state = try values.decodeIfPresent(State.self, forKey: .state) ?? .pending
    }

    /// The wire item, or nil when the entry cannot be sent.
    var syncItem: SyncProgressItem? {
        SyncProgressItem(
            mediaItemId: mediaItemId,
            position: position,
            duration: duration,
            forceOverwrite: false,
            updatedAt: updatedAt
        )
    }
}

/// Last-known resume point for a downloaded item, updated by offline
/// playback and by each complete `GET /api/v2/progress` read. Drives offline
/// resume, `isWatched` and `delete_watched`.
struct LocalProgressEntry: Codable, Equatable, Sendable {
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
    var localProgress: [String: LocalProgressEntry]
    /// Registry entries this device deleted locally whose server DELETE has
    /// not been confirmed. Reconcile never imports them and retries the
    /// DELETE.
    var pendingServerDeletes: Set<String>? = nil
    /// Set when this store replaced one an earlier version wrote (see
    /// `LegacyDownloadStorage`). The scope's first complete registry read
    /// deletes every row the store doesn't know instead of importing it.
    var legacyRowsPending: Bool? = nil
    /// Monitors the user stopped whose server DELETE has not been confirmed,
    /// with the validator each was last read with. The monitor list never
    /// imports them, and a later sync sends the DELETE again.
    var pendingSubscriptionDeletes: [String: String]? = nil
    /// Set when this store replaced one an earlier version wrote (see
    /// `LegacyDownloadStorage`). The scope's first complete monitor list
    /// records every monitor the store doesn't know in `legacyMonitorIds`.
    var legacyMonitorsPending: Bool? = nil
    /// Monitors an earlier version created. They stay on the server but are
    /// never shown or synced here.
    var legacyMonitorIds: Set<String>? = nil
    /// Identifier of the background session the records' `taskIdentifier`
    /// values belong to. Nil in stores written before the continuum → silo
    /// rename moved transfers to a new session.
    var taskSessionIdentifier: String? = nil

    static let currentVersion = 1

    static let empty = DownloadStoreFile(
        version: currentVersion,
        records: [:],
        subscriptions: [],
        capability: nil,
        capabilityFetchedAt: nil,
        progressQueue: [],
        localProgress: [:]
    )
}
