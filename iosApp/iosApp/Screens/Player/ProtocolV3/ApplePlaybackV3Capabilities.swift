import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import VideoToolbox

struct ApplePlaybackV3CapabilitySnapshot: Equatable {
    let capabilities: PlaybackV3CodecCapabilities
    let context: PlaybackV3ClientContext
    let hdrAvailability: ApplePlaybackHDRAvailability

    var outputContextId: String? { context.output.outputContextId }

    /// Privacy-safe fields describing the exact output capability snapshot
    /// sent with this protocol-v3 attempt. Raw route UIDs and the derived
    /// output-context identifier intentionally stay out of hosted logs.
    var outputDiagnosticsLogFields: String {
        let hdr = context.output.hdrDetails
        let dolbyVisionProfiles = hdr?.dolbyVisionProfiles ?? []
        let profiles = dolbyVisionProfiles.isEmpty
            ? "none"
            : dolbyVisionProfiles.map(String.init).joined(separator: ",")
        let sinkType = context.output.sinkType.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        return
            "hdrOutputEligible=\(hdrAvailability.hdrPlaybackEligible) " +
            "hdr10=\(hdr?.hdr10 ?? false) " +
            "hdr10Plus=\(hdr?.hdr10Plus ?? false) " +
            "hlg=\(hdr?.hlg ?? false) " +
            "dolbyVision=\(!dolbyVisionProfiles.isEmpty) " +
            "dvModes=\(profiles) " +
            "sinkType=\(sinkType)"
    }
}

enum ApplePlaybackV3Capabilities {
    /// Features this client understands, advertised on every request.
    ///
    /// `layout_aware_passthrough` is deliberately absent: the server grants a
    /// validated passthrough claim only to a client that enumerates real sink
    /// channel layouts at `exact` audio evidence, and Apple attests neither.
    /// Advertising it would be a claim we cannot back.
    static let features = [
        PlaybackProtocolV3.planFeature,
        PlaybackProtocolV3.clientTransformFeature,
        PlaybackProtocolV3.routeDiagnosticsFeature,
        PlaybackProtocolV3.deviceQuirksFeature,
        PlaybackProtocolV3.seekReanchorFeature,
        PlaybackProtocolV3.outputChangeFeature,
        PlaybackProtocolV3.directStreamResumeFeature,
        PlaybackProtocolV3.headerAuthenticatedMediaFeature,
        PlaybackProtocolV3.softwareVideoDecodeFeature
    ]

    /// Audiobooks currently restart sessions at part boundaries and do not
    /// retain enough plan identity to request seek re-anchors in place. Their
    /// capability snapshot is audio-only, so it must not opt into the
    /// software-video planner contract either.
    static let audiobookFeatures = features.filter {
        $0 != PlaybackProtocolV3.seekReanchorFeature
            && $0 != PlaybackProtocolV3.softwareVideoDecodeFeature
    }

    /// `authorized_media_origins_v1` is negotiated per attempt rather than
    /// declared once, so it is never part of the static list above: the video
    /// path adds it only when the server advertises it, and both the audiobook
    /// surface and every capability report stay opted out. Audio validates
    /// media URLs as API-relative only, and adding the token there would let a
    /// plan hand it an absolute URL its resolver must reject anyway.
    static func startFeatures(authorizedMediaOrigins: Bool) -> [String] {
        guard authorizedMediaOrigins else { return features }
        return features + [PlaybackProtocolV3.authorizedMediaOriginsFeature]
    }

    /// The audiobook surface is migrated separately but uses the same Aether
    /// execution contract. Keep its first-build claim deliberately narrow.
    private static let audiobookAudioCodecs = [
        "aac", "ac3", "eac3", "alac", "mp3", "flac",
        "pcm", "pcm_s16le", "pcm_s24le"
    ]
    private static let audiobookOriginalContainers = ["mp4"] + AppleDecodeCapabilities.audioContainers
    private static let commonClaims = ["authenticated_stream_headers"]

