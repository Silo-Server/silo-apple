import CoreMedia
import Foundation
import VideoToolbox

struct AppleVideoDecodeCapability: Equatable, Sendable {
    let codec: String
    let decoderName: String?
    let profiles: [String]
    let levels: [Int]
    let bitDepths: [Int]
    let maxWidth: Int
    let maxHeight: Int
    let maxFrameRate: Double
    let maxBitrateKbps: Int
    let hardware: Bool
}

/// What the pinned Apple playback stack can actually open, stated once.
///
/// Online playback and persistent downloads deliberately use different
/// policies. Aether probes each online source and chooses its native or
/// libavcodec path at load time, so supported Apple TV 4K hardware reports the
/// pinned engine/build manifest without predicting profiles, bit depths, or
/// performance in app code. Downloads have no server replan available when
/// they are played offline, so they retain the bounded platform attestation.
///
/// This is intentionally the only codec/container inventory in the app. Wire
/// surfaces may narrow it for their delivery contract, but must not recreate
/// their own decoder tables.
enum AppleDecodeCapabilities {
    enum StreamingVideoCapabilityMode: Equatable {
        case aetherDeclared
        case platformAttested
    }

    #if targetEnvironment(simulator)
    static let isSimulator = true
    #else
    static let isSimulator = false
    #endif

    static let machineIdentifier: String = {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }()

    /// Keep the optimistic engine declaration off Apple TV HD. It has much
    /// less software-decode headroom than every Apple TV 4K generation and no
    /// online performance signal exists yet that can trigger a typed replan.
    static func streamingVideoCapabilityModeForDevice(
        isTVOS: Bool,
        isSimulator: Bool,
        machineIdentifier: String
    ) -> StreamingVideoCapabilityMode {
        guard isTVOS,
              !isSimulator,
              machineIdentifier.hasPrefix("AppleTV"),
              machineIdentifier != "AppleTV5,3" else {
            return .platformAttested
        }
        return .aetherDeclared
    }

    static var streamingVideoCapabilityMode: StreamingVideoCapabilityMode {
        #if os(tvOS)
        let isTVOS = true
        #else
        let isTVOS = false
        #endif
        return streamingVideoCapabilityModeForDevice(
            isTVOS: isTVOS,
            isSimulator: isSimulator,
            machineIdentifier: machineIdentifier
        )
    }

    private static var isAppleTVHD: Bool {
        machineIdentifier == "AppleTV5,3"
    }

    /// The narrower, fixture-bounded software set retained for downloads and
    /// conservative streaming clients. H.264 High 10 is added as a separate
    /// detailed entry below because ordinary H.264 is also hardware-backed.
    static let softwareVideoCodecs = ["av1", "vp9", "mpeg2video", "vc1"]

    /// The complete online video manifest of AetherEngine 6.67.2 with
    /// FFmpegBuild 3.0.0 (same FFmpeg n8.1.2 decoder set as 2.4.3). Aether routes H.264, HEVC, and
    /// hardware-decodable AV1 natively when the exact probed stream permits;
    /// every other decoder present in the build goes through libavcodec.
    static let aetherOriginalHTTPVideoCodecs = [
        "h264", "hevc", "av1", "vp9", "vp8", "mpeg4", "mpeg2video", "vc1",
        "qtrle", "msmpeg4v1", "msmpeg4v2", "msmpeg4v3", "wmv1", "wmv2", "wmv3"
    ]

    /// Server-packaged progressive/HLS routes remain on their native codec
    /// vocabulary. The software claims above describe Aether's original-file
    /// path and must not silently broaden a receiver/native-HLS contract.
    static let packagedVideoCodecs = hardwareVideoCodecs

    /// Audio codecs the client decodes. The simulator keeps the conservative
    /// subset it was aligned to alongside its H.264-only video claim, rather
    /// than the device's full list.
    static let audioCodecs: [String] = isSimulator
        ? ["aac", "ac3", "eac3", "mp3", "opus", "flac"]
        : [
            "aac", "ac3", "eac3", "dts", "truehd", "flac", "alac", "mp3",
            "opus", "vorbis", "pcm", "pcm_s16le", "pcm_s24le"
        ]

