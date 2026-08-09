import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import VideoToolbox

struct ApplePlaybackV3CapabilitySnapshot: Equatable {
    let capabilities: PlaybackV3CodecCapabilities
    let context: PlaybackV3ClientContext

    var outputContextId: String? { context.output.outputContextId }
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
        PlaybackProtocolV3.directStreamResumeFeature
    ]

    /// Video codecs the Apple playback stack decodes on a direct route. This
    /// mirrors `ApplePlaybackRoutePlanner`'s native-direct and loopback
    /// allowlists rather than the wider set FFmpeg can demux: a codec claimed
    /// here is one the server may hand us untranscoded.
    private static let directVideoCodecs = ["h264", "hevc", AppleDecodeCapabilities.mpeg2VideoCodec]

    static func snapshot() -> ApplePlaybackV3CapabilitySnapshot {
        let output = outputSnapshot()
        let isSimulator = AppleDecodeCapabilities.isSimulator
        let videoDecode = videoDecodeAttestation()
        let videoCodecs = videoDecode.map(\.codec)
        let hardwareVideoCodecs = videoDecode.filter(\.hardware).map(\.codec)

        // Audio is decoded by the bundled FFmpeg demuxer on the loopback route,
        // so the flat list is wider than what AVPlayer alone accepts. The
        // narrower per-delivery lists below carry that distinction.
        let audioCodecs = AppleDecodeCapabilities.audioCodecs
        let containers = AppleDecodeCapabilities.containers
        let hdr = output.hdrDetails.map { $0.hdr10 || $0.hlg || !$0.dolbyVisionProfiles.isEmpty } ?? false

        let capabilities = PlaybackV3CodecCapabilities(
            // VideoToolbox attests that a codec family is hardware-decodable;
            // it cannot enumerate the profiles and levels a decoder accepts.
            // The server skips profile/level matching at this tier and still
            // applies every bound we do supply.
            videoEvidence: PlaybackProtocolV3.Evidence.platformAttested,
            audioEvidence: PlaybackProtocolV3.Evidence.platformAttested,
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

        let clientTransformations: [PlaybackV3Transformation] = isSimulator ? [] : [
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

        // The loopback executor demuxes and renders subtitles itself; AVPlayer
        // only carries what the stream already presents as a media selection.
        let loopbackSubtitles = PlaybackV3DeliverySubtitleCapabilities(
            embeddedText: true,
            sidecarText: true,
            assStyling: true,
            embeddedBitmap: true,
            // SidecarSubtitleFetcher intentionally accepts text payloads only;
            // bitmap subtitles are supported when embedded in the original
            // source and decoded by the loopback extractor, not as sidecars.
            sidecarBitmap: false,
            fontAttachments: true
        )
        let avPlayerSubtitles = PlaybackV3DeliverySubtitleCapabilities(
            embeddedText: true,
            sidecarText: true,
            assStyling: false,
            embeddedBitmap: false,
            sidecarBitmap: false,
            fontAttachments: false
        )
        let commonClaims = ["apple_execution_plan_v1", "authenticated_stream_headers"]

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
                subtitles: loopbackSubtitles,
                features: ["apple_native_direct", "apple_local_loopback", "apple_playercore"],
                authHeaderRefresh: true,
                validatedClaims: commonClaims + ["client_subtitle_overlay"],
                transformations: clientTransformations
            ),
            PlaybackProtocolV3.DeliveryClass.progressive: PlaybackV3DeliveryCapability(
                enabled: true,
                supportedOnDevice: true,
                failureReason: nil,
                containers: ["mp4", "mov", "m4v"],
                videoCodecs: videoCodecs,
                audioDecodeCodecs: ["aac", "ac3", "eac3", "alac", "mp3"],
                audioPassthroughCodecs: [],
                maxChannels: 8,
                hdrDetails: output.hdrDetails,
                subtitles: avPlayerSubtitles,
                features: ["apple_avplayer_progressive"],
                authHeaderRefresh: true,
                validatedClaims: commonClaims,
                transformations: []
            ),
            PlaybackProtocolV3.DeliveryClass.hls: PlaybackV3DeliveryCapability(
                enabled: true,
                supportedOnDevice: true,
                failureReason: nil,
                containers: ["hls", "mpegts", "fmp4", "mp4"],
                videoCodecs: videoCodecs,
                audioDecodeCodecs: ["aac", "ac3", "eac3"],
                audioPassthroughCodecs: [],
                maxChannels: 8,
                hdrDetails: output.hdrDetails,
                subtitles: avPlayerSubtitles,
                features: ["apple_avplayer_hls"],
                authHeaderRefresh: true,
                validatedClaims: commonClaims,
                transformations: []
            )
        ]

        let context = PlaybackV3ClientContext(
            protocolVersion: PlaybackProtocolV3.version,
            formFactor: formFactor,
            appVersion: appVersion,
            device: deviceContext,
            output: output,
            deliveries: deliveries
        )
        return ApplePlaybackV3CapabilitySnapshot(capabilities: capabilities, context: context)
    }

    /// What VideoToolbox will actually say about this device's decoders.
    ///
    /// Profiles and levels stay empty because there is no API that enumerates
    /// them — under `platform_attested` the server skips both rather than
    /// treating the gap as a refusal, so fabricating plausible tuples would add
    /// risk and buy nothing. Every other bound here is a real platform fact.
    private static func videoDecodeAttestation() -> [PlaybackV3VideoDecodeCapability] {
        let codecTypes: [(String, CMVideoCodecType)] = [
            ("h264", kCMVideoCodecType_H264),
            ("hevc", kCMVideoCodecType_HEVC)
        ]
        var capabilities: [PlaybackV3VideoDecodeCapability] = codecTypes.compactMap { codec, codecType in
            guard directVideoCodecs.contains(codec), hardwareDecodeSupported(codecType) else {
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
        #if !targetEnvironment(simulator)
        // PlayerCore carries a bounded FFmpeg software path for MPEG-2. Keep
        // it out of the hardware list while still advertising the route the
        // production executor can actually decode.
        capabilities.append(PlaybackV3VideoDecodeCapability(
            codec: AppleDecodeCapabilities.mpeg2VideoCodec,
            decoderName: "FFmpeg",
            profiles: [],
            levels: [],
            bitDepths: [8],
            maxWidth: 1_920,
            maxHeight: 1_080,
            maxFrameRate: 60,
            maxBitrateKbps: 50_000,
            hardware: false
        ))
        #endif
        return capabilities
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

    private static func outputSnapshot() -> PlaybackV3OutputContext {
        // This describes the active output, not just formats the decoder can
        // open. The server gives output HDR evidence precedence over device
        // decoder evidence, so a hardcoded device-wide claim could select an
        // HDR route for an SDR display chain.
        let hdrCapabilities: PlaybackV3HDRCapabilities? = {
            #if targetEnvironment(simulator)
            return PlaybackV3HDRCapabilities(
                hdr10: false,
                hdr10Plus: false,
                hlg: false,
                dolbyVisionProfiles: []
            )
            #elseif os(macOS)
            // macOS exposes a live output-chain eligibility signal instead of
            // AVPlayer.availableHDRModes. It attests HDR presentation, but not
            // Dolby Vision format support, so keep DV profiles empty.
            return hdrDetails(
                hdr10: AVPlayer.eligibleForHDRPlayback,
                hlg: AVPlayer.eligibleForHDRPlayback,
                dolbyVision: false
            )
            #else
            let modes = AVPlayer.availableHDRModes
            return hdrDetails(
                hdr10: modes.contains(.hdr10),
                hlg: modes.contains(.hlg),
                dolbyVision: modes.contains(.dolbyVision)
            )
            #endif
        }()

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
        let hdrIdentity = hdrCapabilities.map {
            "\($0.hdr10)|\($0.hdr10Plus)|\($0.hlg)|\($0.dolbyVisionProfiles.map { String($0) }.joined(separator: ","))"
        } ?? "unknown"
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

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
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