    /// The Dolby Vision Profile 7 recipes Aether executes on a real device.
    /// Advertised on the `original_http` delivery only — the packaged
    /// deliveries are server-produced and carry no client recipe. These entries
    /// are only valid alongside `client_video_transformations_v1` in
    /// `features`; the server rejects the whole request if a `client` executor
    /// entry appears without that flag.
    static let deviceClientTransformations = [
        PlaybackV3Transformation(
            name: "client_dv7_to_dv81",
            executor: "client",
            recipeVersion: "1",
            validatedClaims: [
                "profile7_rpu_converted_to_profile81",
                "hdr10_base_layer_preserved",
                "enhancement_layer_discarded"
            ]
        ),
        PlaybackV3Transformation(
            name: "client_dv7_to_hdr10",
            executor: "client",
            recipeVersion: "1",
            validatedClaims: [
                "dolby_vision_metadata_removed",
                "hdr10_base_layer_preserved",
                "enhancement_layer_discarded"
            ]
        )
    ]

    static func snapshot() -> ApplePlaybackV3CapabilitySnapshot {
        let hdrAvailability = ApplePlaybackHDRAvailability.probe()
        let output = outputSnapshot(hdrAvailability: hdrAvailability)
        let videoDecode = videoDecodeAttestation()
        var seenVideoCodecs = Set<String>()
        let videoCodecs = videoDecode.map(\.codec).filter {
            seenVideoCodecs.insert($0).inserted
        }
        let hardwareVideoCodecs = videoDecode.filter(\.hardware).map(\.codec)

        // Aether owns demux/decode on original HTTP. The narrower packaged
        // delivery lists below describe the formats the server may emit.
        let audioCodecs = AppleDecodeCapabilities.audioCodecs
        let containers = AppleDecodeCapabilities.containers
        let hdr = output.hdrDetails.map { $0.hdr10 || $0.hlg || !$0.dolbyVisionProfiles.isEmpty } ?? false

        let capabilities = PlaybackV3CodecCapabilities(
            // VideoToolbox attests that a codec family is hardware-decodable;
            // it cannot enumerate the profiles and levels a decoder accepts.
            // The server skips those fields only for hardware entries at this
            // tier and still applies every bound we do supply. Software
            // entries carry profiles the server enforces.
            videoEvidence: PlaybackProtocolV3.Evidence.platformAttested,
            // These are the exact codecs accepted by the pinned Aether build,
            // not codecs attested by an Apple audio-decoder probe.
            audioEvidence: PlaybackProtocolV3.Evidence.declared,
            codecsVideo: videoCodecs,
            codecsVideoHardware: hardwareVideoCodecs,
            codecsAudio: audioCodecs,
            containers: containers,
            maxResolution: AppleDecodeCapabilities.maxResolutionToken,
            hdr: hdr,
            hdrDetails: output.hdrDetails,
            // No passthrough entries: Apple routes audio through the system
            // mixer and cannot enumerate a receiver's per-codec channel
            // layouts, so there is nothing here the server could validate.
            audioPassthrough: output.audioPassthrough,
            videoDecode: videoDecode
        )

        // The `client` executor for these two recipes is Aether's internal
        // route policy, not app code: it converts a Profile 7 RPU to Profile
        // 8.1 when the live panel accepts Dolby Vision, and strips the Dolby
        // Vision metadata down to the HDR10 base layer otherwise. Declaring
        // them is what lets the server keep a DV7 source on `original_http`
        // instead of remuxing it. The server gates `client_dv7_to_dv81` on the
        // profiles in our `dolbyVisionProfiles` and `client_dv7_to_hdr10` on
        // `hdr_details.hdr10`, both of which come from the same display
        // snapshot, so no extra panel condition belongs here.
        //
        // The simulator has no real display or hardware HEVC decoder, so it
        // must not claim either recipe.
        let clientTransformations: [PlaybackV3Transformation] =
            AppleDecodeCapabilities.isSimulator ? [] : deviceClientTransformations

        let aetherSubtitles = PlaybackV3DeliverySubtitleCapabilities(
            embeddedText: true,
            sidecarText: true,
            // The Silo overlay preserves normalized text and placement, not
            // the complete authored ASS style contract.
            assStyling: false,
            embeddedBitmap: true,
            sidecarBitmap: false,
            fontAttachments: false
        )
        let packagedSubtitles = PlaybackV3DeliverySubtitleCapabilities(
            embeddedText: true,
            sidecarText: true,
            assStyling: false,
            embeddedBitmap: false,
            sidecarBitmap: false,
            fontAttachments: false
        )
        let deliveries = [
            PlaybackProtocolV3.DeliveryClass.originalHTTP: PlaybackV3DeliveryCapability(
                enabled: true,
                supportedOnDevice: true,
                failureReason: nil,
                containers: containers,
                videoCodecs: videoCodecs,
                audioDecodeCodecs: audioCodecs,
                audioPassthroughCodecs: [],
                maxChannels: 8,
                hdrDetails: output.hdrDetails,
                subtitles: aetherSubtitles,
                features: [],
                authHeaderRefresh: false,
                validatedClaims: commonClaims + ["client_subtitle_overlay"],
                transformations: clientTransformations
            ),
            PlaybackProtocolV3.DeliveryClass.progressive: PlaybackV3DeliveryCapability(
                enabled: true,
                supportedOnDevice: true,
                failureReason: nil,
                containers: ["mp4", "mov", "m4v"],
                videoCodecs: AppleDecodeCapabilities.packagedVideoCodecs,
                audioDecodeCodecs: ["aac", "ac3", "eac3", "alac", "mp3"],
                audioPassthroughCodecs: [],
                maxChannels: 8,
                hdrDetails: output.hdrDetails,
                subtitles: packagedSubtitles,
                features: [],
                authHeaderRefresh: false,
                validatedClaims: commonClaims,
                transformations: []
            ),
            PlaybackProtocolV3.DeliveryClass.hls: PlaybackV3DeliveryCapability(
                enabled: true,
                supportedOnDevice: true,
                failureReason: nil,
                containers: ["hls", "mpegts", "fmp4", "mp4"],
                // The remote-HLS bypass is intentionally narrower than the
                // original-source Aether route.
                videoCodecs: AppleDecodeCapabilities.packagedVideoCodecs,
                audioDecodeCodecs: ["aac", "ac3", "eac3"],
                audioPassthroughCodecs: [],
                maxChannels: 8,
                hdrDetails: output.hdrDetails,
                subtitles: packagedSubtitles,
                features: [],
                authHeaderRefresh: false,
                validatedClaims: commonClaims,
                transformations: []
            )
        ]

        let context = PlaybackV3ClientContext(
            protocolVersion: PlaybackProtocolV3.version,
            formFactor: formFactor,
            appVersion: appVersion,
            appBuild: appBuild,
            appChannel: appChannel,
            device: deviceContext,
            output: output,
            deliveries: deliveries
        )
        return ApplePlaybackV3CapabilitySnapshot(
            capabilities: capabilities,
            context: context,
            hdrAvailability: hdrAvailability
        )
    }