    /// Audio decoders present in the same Aether/FFmpeg build. Aliases are
    /// intentional because scanners do not all spell DTS-HD or PCM alike.
    /// `pcm_bluray` is the Blu-ray LPCM decoder FFmpegBuild ships for M2TS;
    /// `pcm_dvd` stays absent because the build does not enable it.
    static let aetherOriginalHTTPAudioCodecs = [
        "aac", "ac3", "eac3", "mp3", "mp2", "flac", "opus", "vorbis", "alac",
        "truehd", "mlp", "dts", "dca", "dts-hd", "dtshd", "pcm", "pcm_s16le",
        "pcm_s24le", "pcm_f32le", "pcm_bluray"
    ]

    /// Video containers the client demuxes. Both spellings of the two aliased
    /// ones (`mkv`/`matroska`, `ts`/`mpegts`) are listed: the server sends
    /// whichever its scanner recorded, and a claim it cannot match reads as
    /// "unsupported".
    static let videoContainers: [String] = isSimulator
        ? ["mp4", "mov", "m4v", "mkv", "matroska", "ts", "m2ts", "mpegts"]
        : ["mp4", "mov", "m4v", "mkv", "matroska", "webm", "avi", "ts", "m2ts", "mpegts"]

    /// Bare audio containers proven by the first Aether-only Silo fixture
    /// matrix. The scanner currently normalizes M4A/M4B to `mp4`, but the
    /// aliases remain honest for legacy metadata and future scanner changes.
    ///
    /// Aether supports additional containers, including Ogg. They stay out of
    /// the conservative/download vocabulary; online Apple TV 4K playback uses
    /// the engine manifest below and relies on its per-source probe.
    static let audioContainers = ["mp3", "m4a", "m4b", "aac", "flac", "wav"]

    /// Demuxers used by the pinned Aether build for online original HTTP.
    /// Silo's scanner records MPEG program streams (`.mpg`/`.vob`) as `mpeg`,
    /// so that token is what carries FFmpegBuild's `mpegps` demuxer claim.
    /// ASF/WMV stays absent even though WMV elementary streams in Matroska are
    /// supported; FFmpegBuild does not ship the corresponding container path.
    private static let aetherVideoContainers = [
        "mp4", "m4v", "mov", "mkv", "matroska", "avi", "mpegts", "ts", "m2ts",
        "mts", "3gp", "3g2", "mpeg", "vob", "ogg", "webm", "flv"
    ]
    private static let aetherAudioContainers = [
        "mp3", "aac", "m4a", "m4b", "flac", "alac", "wav", "opus", "ogg"
    ]

    static let aetherOriginalHTTPContainers: [String] = {
        var seen = Set<String>()
        return (aetherVideoContainers + aetherAudioContainers).filter {
            seen.insert($0).inserted
        }
    }()

    /// The full direct-play container vocabulary used by flat capability
    /// surfaces and by the `original_http` V3 delivery.
    static let containers = videoContainers + audioContainers

    static func streamingVideoCodecs(for mode: StreamingVideoCapabilityMode) -> [String] {
        switch mode {
        case .aetherDeclared:
            return aetherOriginalHTTPVideoCodecs
        case .platformAttested:
            return attestedVideoCodecs
        }
    }

    static func streamingAudioCodecs(for mode: StreamingVideoCapabilityMode) -> [String] {
        mode == .aetherDeclared
            ? aetherOriginalHTTPAudioCodecs
            : audioCodecs
    }

    static func streamingContainers(for mode: StreamingVideoCapabilityMode) -> [String] {
        mode == .aetherDeclared
            ? aetherOriginalHTTPContainers
            : containers
    }

    static var streamingVideoCodecs: [String] {
        streamingVideoCodecs(for: streamingVideoCapabilityMode)
    }

    static var streamingAudioCodecs: [String] {
        streamingAudioCodecs(for: streamingVideoCapabilityMode)
    }

    static var streamingContainers: [String] {
        streamingContainers(for: streamingVideoCapabilityMode)
    }

