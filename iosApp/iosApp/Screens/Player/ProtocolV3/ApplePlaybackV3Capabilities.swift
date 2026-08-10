import AVFoundation
import Foundation
import VideoToolbox

struct ApplePlaybackV3CapabilitySnapshot: Equatable {
    let capabilities: PlaybackV3CodecCapabilities
    let context: PlaybackV3ClientContext

    var outputRouteGeneration: Int64 { context.output.outputRouteGeneration }
}

enum ApplePlaybackV3Capabilities {
    static let features = [
        PlaybackProtocolV3.planFeature,
        PlaybackProtocolV3.detailedDecodeFeature,
        PlaybackProtocolV3.clientTransformFeature,
        PlaybackProtocolV3.routeDiagnosticsFeature,
        PlaybackProtocolV3.deviceQuirksFeature,
        PlaybackProtocolV3.seekReanchorFeature,
        PlaybackProtocolV3.directStreamResumeFeature
    ]

    static func snapshot() -> ApplePlaybackV3CapabilitySnapshot {
        let output = outputSnapshot()
        let isSimulator = AppleDecodeCapabilities.isSimulator

        // This snapshot describes every route the plan can land on, including
        // the software decoder, so it claims MPEG-2.
        let videoCodecs = AppleDecodeCapabilities.videoCodecs(includingMPEG2: true)
        let hardwareVideoCodecs = AppleDecodeCapabilities.hardwareVideoCodecs
        let audioCodecs = AppleDecodeCapabilities.audioCodecs
        let containers = AppleDecodeCapabilities.containers
        let maxWidth = AppleDecodeCapabilities.maxDecodeWidth
        let maxHeight = AppleDecodeCapabilities.maxDecodeHeight

        let capabilities = PlaybackV3CodecCapabilities(
            codecsVideo: videoCodecs,
            codecsVideoHardware: hardwareVideoCodecs,
            codecsAudio: audioCodecs,
            containers: containers,
            maxResolution: AppleDecodeCapabilities.maxResolutionToken,
            hdr: output.hdrDetails?.claimsAnyHDR ?? false,
            hdrDetails: output.hdrDetails,
            audioPassthrough: output.audioPassthrough,
            videoDecode: videoCodecs.map { codec in
                let hardware = hardwareVideoCodecs.contains(codec)
                return PlaybackV3VideoDecodeCapability(
                    codec: codec,
                    // MPEG-2 is the one claimed codec PlayerCore routes to the
                    // FFmpeg decoder (`videoDecodeMode = .software`); naming
                    // VideoToolbox for it would contradict `hardware: false`.
                    decoderName: hardware ? "VideoToolbox" : "FFmpeg",
                    profiles: [],
                    levels: [],
                    bitDepths: codec == "hevc" ? [8, 10] : [8],
                    maxWidth: maxWidth,
                    maxHeight: maxHeight,
                    maxFrameRate: 60,
                    maxBitrateKbps: isSimulator ? 25_000 : 120_000,
                    hardware: hardware
                )
            }
        )

        let directTransformations: [PlaybackV3Transformation] = isSimulator ? [] : [
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

        let directSubtitles = PlaybackV3EngineSubtitleCapabilities(
            embeddedText: true,
            sidecarText: true,
            assStyling: true,
            embeddedBitmap: true,
            sidecarBitmap: true,
            fontAttachments: true
        )
        let avPlayerSubtitles = PlaybackV3EngineSubtitleCapabilities(
            embeddedText: true,
            sidecarText: true,
            assStyling: false,
            embeddedBitmap: false,
            sidecarBitmap: false,
            fontAttachments: false
        )
        let commonClaims = ["apple_execution_plan_v1", "authenticated_stream_headers"]

        // The protocol currently uses Media3 engine identifiers as wire-level
        // route slots. They are compatibility aliases here: each is translated
        // into a typed Apple PlaybackExecutionPlan before any player is loaded.
        let engines = [
            "media3_direct": PlaybackV3EngineCapability(
                enabled: true,
                supportedOnDevice: true,
                failureReason: nil,
                containers: containers,
                videoCodecs: videoCodecs,
                audioDecodeCodecs: audioCodecs,
                audioPassthroughCodecs: [],
                maxChannels: 8,
                hdrDetails: output.hdrDetails,
                subtitles: directSubtitles,
                features: ["apple_native_direct", "apple_local_loopback", "apple_playercore"],
                authHeaderRefresh: true,
                validatedClaims: commonClaims + ["client_subtitle_overlay"],
                transformations: directTransformations
            ),
            "media3_progressive_remux": PlaybackV3EngineCapability(
                enabled: true,
                supportedOnDevice: true,
                failureReason: nil,
                containers: ["mp4", "mov", "m4v"],
                videoCodecs: ["h264", "hevc"],
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
            "media3_hls": PlaybackV3EngineCapability(
                enabled: true,
                supportedOnDevice: true,
                failureReason: nil,
                containers: ["hls", "mpegts", "fmp4", "mp4"],
                videoCodecs: ["h264", "hevc"],
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
            features: features,
            platform: platformName,
            formFactor: formFactor,
            appVersion: appVersion,
            device: deviceContext,
            output: output,
            engines: engines
        )
        return ApplePlaybackV3CapabilitySnapshot(capabilities: capabilities, context: context)
    }

    private static func outputSnapshot() -> PlaybackV3OutputContext {
        // Per format: can this client be handed such a source and render it
        // correctly? That is what the server plans against, and it does not
        // depend on the display — PQ, HLG and the HDR10 base of HDR10+ all tone
        // map on the display layer, and Dolby Vision is resolved during decode.
        //
        // Dolby Vision is per-platform because Profile 5 carries IPT-PQ-c2
        // pixels with no HDR10-compatible base layer: rendering it correctly
        // needs a display in Dolby Vision mode. tvOS negotiates that mode over
        // HDMI and refuses playback when the panel declines
        // (`PlayerCore.applyDvGatedDisplayCriteria`); iOS drives its own
        // Dolby-Vision-capable panel. macOS has neither — an arbitrary
        // attached display is never negotiated — so it claims only the
        // base-layer-compatible Profile 8.
        let hdrDetails: PlaybackV3HDRCapabilities? = {
            #if targetEnvironment(simulator)
            // The simulator decodes H.264 only, matching the rest of this
            // snapshot and `PlaybackSessionBridge.makeClientCaps()`.
            return PlaybackV3HDRCapabilities(
                hdr10: false,
                hdr10Plus: false,
                hlg: false,
                dolbyVisionProfiles: []
            )
            #elseif os(macOS)
            return PlaybackV3HDRCapabilities(
                hdr10: true,
                hdr10Plus: true,
                hlg: true,
                dolbyVisionProfiles: [8]
            )
            #else
            return PlaybackV3HDRCapabilities(
                hdr10: true,
                hdr10Plus: true,
                hlg: true,
                dolbyVisionProfiles: [5, 8]
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
        let identity = [platformName, formFactor, sink, sinkType, String(describing: hdrDetails)].joined(separator: "|")
        return PlaybackV3OutputContext(
            hdrDetails: hdrDetails,
            audioPassthrough: PlaybackV3AudioPassthrough(
                passthroughCodecs: [],
                spatializerEnabled: false,
                maxChannels: 8,
                entries: []
            ),
            currentSink: sink.isEmpty ? nil : sink,
            sinkType: sinkType.isEmpty ? nil : sinkType,
            outputRouteGeneration: stableGeneration(identity)
        )
    }

    private static func stableGeneration(_ identity: String) -> Int64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return Int64(hash & UInt64(Int64.max))
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
        let model = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return PlaybackV3DeviceContext(
            manufacturer: "Apple",
            model: model.isEmpty ? nil : model,
            brand: "Apple",
            device: model.isEmpty ? nil : model,
            product: formFactor,
            socManufacturer: "Apple",
            socModel: nil,
            buildId: nil,
            buildDisplay: ProcessInfo.processInfo.operatingSystemVersionString,
            securityPatch: nil,
            sdkInt: nil,
            abis: ["arm64"]
        )
    }
}