    /// Capability evidence for Aether's audio-only execution mode. Keep every
    /// advertised delivery executable without relying on a video surface.
    static func audiobookSnapshot() -> ApplePlaybackV3CapabilitySnapshot {
        let base = snapshot()
        let noSubtitles = PlaybackV3DeliverySubtitleCapabilities(
            embeddedText: false,
            sidecarText: false,
            assStyling: false,
            embeddedBitmap: false,
            sidecarBitmap: false,
            fontAttachments: false
        )
        let deliveries = [
            PlaybackProtocolV3.DeliveryClass.originalHTTP: PlaybackV3DeliveryCapability(
                enabled: true,
                supportedOnDevice: true,
                failureReason: nil,
                containers: audiobookOriginalContainers,
                videoCodecs: [],
                audioDecodeCodecs: audiobookAudioCodecs,
                audioPassthroughCodecs: [],
                maxChannels: 8,
                hdrDetails: nil,
                subtitles: noSubtitles,
                features: [],
                authHeaderRefresh: false,
                validatedClaims: commonClaims,
                transformations: []
            ),
            PlaybackProtocolV3.DeliveryClass.progressive: PlaybackV3DeliveryCapability(
                enabled: true,
                supportedOnDevice: true,
                failureReason: nil,
                containers: ["mp4", "mov", "m4v"],
                videoCodecs: [],
                audioDecodeCodecs: ["aac", "ac3", "eac3", "alac", "mp3"],
                audioPassthroughCodecs: [],
                maxChannels: 8,
                hdrDetails: nil,
                subtitles: noSubtitles,
                features: [],
                authHeaderRefresh: false,
                validatedClaims: commonClaims,
                transformations: []
            ),
            PlaybackProtocolV3.DeliveryClass.hls: PlaybackV3DeliveryCapability(
                enabled: true,
                supportedOnDevice: true,
                failureReason: nil,
                containers: ["hls", "mpegts", "fmp4", "mp4"],
                videoCodecs: [],
                audioDecodeCodecs: ["aac", "ac3", "eac3"],
                audioPassthroughCodecs: [],
                maxChannels: 8,
                hdrDetails: nil,
                subtitles: noSubtitles,
                features: [],
                authHeaderRefresh: false,
                validatedClaims: commonClaims,
                transformations: []
            )
        ]
        let capabilities = PlaybackV3CodecCapabilities(
            videoEvidence: base.capabilities.videoEvidence,
            audioEvidence: base.capabilities.audioEvidence,
            codecsVideo: [],
            codecsVideoHardware: [],
            codecsAudio: audiobookAudioCodecs,
            containers: audiobookOriginalContainers,
            maxResolution: nil,
            hdr: false,
            hdrDetails: nil,
            audioPassthrough: nil,
            videoDecode: []
        )
        let output = PlaybackV3OutputContext(
            hdrDetails: nil,
            audioPassthrough: nil,
            currentSink: base.context.output.currentSink,
            sinkType: base.context.output.sinkType,
            outputContextId: base.context.output.outputContextId
        )
        let context = PlaybackV3ClientContext(
            protocolVersion: base.context.protocolVersion,
            formFactor: base.context.formFactor,
            appVersion: base.context.appVersion,
            appBuild: base.context.appBuild,
            appChannel: base.context.appChannel,
            device: base.context.device,
            output: output,
            deliveries: deliveries
        )
        return ApplePlaybackV3CapabilitySnapshot(
            capabilities: capabilities,
            context: context,
            hdrAvailability: base.hdrAvailability
        )
    }

