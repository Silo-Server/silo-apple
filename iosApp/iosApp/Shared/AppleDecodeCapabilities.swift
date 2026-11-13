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
/// libavcodec path at load time, so physical iOS devices and Apple TV 4K report
/// the pinned engine/build manifest without predicting profiles or bit depths
/// in app code, except that iPhone and iPad bound the codecs they may decode
/// only in software (`declaredOnlineVideo`). Downloads have no server replan
/// available when they are played offline, so they retain the bounded
/// platform attestation.
///
/// This is intentionally the only codec/container inventory in the app. Wire
/// surfaces may narrow it for their delivery contract, but must not recreate
/// their own decoder tables.
enum AppleDecodeCapabilities {
    enum StreamingVideoCapabilityMode: Equatable {
        case aetherDeclared
        case platformAttested
    }

    /// The device model, such as `iPhone17,1` or `AppleTV14,1`. A simulator's
    /// `uname` reports the host architecture, so it reads the model it
    /// simulates instead and gets that device's capability policy.
    static let machineIdentifier: String = {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           !simulated.isEmpty {
            return simulated
        }
        #endif
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }()

    /// iPhone, iPad, and Apple TV 4K use Aether's original-file executor.
    /// Keep the optimistic engine declaration off Apple TV HD. It has much
    /// less software-decode headroom than every Apple TV 4K generation and no
    /// online performance signal exists yet that can trigger a typed replan.
    static func streamingVideoCapabilityModeForDevice(
        isTVOS: Bool,
        machineIdentifier: String
    ) -> StreamingVideoCapabilityMode {
        if isTVOS {
            return machineIdentifier.hasPrefix("AppleTV") && machineIdentifier != "AppleTV5,3"
                ? .aetherDeclared : .platformAttested
        }
        return machineIdentifier.hasPrefix("iPhone") || machineIdentifier.hasPrefix("iPad")
            ? .aetherDeclared : .platformAttested
    }

    static var streamingVideoCapabilityMode: StreamingVideoCapabilityMode {
        #if os(tvOS)
        let isTVOS = true
        #else
        let isTVOS = false
        #endif
        return streamingVideoCapabilityModeForDevice(
            isTVOS: isTVOS,
            machineIdentifier: machineIdentifier
        )
    }

    private static var isAppleTVHD: Bool {
        machineIdentifier == "AppleTV5,3"
    }

    /// Silo's declared online video set for the pinned AetherEngine and
    /// FFmpegBuild. Newly bundled formats await capability and playback
    /// validation in silo-apple#299. Aether routes H.264, HEVC, and
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

    /// Audio codecs the client decodes.
    static let audioCodecs = [
        "aac", "ac3", "eac3", "dts", "truehd", "flac", "alac", "mp3",
        "opus", "vorbis", "pcm", "pcm_s16le", "pcm_s24le"
    ]

    /// Silo's declared online audio set from the same Aether/FFmpeg build.
    /// Newly bundled WMA and legacy Flash audio are tracked in silo-apple#299.
    /// Aliases are intentional because scanners do not all spell DTS-HD or PCM alike.
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
    static let videoContainers = [
        "mp4", "mov", "m4v", "mkv", "matroska", "webm", "avi", "ts", "m2ts", "mpegts"
    ]

    /// Bare audio containers proven by the first Aether-only Silo fixture
    /// matrix. The scanner currently normalizes M4A/M4B to `mp4`, but the
    /// aliases remain honest for legacy metadata and future scanner changes.
    ///
    /// Aether supports additional containers, including Ogg. They stay out of
    /// the conservative/download vocabulary; online iOS and Apple TV 4K
    /// playback use the engine manifest below and its per-source probe.
    static let audioContainers = ["mp3", "m4a", "m4b", "aac", "flac", "wav"]

    /// Theme music plays through AVFoundation, not Aether, so it narrows the
    /// bare audio containers to what AVPlayer opens over HTTP. AVFoundation
    /// has no Ogg demuxer, so Vorbis and Opus themes arrive converted to AAC in
    /// MP4. `mp4`/`aac` is also the pair that lets the server convert at all.
    static let themeAudioFormats: [(container: String, codec: String)] = [
        ("mp3", "mp3"),
        ("mp4", "aac"), ("mp4", "alac"),
        ("m4a", "aac"), ("m4a", "alac"),
        ("aac", "aac"),
        ("flac", "flac"),
        ("wav", "pcm"),
    ]

