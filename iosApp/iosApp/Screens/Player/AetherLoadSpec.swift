import AetherEngine
import Foundation

/// Immutable inputs for one Aether load generation.
///
/// The initialisers are main-actor isolated because they sample the display
/// before building `LoadOptions`: Aether runs the display-criteria handshake
/// synchronously inside `load`, so `panelIsInHDRMode` and `matchContentEnabled`
/// have to be true of the panel at spec-construction time. Passing an explicit
/// `panelIsInHDRMode` overrides that measurement; `nil` means measure now.
struct AetherLoadSpec {
    enum ValidationError: Error, Equatable {
        case invalidStreamURL(String)
        case unsupportedDelivery(String)
        case invalidAudioTrackIndex(Int)
        case invalidSubtitleArtifactURL(String)
        case unsupportedSubtitleTimingOrigin(origin: Double, timelineOffset: Double)
    }

    let planID: String
    let sessionID: String
    let delivery: String
    let sourceURL: URL
    let timeline: PlaybackTimelineMapper
    let options: LoadOptions
    let audioSourceStreamIndex: Int32?
    /// App-facing ids for `options.externalSubtitles`, positionally parallel to
    /// that array — element `i` is the Silo id of `options.externalSubtitles[i]`,
    /// and `nil` means "this declared track has no stable Silo id".
    ///
    /// Aether assigns its own ids sequentially from `externalSubtitleTrackIDBase`
    /// in declaration order, so the controller can only translate an alias by
    /// position. That makes the parallel-arrays invariant load-bearing: an entry
    /// here that Aether was never asked to register binds a Silo id to the Aether
    /// id of some *other* sidecar (the first one registered later), which is how
    /// picking "English" ends up rendering the first sidecar in the plan. Both
    /// arrays are therefore built at a single append site.
    let externalSubtitleAppTrackIDs: [Int64?]

    /// The bridge this app assumes for codecs Aether cannot stream-copy, when
    /// a caller does not name one.
    ///
    /// Deliberately not Aether's own `.surroundCompat` default: the engine this
    /// player replaced always bridged TrueHD and DTS-HD MA losslessly, so
    /// inheriting the lossy default would quietly downgrade shipped behavior —
    /// which is exactly what happened before this parameter existed. The user
    /// setting overrides it; see `PlayerSettings.losslessAudioEnabled`.
    static let defaultAudioBridgeMode: AudioBridgeMode = .lossless

    /// The deinterlacer used when a caller does not name one.
    ///
    /// Aether's own default, unlike ``defaultAudioBridgeMode``: the hardware
    /// graph with its software fallback is what every load has always got, so
    /// restating it here changes nothing until the user picks otherwise. See
    /// `PlayerSettings.deinterlaceMode`.
    static let defaultDeinterlaceMode: DeinterlaceMode = .auto

    /// The hardware deinterlacer's cadence when a caller does not name one.
    /// Also Aether's own default; see `PlayerSettings.deinterlaceFieldRate`.
    static let defaultDeinterlaceFieldRate: DeinterlaceFieldRate = .field