    /// The hardware attestations VideoToolbox supplies, followed by the
    /// narrower software envelopes proven with Aether fixtures.
    ///
    /// Hardware profiles and levels stay empty because VideoToolbox cannot
    /// enumerate them; under `platform_attested` the server skips both only
    /// for `hardware: true` entries. Software entries carry and enforce the
    /// exact exercised profiles plus fixture-bounded performance ceilings.
    static func videoDecodeAttestation() -> [PlaybackV3VideoDecodeCapability] {
        let codecTypes: [(String, CMVideoCodecType)] = [
            ("h264", kCMVideoCodecType_H264),
            ("hevc", kCMVideoCodecType_HEVC)
        ]
        let hardwareCapabilities: [PlaybackV3VideoDecodeCapability] = codecTypes.compactMap { codec, codecType in
            guard hardwareDecodeSupported(codecType) else {
                return nil
            }
            return PlaybackV3VideoDecodeCapability(
                codec: codec,
                decoderName: "VideoToolbox",
                profiles: [],
                levels: [],
                // Apple hardware decodes HEVC Main and Main10; H.264 High 10
                // has no hardware path on any supported device.
                bitDepths: codec == "hevc" ? [8, 10] : [8],
                maxWidth: maxDecodeHeight >= 2_160 ? 3_840 : 1_920,
                maxHeight: maxDecodeHeight,
                // Every device that reaches the minimum OS decodes 4K60. Higher
                // frame rates are only guaranteed below 4K, and the contract has
                // no way to express a rate that depends on resolution, so the
                // lower of the two is the bound we can stand behind.
                maxFrameRate: 60,
                maxBitrateKbps: maxDecodeHeight >= 2_160 ? 120_000 : 25_000,
                hardware: true
            )
        }
        let softwareCapabilities: [(
            codec: String, decoder: String, profiles: [String], bitDepths: [Int],
            maxWidth: Int, maxHeight: Int, maxFrameRate: Double, maxBitrateKbps: Int
        )] = [
            // H.264 remains a duplicate on purpose: the hardware entry covers
            // ordinary 8-bit streams, while this entry is the exercised High
            // 10 software route. MPEG-2 carries the interlaced proof.
            ("h264", "libavcodec", ["high 10"], [10], 1_920, 1_080, 30, 10_000),
            ("av1", "dav1d", ["main"], [10], 1_920, 1_080, 30, 3_000),
            ("vp9", "libavcodec", ["profile 0"], [8], 1_920, 1_080, 30, 3_000),
            // The exercised NTSC fixture's server probe reports 30.303 fps,
            // so its rounded source-rate ceiling must be 31 rather than 30.
            ("mpeg2video", "libavcodec", ["main"], [8], 720, 480, 31, 7_000),
            ("vc1", "libavcodec", ["advanced"], [8], 1_920, 1_080, 30, 32_000),
        ]
        return hardwareCapabilities + softwareCapabilities.map { capability in
            PlaybackV3VideoDecodeCapability(
                codec: capability.codec,
                decoderName: capability.decoder,
                profiles: capability.profiles,
                levels: [],
                bitDepths: capability.bitDepths,
                maxWidth: capability.maxWidth,
                maxHeight: capability.maxHeight,
                maxFrameRate: capability.maxFrameRate,
                maxBitrateKbps: capability.maxBitrateKbps,
                hardware: false
            )
        }
    }