    /// The conservative resolution ceiling, or nil for "no client-imposed
    /// cap". The simulator and Apple TV HD stop at 1080p; other device
    /// surfaces retain the existing 2160p fallback token.
    static var maxResolution: String? {
        isSimulator || isAppleTVHD ? "1080p" : nil
    }

    /// `maxResolution` for surfaces that need it spelled out rather than left
    /// open — the V3 snapshot's per-codec decode entries pair it with
    /// explicit pixel dimensions, so "no cap" has nothing to mean there.
    static var maxResolutionToken: String { maxResolution ?? "2160p" }

    static func streamingMaxResolutionToken(for mode: StreamingVideoCapabilityMode) -> String {
        mode == .aetherDeclared ? "2160p" : maxResolutionToken
    }

    static var streamingMaxResolutionToken: String {
        streamingMaxResolutionToken(for: streamingVideoCapabilityMode)
    }

    static var maxDecodeWidth: Int { maxDecodeHeight >= 2_160 ? 3_840 : 1_920 }
    static var maxDecodeHeight: Int { isSimulator || isAppleTVHD ? 1_080 : 2_160 }

    /// The hardware attestations VideoToolbox supplies, followed by the
    /// narrower software envelopes proven with Aether fixtures. This is the
    /// persistent-download safety contract and the fallback for Apple TV HD,
    /// simulators, iOS, and macOS; online Apple TV 4K playback does not send
    /// these predictions.
    static func videoDecodeAttestation() -> [AppleVideoDecodeCapability] {
        videoDecodeAttestationValue
    }

    private static let videoDecodeAttestationValue = makeVideoDecodeAttestation()

    private static func makeVideoDecodeAttestation() -> [AppleVideoDecodeCapability] {
        let codecTypes: [(String, CMVideoCodecType)] = [
            ("h264", kCMVideoCodecType_H264),
            ("hevc", kCMVideoCodecType_HEVC)
        ]
        let hardwareCapabilities: [AppleVideoDecodeCapability] = codecTypes.compactMap { codec, codecType in
            guard hardwareDecodeSupported(codecType) else {
                return nil
            }
            return AppleVideoDecodeCapability(
                codec: codec,
                decoderName: "VideoToolbox",
                profiles: [],
                levels: [],
                bitDepths: codec == "hevc" ? [8, 10] : [8],
                maxWidth: maxDecodeWidth,
                maxHeight: maxDecodeHeight,
                maxFrameRate: 60,
                maxBitrateKbps: maxDecodeHeight >= 2_160 ? 120_000 : 25_000,
                hardware: true
            )
        }
        let softwareCapabilities: [(
            codec: String, decoder: String, profiles: [String], bitDepths: [Int],
            maxWidth: Int, maxHeight: Int, maxFrameRate: Double, maxBitrateKbps: Int
        )] = [
            ("h264", "libavcodec", ["high 10"], [10], 1_920, 1_080, 30, 10_000),
            ("av1", "dav1d", ["main"], [10], 1_920, 1_080, 30, 3_000),
            ("vp9", "libavcodec", ["profile 0"], [8], 1_920, 1_080, 30, 3_000),
            // The exercised NTSC fixture reports 30.303 fps.
            ("mpeg2video", "libavcodec", ["main"], [8], 720, 480, 31, 7_000),
            ("vc1", "libavcodec", ["advanced"], [8], 1_920, 1_080, 30, 32_000),
        ]
        return hardwareCapabilities + softwareCapabilities.map { capability in
            AppleVideoDecodeCapability(
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

    static let hardwareVideoCodecs = videoDecodeAttestationValue.filter(\.hardware).map(\.codec)

    static let attestedVideoCodecs: [String] = {
        var seen = Set<String>()
        return videoDecodeAttestationValue.map(\.codec).filter {
            seen.insert($0).inserted
        }
    }()

    private static func hardwareDecodeSupported(_ codecType: CMVideoCodecType) -> Bool {
        #if targetEnvironment(simulator)
        // The simulator answers for the host GPU, not a shippable device.
        return codecType == kCMVideoCodecType_H264
        #else
        return VTIsHardwareDecodeSupported(codecType)
        #endif
    }
}
