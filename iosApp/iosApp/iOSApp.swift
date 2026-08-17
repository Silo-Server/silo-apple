import SwiftUI
#if DEBUG && os(macOS)
import Darwin
#endif

@main
struct SiloApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(SiloAppDelegate.self) private var appDelegate
    #endif

    init() {
        #if os(tvOS)
        ExitSentinel.shared.appDidLaunch()
        #endif

        #if DEBUG && os(macOS)
        if DVLoopbackFixtureRunner.isRequested {
            DVLoopbackFixtureRunner.runFromCommandLineAndExit()
        }
        #endif

        // Replace FFmpeg's default `av_log` callback before any libavformat
        // context opens. Drops a small allowlist of cosmetic warnings (PGS
        // probe codec-params, TrueHD bitstream gripes during prime) so the
        // player log stays readable; everything else still hits stderr.
        SiloInstallFFmpegLogFilter()

        // Install the shared Nuke-backed image cache before any SwiftUI view
        // runs so poster/backdrop-heavy screens reuse the same pipeline on
        // both iOS and tvOS.
        PosterImageCache.install()

        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.recordBreadcrumb(
            category: .lifecycle,
            tag: "App",
            message: "app launched",
            attrs: ["state": .string("launch")]
        )
        #endif

        #if os(iOS)
        MetricKitCapture.shared.start()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    NotificationCenter.default.post(
                        name: .siloDeepLink,
                        object: nil,
                        userInfo: ["url": url]
                    )
                }
        }
    }
}

extension Notification.Name {
    /// Posted whenever the app receives a `continuum://` deep-link URL
    /// (debug launches, Top Shelf taps). `ContentView` consumes it and
    /// queues until the auth state machine reaches `.authenticated`.
    static let siloDeepLink = Notification.Name("siloDeepLink")
}

#if DEBUG && os(macOS)
private enum DVLoopbackFixtureRunner {
    private struct Options {
        let inputURL: URL
        let outputDirectory: URL
        let includeAudio: Bool
        let audioTrackIndex: Int
        let audioFfIndex: Int
        let audioMode: LoopbackSessionSpec.AudioOutputMode
        let timeoutSeconds: TimeInterval
    }

    private enum RunnerError: Error, CustomStringConvertible {
        case missingInput
        case missingValue(String)
        case invalidInteger(String, String)
        case invalidDouble(String, String)
        case invalidAudioMode(String)
        case inputMissing(String)
        case writerFailed(Error)
        case timedOut(TimeInterval)

        var description: String {
            switch self {
            case .missingInput:
                return "missing input path. Use --debug-dv-fixture <path> or --input <path>."
            case .missingValue(let flag):
                return "missing value for \(flag)"
            case .invalidInteger(let flag, let value):
                return "invalid integer for \(flag): \(value)"
            case .invalidDouble(let flag, let value):
                return "invalid number for \(flag): \(value)"
            case .invalidAudioMode(let value):
                return "invalid audio mode '\(value)'; expected copy, flac, aac, ac3, or ec3"
            case .inputMissing(let path):
                return "input file does not exist: \(path)"
            case .writerFailed(let error):
                return "LoopbackSegmentWriter failed: \(error)"
            case .timedOut(let seconds):
                return "timed out after \(Int(seconds))s waiting for LoopbackSegmentWriter"
            }
        }
    }

    static var isRequested: Bool {
        CommandLine.arguments.contains("--debug-dv-fixture")
            || CommandLine.arguments.contains("-debugDVFixture")
    }

    static func runFromCommandLineAndExit() -> Never {
        do {
            let options = try parseOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            try run(options: options)
            exit(EXIT_SUCCESS)
        } catch {
            fputs("[DVFixture] error: \(error)\n", stderr)
            printUsage()
            exit(EXIT_FAILURE)
        }
    }