    /// Whether the platform routes this codec to an accelerated decoder.
    private static func hardwareDecodeSupported(_ codecType: CMVideoCodecType) -> Bool {
        #if targetEnvironment(simulator)
        // The simulator services VideoToolbox through the host Mac, so
        // `VTIsHardwareDecodeSupported` answers for the host GPU rather than
        // for any device we could ship to. H.264 is accelerated on every host
        // that can run the simulator; nothing else is worth attesting.
        return codecType == kCMVideoCodecType_H264
        #else
        return VTIsHardwareDecodeSupported(codecType)
        #endif
    }

    /// The tallest frame this build's decoders are guaranteed to accept.
    private static var maxDecodeHeight: Int {
        #if targetEnvironment(simulator)
        1_080
        #else
        2_160
        #endif
    }

    private static func outputSnapshot(
        hdrAvailability: ApplePlaybackHDRAvailability
    ) -> PlaybackV3OutputContext {
        // This describes the active output, not just formats the decoder can
        // open. The server gives output HDR evidence precedence over device
        // decoder evidence, so a hardcoded device-wide claim could select an
        // HDR route for an SDR display chain.
        let hdrCapabilities = hdrDetails(
            hdr10: PlayerSettings.shared.hdrEnabled && hdrAvailability.supportsHDR10,
            hlg: PlayerSettings.shared.hdrEnabled && hdrAvailability.supportsHLG,
            dolbyVision: PlayerSettings.shared.hdrEnabled
                && PlayerSettings.shared.dolbyVisionEnabled
                && hdrAvailability.supportsDolbyVision
        )

        let sink: String
        let sinkType: String
        #if os(macOS)
        sink = "default"
        sinkType = "mac"
        #else
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        sink = outputs.map { $0.uid }.sorted().joined(separator: ",")
        sinkType = outputs.map { $0.portType.rawValue }.sorted().joined(separator: ",")
        #endif
        let hdrIdentity =
            "\(hdrCapabilities.hdr10)|\(hdrCapabilities.hdr10Plus)|\(hdrCapabilities.hlg)|" +
            hdrCapabilities.dolbyVisionProfiles.map(String.init).joined(separator: ",")
        let identity = [platformName, formFactor, sink, sinkType, hdrIdentity].joined(separator: "|")
        return PlaybackV3OutputContext(
            hdrDetails: hdrCapabilities,
            // Apple cannot enumerate receiver codec/layout passthrough facts,
            // and platform-attested audio evidence never earns passthrough.
            audioPassthrough: nil,
            currentSink: boundedField(sink),
            sinkType: boundedField(sinkType),
            outputContextId: outputContextId(identity)
        )
    }

