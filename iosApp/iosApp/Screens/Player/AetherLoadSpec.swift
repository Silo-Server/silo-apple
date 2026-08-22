import AetherEngine
import Foundation

/// Immutable inputs for one Aether load generation.
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
    /// App-facing ids for `options.externalSubtitles`, in registration order.
    /// Aether assigns its own ids starting at `externalSubtitleTrackIDBase`;
    /// the controller translates those back to Silo's stable sidecar ids.
    let externalSubtitleAppTrackIDs: [Int64]

    init(
        offlineURL: URL,
        startPosition: Double,
        audioOnly: Bool,
        audioSourceStreamIndex: Int32? = nil,
        sidecars: [SubtitleUrl] = [],
        preferredAudioLanguages: [String] = [],
        preferredSubtitleLanguages: [String] = [],
        forwardBufferSegments: Int? = nil
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
        externalSubtitleAppTrackIDs = sidecars.map {
            SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: $0.index)
        }
        options = LoadOptions(
            audioOnly: audioOnly,
            preserveASSMarkup: false,
            prepareNativeSubtitles: true,
            eagerNativeSubtitleReaders: true,
            nativeSubtitlePreferredLanguages: preferredSubtitleLanguages,
            preferredAudioLanguages: preferredAudioLanguages,
            preferredSubtitleLanguages: preferredSubtitleLanguages,
            externalSubtitles: externalSubtitles,
            forwardBufferSegments: forwardBufferSegments,
            autoplay: false
        )
    }

    init(
        directURL: URL,
        headers: [String: String],
        startPosition: Double,
        audioOnly: Bool,
        sidecars: [SubtitleUrl] = [],
        preferredAudioLanguages: [String] = [],
        preferredSubtitleLanguages: [String] = [],
        forwardBufferSegments: Int? = nil
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
        externalSubtitleAppTrackIDs = sidecars.map {
            SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: $0.index)
        }
        options = LoadOptions(
            httpHeaders: headers,
            audioOnly: audioOnly,
            preserveASSMarkup: false,
            prepareNativeSubtitles: true,
            eagerNativeSubtitleReaders: true,
            nativeSubtitlePreferredLanguages: preferredSubtitleLanguages,
            preferredAudioLanguages: preferredAudioLanguages,
            preferredSubtitleLanguages: preferredSubtitleLanguages,
            externalSubtitles: externalSubtitles,
            forwardBufferSegments: forwardBufferSegments,
            autoplay: false
        )
    }

    init(
        validating plan: PlaybackV3Plan,
        sessionID: String,
        matchContentEnabled: Bool,
        sourceURLOverride: URL? = nil,
        requestHeaders: [String: String]? = nil,
        resolveURL: ((String) -> URL?)? = nil,
        preferredAudioLanguages: [String] = [],
        preferredSubtitleLanguages: [String] = [],
        forwardBufferSegments: Int? = nil
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

        var externalSubtitles: [ExternalSubtitleTrack] = []
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
                httpHeaders: Self.subtitleRequestHeaders(
                    effectiveHeaders,
                    resourceURL: artifactURL,
                    trustedOriginURLs: [sourceURL]
                ),
                formatHint: artifact.format
            ))
        }

        self.planID = plan.planId
        self.sessionID = sessionID
        self.delivery = plan.delivery
        self.sourceURL = sourceURL
        self.timeline = timeline
        self.audioSourceStreamIndex = nil
        externalSubtitleAppTrackIDs = plan.subtitle.artifact.flatMap { _ in
            plan.subtitle.inventory.first(where: { item in
                item.trackId == plan.subtitle.trackId
            })
        }.map {
            [SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: $0.combinedIndex)]
        } ?? []
        let isServerHLS = [
            PlaybackProtocolV3.PlanDelivery.remuxHLS,
            PlaybackProtocolV3.PlanDelivery.transcodeHLS,
        ].contains(plan.delivery)
        options = LoadOptions(
            httpHeaders: effectiveHeaders,
            matchContentEnabled: matchContentEnabled,
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
            autoplay: false
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
        let isTrustedOrigin = trustedOriginURLs.contains { trustedURL in
            !trustedURL.isFileURL
                && resourceURL.scheme?.lowercased() == trustedURL.scheme?.lowercased()
                && resourceURL.host?.lowercased() == trustedURL.host?.lowercased()
                && resourceURL.port == trustedURL.port
        }
        return isTrustedOrigin ? headers : [:]
    }
}