    private static func parseOptions(arguments: [String]) throws -> Options {
        var inputPath: String?
        var outputPath: String?
        var includeAudio = true
        var audioTrackIndex = 0
        var audioFfIndex = 1
        var audioMode: LoopbackSessionSpec.AudioOutputMode = .copy
        var timeoutSeconds: TimeInterval = 180

        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--debug-dv-fixture", "-debugDVFixture":
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") {
                    inputPath = arguments[index + 1]
                    index += 1
                }
            case "--input":
                inputPath = try value(after: arg, in: arguments, at: &index)
            case "--output-dir":
                outputPath = try value(after: arg, in: arguments, at: &index)
            case "--no-audio":
                includeAudio = false
            case "--audio-track-index":
                let raw = try value(after: arg, in: arguments, at: &index)
                guard let parsed = Int(raw) else { throw RunnerError.invalidInteger(arg, raw) }
                audioTrackIndex = parsed
            case "--audio-ff-index":
                let raw = try value(after: arg, in: arguments, at: &index)
                guard let parsed = Int(raw) else { throw RunnerError.invalidInteger(arg, raw) }
                audioFfIndex = parsed
            case "--audio-mode":
                let raw = try value(after: arg, in: arguments, at: &index)
                audioMode = try parseAudioMode(raw)
            case "--timeout":
                let raw = try value(after: arg, in: arguments, at: &index)
                guard let parsed = TimeInterval(raw) else { throw RunnerError.invalidDouble(arg, raw) }
                timeoutSeconds = parsed
            case "--help", "-h":
                printUsage()
                exit(EXIT_SUCCESS)
            default:
                if inputPath == nil, !arg.hasPrefix("-") {
                    inputPath = arg
                }
            }
            index += 1
        }

        guard let inputPath, !inputPath.isEmpty else {
            throw RunnerError.missingInput
        }
        let inputURL = url(from: inputPath)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw RunnerError.inputMissing(inputURL.path)
        }

        let outputDirectory = outputPath.map(url(from:)) ?? defaultOutputDirectory(for: inputURL)
        return Options(
            inputURL: inputURL,
            outputDirectory: outputDirectory,
            includeAudio: includeAudio,
            audioTrackIndex: audioTrackIndex,
            audioFfIndex: audioFfIndex,
            audioMode: audioMode,
            timeoutSeconds: timeoutSeconds
        )
    }

    private static func run(options: Options) throws {
        try resetDirectory(options.outputDirectory)

        let session = LoopbackSessionSpec(
            sourceURL: options.inputURL,
            headers: [:],
            videoMode: .convertProfile7To81,
            sourceVideoFrameRate: nil,
            selectedAudio: LoopbackSessionSpec.SelectedAudio(
                trackIndex: options.includeAudio ? options.audioTrackIndex : -1,
                ffIndex: options.includeAudio ? options.audioFfIndex : nil,
                sourceCodec: nil,
                sourceChannelCount: nil,
                sourceChannelLayout: nil,
                outputMode: options.audioMode,
                preservesAtmos: false
            ),
            availableAudioTracks: [],
            manifestMetadata: LoopbackSessionSpec.ManifestMetadata(
                advertisedDolbyVisionProfile: 8,
                compatibilityBrand: "db1p",
                videoRange: "PQ",
                mayClaimAtmos: false
            )
        )

        print("[DVFixture] input=\(options.inputURL.path)")
        print("[DVFixture] output=\(options.outputDirectory.path)")
        if options.includeAudio {
            print("[DVFixture] audioTrackIndex=\(options.audioTrackIndex) audioFfIndex=\(options.audioFfIndex) audioMode=\(audioModeLabel(options.audioMode))")
        } else {
            print("[DVFixture] audio=none")
        }

        let writer = LoopbackSegmentWriter(
            sessionSpec: session,
            outputDirectory: options.outputDirectory
        )
        let semaphore = DispatchSemaphore(value: 0)
        final class ResultBox {
            var error: Error?
        }
        let result = ResultBox()

        writer.onFirstSegmentReady = { playlist in
            print("[DVFixture] firstSegmentReady=\(playlist)")
        }
        writer.onSegmentAppended = { index, duration in
            print("[DVFixture] segment=\(index) totalDuration=\(String(format: "%.1f", duration))")
        }
        writer.onFinished = { error in
            result.error = error
            semaphore.signal()
        }

        writer.start()
        let waitResult = semaphore.wait(timeout: .now() + options.timeoutSeconds)
        if waitResult == .timedOut {
            writer.stop()
            throw RunnerError.timedOut(options.timeoutSeconds)
        }
        if let error = result.error {
            throw RunnerError.writerFailed(error)
        }
        print("[DVFixture] completed output=\(options.outputDirectory.path)")
    }

    private static func value(after flag: String, in arguments: [String], at index: inout Int) throws -> String {
        let next = index + 1
        guard next < arguments.count else { throw RunnerError.missingValue(flag) }
        index = next
        return arguments[next]
    }

    private static func parseAudioMode(_ raw: String) throws -> LoopbackSessionSpec.AudioOutputMode {
        switch raw.lowercased() {
        case "copy":
            return .copy
        case "flac":
            return .transcodeFLAC
        case "aac":
            return .transcodeAAC
        case "ac3", "ac-3":
            return .transcodeAC3
        case "ec3", "ec-3", "eac3", "e-ac-3":
            return .transcodeEC3
        default:
            throw RunnerError.invalidAudioMode(raw)
        }
    }

    private static func audioModeLabel(_ mode: LoopbackSessionSpec.AudioOutputMode) -> String {
        switch mode {
        case .copy:
            return "copy"
        case .transcodeFLAC:
            return "flac"
        case .requireFLAC:
            return "flac-required"
        case .transcodeAAC:
            return "aac"
        case .transcodeAC3:
            return "ac3"
        case .transcodeEC3:
            return "ec3"
        }
    }

    private static func url(from value: String) -> URL {
        if let url = URL(string: value), url.scheme != nil {
            return url
        }
        return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
    }

    private static func defaultOutputDirectory(for inputURL: URL) -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-dv-fixtures", isDirectory: true)
        let name = inputURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return base.appendingPathComponent(name.isEmpty ? "fixture" : name, isDirectory: true)
    }

    private static func resetDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    }

    private static func printUsage() {
        fputs(
            """
            Usage:
              Silo --debug-dv-fixture <input-file> [options]

            Options:
              --output-dir <path>         Output artifact directory.
              --no-audio                  Emit video-only HLS.
              --audio-ff-index <index>    FFmpeg audio stream index. Default: 1.
              --audio-track-index <idx>   Audio ordinal used by player UI. Default: 0.
              --audio-mode <mode>         copy, flac, aac, ac3, or ec3. Default: copy.
              --timeout <seconds>         Writer timeout. Default: 180.

            """,
            stderr
        )
    }
}
#endif