    static func hdrDetails(
        hdr10: Bool,
        hlg: Bool,
        dolbyVision: Bool
    ) -> PlaybackV3HDRCapabilities {
        PlaybackV3HDRCapabilities(
            hdr10: hdr10,
            // Apple exposes no independent HDR10+ output attestation.
            hdr10Plus: false,
            hlg: hlg,
            dolbyVisionProfiles: dolbyVision ? [5, 8] : []
        )
    }

    /// A stable, opaque token for the current output route.
    ///
    /// The server only ever compares this for equality — in attempt keys and
    /// plan invalidation — so a digest of the route identity is exactly as
    /// useful as the identity itself, and stays inside the contract's 128-byte
    /// field bound however many sinks are attached.
    private static func outputContextId(_ identity: String) -> String {
        let digest = SHA256.hash(data: Data(identity.utf8))
        return "apple:" + digest.map { String(format: "%02x", $0) }.joined().prefix(16)
    }

    /// Truncate to the contract's 128-character limit for free-form context
    /// strings; an over-long value is rejected outright by the server.
    private static func boundedField(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        return String(value.prefix(128))
    }

    private static var platformName: String {
        #if os(tvOS)
        "tvos"
        #elseif os(macOS)
        "macos"
        #else
        "ios"
        #endif
    }

    private static var formFactor: String {
        #if os(tvOS)
        "tv"
        #elseif os(macOS)
        "desktop"
        #else
        "mobile"
        #endif
    }

    // Version/build/channel come from the same readers the HTTP headers use,
    // so the two carriers cannot disagree about the same running binary. They
    // deliberately do NOT go through `AppleDeviceIdentity.current`: that
    // initializer also resolves the keychain-backed device id, and a capability
    // snapshot has no need to block on the keychain. A missing Info.plist key
    // reports `unknown` rather than a plausible-looking "0".
    private static var appVersion: String {
        AppleDeviceIdentity.bundleAppVersion
    }

    private static var appBuild: String {
        AppleDeviceIdentity.bundleAppBuild
    }

    private static var appChannel: String {
        AppleDeviceIdentity.buildChannel
    }

    private static var deviceContext: PlaybackV3DeviceContext {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let machine = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var details = ["os_name": platformName]
        if !machine.isEmpty {
            details["machine"] = machine
        }
        #if targetEnvironment(simulator)
        details["simulator"] = "true"
        #endif
        return PlaybackV3DeviceContext(
            platform: platformName,
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            manufacturer: "Apple",
            model: boundedField(machine),
            platformDetails: details
        )
    }
}