    /// Silo's declared containers for online original HTTP.
    /// Silo's scanner records MPEG program streams (`.mpg`/`.vob`) as `mpeg`,
    /// so that token is what carries FFmpegBuild's `mpegps` demuxer claim.
    /// The pinned FFmpegBuild includes ASF/WMV support. Advertising it together with
    /// the matching audio codecs awaits playback validation in silo-apple#299.
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
            return declaredOnlineVideo.codecs
        case .platformAttested:
            return attestedVideoCodecs
        }
    }

    /// The online declaration's video codecs, and the decode entries that
    /// bound the ones iPhone and iPad may decode only in software. At the
    /// `declared` tier an entry naming a codec narrows the flat claim to the
    /// sources it admits, so the server sends a file outside the measured
    /// software envelope through another route rather than straight to a
    /// decoder that cannot keep up with it.
    ///
    /// - AV1 is unbounded where VideoToolbox decodes it in hardware, the same
    ///   answer AetherEngine routes on. Without hardware AV1 a device claims
    ///   only dav1d's measured envelope, and the simulator, where AV1 direct
    ///   play has been seen never to start, does not claim AV1 at all.
    /// - MPEG-2 always decodes in libavcodec, within its measured envelope.
    ///
    /// Apple TV 4K keeps the unbounded declaration.
    static func declaredOnlineVideo(
        isTVOS: Bool,
        hardwareAV1: Bool,
        isSimulator: Bool
    ) -> (codecs: [String], decode: [AppleVideoDecodeCapability]) {
        guard !isTVOS else { return (aetherOriginalHTTPVideoCodecs, []) }
        var boundedCodecs: Set<String> = ["mpeg2video"]
        var codecs = aetherOriginalHTTPVideoCodecs
        if !hardwareAV1 {
            if isSimulator {
                codecs.removeAll { $0 == "av1" }
            } else {
                boundedCodecs.insert("av1")
            }
        }
        return (codecs, softwareVideoDecodeCapabilities.filter { boundedCodecs.contains($0.codec) })
    }

    static let declaredOnlineVideo: (codecs: [String], decode: [AppleVideoDecodeCapability]) = {
        #if os(tvOS)
        let isTVOS = true
        #else
        let isTVOS = false
        #endif
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif
        return declaredOnlineVideo(
            isTVOS: isTVOS,
            hardwareAV1: hardwareDecodeSupported(kCMVideoCodecType_AV1),
            isSimulator: isSimulator
        )
    }()

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
    /// cap". Apple TV HD stops at 1080p; other device surfaces retain the
    /// existing 2160p fallback token.
    static var maxResolution: String? {
        isAppleTVHD ? "1080p" : nil
    }

    /// `maxResolution` for surfaces that need it spelled out rather than left
    /// open — the V3 snapshot's per-codec decode entries pair it with
    /// explicit pixel dimensions, so "no cap" has nothing to mean there.
    static var maxResolutionToken: String { maxResolution ?? "2160p" }

    static func streamingMaxResolutionToken(for mode: StreamingVideoCapabilityMode) -> String {
        mode == .aetherDeclared ? "2160p" : maxResolutionToken
    }

    static var maxDecodeWidth: Int { maxDecodeHeight >= 2_160 ? 3_840 : 1_920 }
    static var maxDecodeHeight: Int { isAppleTVHD ? 1_080 : 2_160 }

    /// The hardware attestations VideoToolbox supplies, followed by the
    /// narrower software envelopes proven with Aether fixtures. This is the
    /// persistent-download safety contract and the fallback for Apple TV HD
    /// and macOS. Online iOS and Apple TV 4K playback delegate
    /// these decisions to Aether's source probe, apart from the software
    /// envelopes `declaredOnlineVideo` sends from iPhone and iPad.
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
        return hardwareCapabilities + softwareVideoDecodeCapabilities
    }

    /// The software envelopes proven with Aether fixtures.
    private static let softwareVideoDecodeCapabilities: [AppleVideoDecodeCapability] = {
        let capabilities: [(
            codec: String, decoder: String, profiles: [String], bitDepths: [Int],
            maxWidth: Int, maxHeight: Int, maxFrameRate: Double, maxBitrateKbps: Int
        )] = [
            ("h264", "libavcodec", ["high 10"], [10], 1_920, 1_080, 30, 10_000),
            ("av1", "dav1d", ["main"], [10], 1_920, 1_080, 30, 3_000),
            ("vp9", "libavcodec", ["profile 0"], [8], 1_920, 1_080, 30, 3_000),
            // Blu-ray MPEG-2 up to its 40 Mbps video ceiling. 31 fps admits
            // the exercised NTSC fixture, which reports 30.303 fps. Not yet
            // measured on Apple TV HD (silo-apple#1124).
            ("mpeg2video", "libavcodec", ["main"], [8], 1_920, 1_080, 31, 40_000),
            ("vc1", "libavcodec", ["advanced"], [8], 1_920, 1_080, 30, 32_000),
        ]
        return capabilities.map { capability in
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
    }()

    static let hardwareVideoCodecs = videoDecodeAttestationValue.filter(\.hardware).map(\.codec)

    static let attestedVideoCodecs: [String] = {
        var seen = Set<String>()
        return videoDecodeAttestationValue.map(\.codec).filter {
            seen.insert($0).inserted
        }
    }()

    private static func hardwareDecodeSupported(_ codecType: CMVideoCodecType) -> Bool {
        #if targetEnvironment(simulator)
        // VideoToolbox in the simulator reports no hardware decoders, which
        // would leave server-packaged streams and downloads with no video
        // codec. AVPlayer there still plays H.264.
        return codecType == kCMVideoCodecType_H264
        #else
        // AV1 asks the way AetherEngine's `VTCapabilityProbe` does before it
        // routes AV1 to the native player: register the supplemental decoder
        // where the SDK has it, then ask for hardware decode.
        #if os(macOS) || compiler(>=6.2.3)
        if codecType == kCMVideoCodecType_AV1, #available(tvOS 26.2, iOS 26.2, macOS 16.0, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(codecType)
        }
        #endif
        return VTIsHardwareDecodeSupported(codecType)
        #endif
    }
}