    @MainActor
    init(
        offlineURL: URL,
        startPosition: Double,
        audioOnly: Bool,
        audioSourceStreamIndex: Int32? = nil,
        sidecars: [SubtitleUrl] = [],
        preferredAudioLanguages: [String] = [],
        preferredSubtitleLanguages: [String] = [],
        forwardBufferSegments: Int? = nil,
        audioBridgeMode: AudioBridgeMode = Self.defaultAudioBridgeMode,
        deinterlaceMode: DeinterlaceMode = Self.defaultDeinterlaceMode,
        deinterlaceFieldRate: DeinterlaceFieldRate = Self.defaultDeinterlaceFieldRate,
        panelIsInHDRMode: Bool? = nil
    ) throws {
        guard offlineURL.isFileURL else {
            throw ValidationError.invalidStreamURL(offlineURL.absoluteString)
        }
        let externalSubtitles = try sidecars.map { sidecar -> ExternalSubtitleTrack in
            guard let url = URL(string: sidecar.url), url.isFileURL else {
                throw ValidationError.invalidSubtitleArtifactURL(sidecar.url)
            }
            return ExternalSubtitleTrack(
                url: url,
                name: sidecar.label,
                language: sidecar.language,
                isForced: sidecar.forced ?? false,
                isHearingImpaired: sidecar.hearingImpaired ?? false,
                isDefault: sidecar.default ?? false,
                formatHint: sidecar.codec
            )
        }
        planID = "offline"
        sessionID = "offline"
        delivery = PlaybackProtocolV3.PlanDelivery.originalHTTP
        sourceURL = offlineURL
        timeline = PlaybackTimelineMapper(directStartSeconds: startPosition)
        self.audioSourceStreamIndex = audioSourceStreamIndex
        externalSubtitleAppTrackIDs = sidecars.map { sidecar -> Int64? in
            SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: sidecar.index)
        }
        options = LoadOptions(
            panelIsInHDRMode: panelIsInHDRMode ?? AetherDisplayContext.panelIsInHDRMode,
            audioBridgeMode: audioBridgeMode,
            audioOnly: audioOnly,
            preserveASSMarkup: false,
            prepareNativeSubtitles: true,
            eagerNativeSubtitleReaders: true,
            nativeSubtitlePreferredLanguages: preferredSubtitleLanguages,
            preferredAudioLanguages: preferredAudioLanguages,
            preferredSubtitleLanguages: preferredSubtitleLanguages,
            externalSubtitles: externalSubtitles,
            forwardBufferSegments: forwardBufferSegments,
            autoplay: false,
            deinterlaceMode: deinterlaceMode,
            deinterlaceFieldRate: deinterlaceFieldRate
        )
    }

    @MainActor
    init(
        directURL: URL,
        headers: [String: String],
        startPosition: Double,
        audioOnly: Bool,
        sidecars: [SubtitleUrl] = [],
        preferredAudioLanguages: [String] = [],
        preferredSubtitleLanguages: [String] = [],
        forwardBufferSegments: Int? = nil,
        audioBridgeMode: AudioBridgeMode = Self.defaultAudioBridgeMode,
        deinterlaceMode: DeinterlaceMode = Self.defaultDeinterlaceMode,
        deinterlaceFieldRate: DeinterlaceFieldRate = Self.defaultDeinterlaceFieldRate,
        panelIsInHDRMode: Bool? = nil
    ) throws {
        guard ["http", "https", "file"].contains(directURL.scheme?.lowercased() ?? "") else {
            throw ValidationError.invalidStreamURL(directURL.absoluteString)
        }
        let externalSubtitles = try sidecars.map { sidecar -> ExternalSubtitleTrack in
            guard let url = Self.resolveSidecarURL(sidecar.url, relativeTo: directURL),
                  ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else {
                throw ValidationError.invalidSubtitleArtifactURL(sidecar.url)
            }
            return ExternalSubtitleTrack(
                url: url,
                name: sidecar.label,
                language: sidecar.language,
                isForced: sidecar.forced ?? false,
                isHearingImpaired: sidecar.hearingImpaired ?? false,
                isDefault: sidecar.default ?? false,
                httpHeaders: Self.subtitleRequestHeaders(
                    headers,
                    resourceURL: url,
                    trustedOriginURLs: [directURL]
                ),
                formatHint: sidecar.codec
            )
        }
        planID = "legacy-direct"
        sessionID = "legacy-direct"
        delivery = PlaybackProtocolV3.PlanDelivery.originalHTTP
        sourceURL = directURL
        timeline = PlaybackTimelineMapper(directStartSeconds: startPosition)
        audioSourceStreamIndex = nil
        externalSubtitleAppTrackIDs = sidecars.map { sidecar -> Int64? in
            SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: sidecar.index)
        }
        options = LoadOptions(
            httpHeaders: headers,
            panelIsInHDRMode: panelIsInHDRMode ?? AetherDisplayContext.panelIsInHDRMode,
            audioBridgeMode: audioBridgeMode,
            audioOnly: audioOnly,
            preserveASSMarkup: false,
            prepareNativeSubtitles: true,
            eagerNativeSubtitleReaders: true,
            nativeSubtitlePreferredLanguages: preferredSubtitleLanguages,
            preferredAudioLanguages: preferredAudioLanguages,
            preferredSubtitleLanguages: preferredSubtitleLanguages,
            externalSubtitles: externalSubtitles,
            forwardBufferSegments: forwardBufferSegments,
            autoplay: false,
            deinterlaceMode: deinterlaceMode,
            deinterlaceFieldRate: deinterlaceFieldRate
        )
    }

    @MainActor
    init(
        validating plan: PlaybackV3Plan,
        sessionID: String,
        matchContentEnabled: Bool,
        sourceURLOverride: URL? = nil,
        requestHeaders: [String: String]? = nil,
        resolveURL: ((String) -> URL?)? = nil,
        apiOriginURL: URL? = nil,
        preferredAudioLanguages: [String] = [],
        preferredSubtitleLanguages: [String] = [],
        forwardBufferSegments: Int? = nil,
        audioBridgeMode: AudioBridgeMode = Self.defaultAudioBridgeMode,
        deinterlaceMode: DeinterlaceMode = Self.defaultDeinterlaceMode,
        deinterlaceFieldRate: DeinterlaceFieldRate = Self.defaultDeinterlaceFieldRate,
        panelIsInHDRMode: Bool? = nil
    ) throws {
        guard PlaybackProtocolV3.PlanDelivery.supported.contains(plan.delivery) else {
            throw ValidationError.unsupportedDelivery(plan.delivery)
        }
        let resolvedPlanSourceURL: URL?
        if let resolveURL {
            resolvedPlanSourceURL = resolveURL(plan.stream.url)
        } else {
            resolvedPlanSourceURL = URL(string: plan.stream.url)
        }
        guard let sourceURL = sourceURLOverride ?? resolvedPlanSourceURL,
              ["http", "https", "file"].contains(sourceURL.scheme?.lowercased() ?? "") else {
            throw ValidationError.invalidStreamURL(plan.stream.url)
        }
        let timeline = try PlaybackTimelineMapper(validating: plan.timeline)
        // `StreamRequest` adds the current Silo bearer to the plan-provided
        // headers. Its merged value is authoritative for both the media and
        // same-origin subtitle artifacts; falling back to the wire-plan value
        // keeps the pure mapper independently usable in tests.
        let effectiveHeaders = requestHeaders ?? plan.stream.headers

        // Protocol V3's selected audio index is an ordinal in the server's
        // audio-track list, not an FFmpeg AVStream index. Original HTTP is
        // offered only for the container default; remux/transcode outputs are
        // already packaged with the selected track. Let Aether choose the
        // default/output stream rather than passing a different index space.
        if let selectedIndex = plan.selectedTracks.audio?.index {
            guard selectedIndex >= 0 else {
                throw ValidationError.invalidAudioTrackIndex(selectedIndex)
            }
        }

        // Declared tracks and their Silo aliases are appended together so the
        // two arrays cannot drift: an alias without a declared track shifts
        // every later Aether external id by one.
        var externalSubtitles: [ExternalSubtitleTrack] = []
        var externalSubtitleAppTrackIDs: [Int64?] = []
        if let artifact = plan.subtitle.artifact,
           ["render", "convert"].contains(plan.subtitle.mode) {
            guard abs(artifact.timingOriginSeconds - plan.timeline.timelineOffsetSeconds) < 0.001 else {
                throw ValidationError.unsupportedSubtitleTimingOrigin(
                    origin: artifact.timingOriginSeconds,
                    timelineOffset: plan.timeline.timelineOffsetSeconds
                )
            }
            let resolvedArtifactURL: URL?
            if let resolveURL {
                resolvedArtifactURL = resolveURL(artifact.url)
            } else {
                resolvedArtifactURL = URL(string: artifact.url)
            }
            guard let artifactURL = resolvedArtifactURL,
                  ["http", "https", "file"].contains(artifactURL.scheme?.lowercased() ?? "") else {
                throw ValidationError.invalidSubtitleArtifactURL(artifact.url)
            }
            let inventoryItem = plan.subtitle.inventory.first { item in
                item.trackId == plan.subtitle.trackId
            }
            externalSubtitles.append(ExternalSubtitleTrack(
                url: artifactURL,
                name: inventoryItem?.label,
                language: inventoryItem?.language,
                isForced: inventoryItem?.forced ?? false,
                isHearingImpaired: inventoryItem?.hearingImpaired ?? false,
                isDefault: inventoryItem?.default ?? false,
                // Subtitle artifacts are always API-origin routes, including
                // when `authorized_media_origins_v1` puts the media itself on a
                // proxy. Trusting the API origin alongside the source is what
                // keeps the bearer attached to the sidecar in that case; the
                // artifact URL itself is still plan-validated as API-relative.
                httpHeaders: Self.subtitleRequestHeaders(
                    effectiveHeaders,
                    resourceURL: artifactURL,
                    trustedOriginURLs: [sourceURL, apiOriginURL].compactMap { $0 }
                ),
                formatHint: artifact.format
            ))
            // A declared artifact the inventory does not name has no stable
            // Silo id; leaving the slot empty keeps the arrays parallel and
            // lets the controller fall back to Aether's own id for it.
            externalSubtitleAppTrackIDs.append(inventoryItem.map { item in
                SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: item.combinedIndex)
            })
        }

        self.planID = plan.planId
        self.sessionID = sessionID
        self.delivery = plan.delivery
        self.sourceURL = sourceURL
        self.timeline = timeline
        self.audioSourceStreamIndex = nil
        self.externalSubtitleAppTrackIDs = externalSubtitleAppTrackIDs
        let isServerHLS = [
            PlaybackProtocolV3.PlanDelivery.remuxHLS,
            PlaybackProtocolV3.PlanDelivery.transcodeHLS,
        ].contains(plan.delivery)
        options = LoadOptions(
            httpHeaders: effectiveHeaders,
            matchContentEnabled: matchContentEnabled,
            panelIsInHDRMode: panelIsInHDRMode ?? AetherDisplayContext.panelIsInHDRMode,
            audioBridgeMode: audioBridgeMode,
            audioOnly: plan.effectiveRecipe.videoCodec == nil,
            nativeRemoteHLS: isServerHLS,
            preserveASSMarkup: false,
            prepareNativeSubtitles: true,
            eagerNativeSubtitleReaders: true,
            nativeSubtitlePreferredLanguages: preferredSubtitleLanguages,
            preferredAudioLanguages: preferredAudioLanguages,
            preferredSubtitleLanguages: preferredSubtitleLanguages,
            externalSubtitles: externalSubtitles,
            forwardBufferSegments: forwardBufferSegments,
            autoplay: false,
            deinterlaceMode: deinterlaceMode,
            deinterlaceFieldRate: deinterlaceFieldRate
        )
    }

    private static func resolveSidecarURL(_ value: String, relativeTo mediaURL: URL) -> URL? {
        if let absolute = URL(string: value), absolute.scheme != nil {
            return absolute
        }
        guard !mediaURL.isFileURL else {
            return URL(fileURLWithPath: value, relativeTo: mediaURL.deletingLastPathComponent())
                .standardizedFileURL
        }
        return URL(string: value, relativeTo: mediaURL)?.absoluteURL
    }

    static func subtitleRequestHeaders(
        _ headers: [String: String],
        resourceURL: URL,
        trustedOriginURLs: [URL]
    ) -> [String: String] {
        guard !resourceURL.isFileURL else {
            return [:]
        }
        // Origin equality has to normalize the implicit ports, or
        // `https://host/media` and `https://host:443/subtitles` read as
        // different origins and the bearer is stripped from a sidecar that is
        // genuinely same-origin (Aether then gets a 401). `StreamRequest`
        // already owns that comparison for the media URL itself; sharing it
        // keeps the two boundaries from drifting apart.
        let isTrustedOrigin = trustedOriginURLs.contains { trustedURL in
            !trustedURL.isFileURL && StreamRequest.hasSameOrigin(resourceURL, trustedURL)
        }
        return isTrustedOrigin ? headers : [:]
    }
}
