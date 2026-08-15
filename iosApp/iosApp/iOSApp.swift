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
        ContinuumInstallFFmpegLogFilter()

        // Install the shared Nuke-backed image cache before any SwiftUI view
        // runs so poster/backdrop-heavy screens reuse the same pipeline on
        // both iOS and tvOS.
        PosterImageCache.install()

        #if os(iOS) || os(tvOS)
        // Opens the launch phase timeline. This runs before any consent
        // context exists, so the line lands in `EarlyBootBuffer` and only
        // reaches disk if this launch's first consent establish permits it —
        // that staging is exactly what makes a launch-path crash reportable.
        LaunchTimeline.recordProcessStart()
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
                        name: .continuumDeepLink,
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
    static let continuumDeepLink = Notification.Name("continuumDeepLink")
}

#if os(iOS) || os(tvOS)
/// The launch and app-lifecycle phase timeline.
///
/// A user whose app dies during launch can report nothing useful: there is no
/// screen to describe and no playback session to correlate. This type is the
/// single funnel that turns that report into evidence — one ordered chain of
/// `.lifecycle` breadcrumbs from `SiloApp.init` to the first real screen, and
/// then the foreground/background/termination edges for the rest of the run.
///
/// Two properties make the chain diagnostic rather than decorative:
///
/// * **It is written to the breadcrumb journal, not the log ring.** The
///   journal is the only diagnostics artifact that survives the process, so a
///   launch that never reaches its next phase leaves the chain truncated
///   exactly where it died. The ring holds 4000 lines and evicts oldest-first,
///   which is the wrong storage for the handful of lines that matter most.
/// * **`duration_ms` is the gap since the previous phase**, not since process
///   start. Reading the chain top-to-bottom therefore localizes a stall to one
///   segment without the reader subtracting timestamps.
///
/// Three tags share the one chain, because tags are how a reader groups a
/// report: `App` for process-level events (launch, memory, termination),
/// `Startup` for the cold-launch chain, `Scene` for scene-phase edges. `App`
/// and `Scene` are the spellings the pre-existing breadcrumbs already used, and
/// are kept so older reports stay comparable to new ones.
///
/// Everything here is deliberately cheap and allocation-light: this is the
/// pre-main-screen path, and instrumentation that slows launch changes the
/// thing it is measuring.
enum LaunchTimeline {
    /// `DispatchTime` rather than `Date` so a mid-launch wall-clock correction
    /// (NTP settling right after boot is the common one) cannot render a
    /// negative or wildly inflated `duration_ms`.
    nonisolated(unsafe) private static var lastMark = DispatchTime.now()
    /// When the app entered the background, or `nil` when it is not currently
    /// backgrounded. Serves two purposes that a plain "has ever backgrounded"
    /// flag could not:
    ///
    /// * It distinguishes the warm return-to-foreground from the
    ///   `.inactive → .active` step every cold launch also performs, which is
    ///   what `launch_type` encodes. Clearing it when the foreground edge
    ///   consumes it is what keeps the *next* `.inactive → .active` pair —
    ///   Control Centre, a notification banner, an app-switcher peek, none of
    ///   which background the app — from being mislabelled as a warm return.
    /// * It times the foreground event against the moment the app actually
    ///   backgrounded rather than against the phase chain's `lastMark`, which
    ///   the intervening `.inactive` step advances. See `record`.
    nonisolated(unsafe) private static var backgroundedAt: DispatchTime?
    nonisolated(unsafe) private static var didRecordRootView = false
    nonisolated(unsafe) private static var didRecordFirstContent = false
    /// Guards the four fields above — the `unsafe` in their annotation is
    /// discharged here, matching how `DiagnosticsCoordinator` guards its own
    /// nonisolated statics. Every current caller is main-actor bound
    /// (`App.init`, SwiftUI view callbacks), but a lock costs nothing on an
    /// uncontended path and keeps a future off-main caller from tearing the
    /// chain.
    private static let lock = NSLock()

    // MARK: - Marks

    /// A monotonic point for callers that time their own work (prefetches,
    /// foreground refreshes) rather than advancing the phase chain.
    static func mark() -> DispatchTime { .now() }

    static func milliseconds(since mark: DispatchTime) -> Int {
        milliseconds(from: mark, to: .now())
    }

    /// Unsigned subtraction on `uptimeNanoseconds` traps on underflow, so the
    /// ordering is checked rather than assumed. `end < start` is not reachable
    /// from a correctly-paired mark, but a clamp is cheaper than a crash inside
    /// diagnostics code.
    private static func milliseconds(from start: DispatchTime, to end: DispatchTime) -> Int {
        let startNanos = start.uptimeNanoseconds
        let endNanos = end.uptimeNanoseconds
        guard endNanos > startNanos else { return 0 }
        return Int((endNanos - startNanos) / 1_000_000)
    }

    // MARK: - Launch chain

    /// `SiloApp.init`. Runs before any consent context exists, so this line
    /// stages in `EarlyBootBuffer` and reaches disk only if the launch's first
    /// consent establish permits it.
    ///
    /// `launch_type` is always `cold` here: reaching `init` means the process
    /// was created. The warm counterpart is recorded by `recordScenePhase`
    /// when an already-running process returns from the background.
    static func recordProcessStart() {
        lock.lock()
        lastMark = .now()
        lock.unlock()
        record(
            tag: "App",
            phase: "process_start",
            message: "app launched",
            state: "launch",
            launchType: "cold",
            includesDuration: false
        )
    }

    /// The root view's first `onAppear` — the first evidence that SwiftUI got
    /// as far as rendering. A launch that logs `process_start` and nothing
    /// else died in static setup or scene creation.
    static func recordRootViewAppeared() {
        lock.lock()
        let alreadyRecorded = didRecordRootView
        didRecordRootView = true
        lock.unlock()
        guard !alreadyRecorded else { return }
        record(phase: "root_view", message: "root view appeared")
    }

    /// Entering the stored-credential / profile resolution that decides the
    /// initial route. Verbose because the interesting line is its completion;
    /// this one only exists to separate "never started the check" from
    /// "started it and hung", which is the difference between a broken scene
    /// and a wedged Keychain or server probe.
    static func recordInitialStateCheckStarted() {
        record(.verbose, phase: "initial_state", message: "initial state check started")
    }

    /// The resolved initial route. `state` is the auth-state token, so a
    /// report shows which tree the app was trying to build.
    static func recordInitialStateResolved(state: String) {
        record(phase: "initial_state", message: "initial state resolved", state: state)
    }

    /// The startup splash animation finished. Recorded separately from the
    /// route commit because the two gate each other: the app shows real
    /// content only once both this and the state check are done, so seeing
    /// which arrived last tells you whether launch was animation-bound or
    /// network/Keychain-bound.
    static func recordSplashFinished() {
        record(phase: "splash", message: "startup splash finished")
    }

    /// First real content: the initial route is committed and the splash is
    /// gone. This closes the cold-launch chain — its absence in a report is
    /// the signal that the user never got a usable app.
    static func recordFirstContent(state: String) {
        lock.lock()
        let alreadyRecorded = didRecordFirstContent
        didRecordFirstContent = true
        lock.unlock()
        guard !alreadyRecorded else { return }
        record(
            phase: "first_content",
            message: "initial route committed",
            state: state,
            outcome: "success"
        )
    }

    // MARK: - Run lifecycle

    /// The single scene-phase funnel. `.active` and `.background` are the
    /// state changes worth keeping unconditionally; `.inactive` fires for
    /// every control-centre pull, notification banner, and app-switcher peek,
    /// so it is verbose-tier detail rather than timeline.
    static func recordScenePhase(_ state: String) {
        switch state {
        case "active":
            // Consume the background mark: a resume is `.background →
            // .inactive → .active`, and the app stays active until the next
            // real `.background`. Leaving the mark set would relabel every
            // later `.inactive → .active` blip — Control Centre, a banner, an
            // app-switcher peek — as a warm foreground with a nonsense
            // duration.
            lock.lock()
            let backgroundStart = backgroundedAt
            backgroundedAt = nil
            lock.unlock()
            if let backgroundStart {
                // `duration_ms` here is the time spent backgrounded, which is
                // what distinguishes a quick app-switch from a resume the
                // system may have jetsammed state out from under. It is
                // measured from the `.background` edge rather than from the
                // phase chain's `lastMark`, because the intervening
                // `.inactive` step advances that mark even when its verbose
                // line is suppressed — timing it off the chain would report
                // the inactive→active gap (a few milliseconds) as the
                // background dwell.
                record(
                    tag: "Scene",
                    phase: "foreground",
                    message: "app foregrounded",
                    state: state,
                    launchType: "warm",
                    duration: milliseconds(since: backgroundStart)
                )
            } else {
                record(tag: "Scene", phase: "scene", message: "scene became active", state: state)
            }
        case "background":
            lock.lock()
            backgroundedAt = .now()
            lock.unlock()
            record(tag: "Scene", phase: "background", message: "app backgrounded", state: state)
        default:
            record(.verbose, tag: "Scene", phase: "scene", message: "scene phase changed", state: state)
        }
    }

    /// Memory pressure. Warning level because the usual next event is a jetsam
    /// kill, which leaves no other trace at all — this line plus a missing
    /// termination line is how that reads in a report.
    static func recordMemoryWarning(state: String) {
        record(
            level: .warning,
            tag: "App",
            phase: "memory_warning",
            message: "memory warning",
            state: state
        )
    }

    /// A clean termination. Its presence is as diagnostic as its content: an
    /// abnormal-exit report whose breadcrumbs end without this line did not
    /// shut down through the normal path.
    static func recordTermination(state: String) {
        record(tag: "App", phase: "terminate", message: "app terminating", state: state)
    }

    // MARK: - Off-chain outcomes

    /// Outcome of a server refresh that is not a phase transition (the
    /// post-authentication hydration and its foreground retry). Timed by the
    /// caller against its own `mark()`, so it does not disturb the phase
    /// chain's inter-phase deltas.
    ///
    /// Failures are essential and successes are verbose, deliberately: a
    /// foreground refresh runs on every return to the app, so recording the
    /// happy path at essential tier would spend the report's breadcrumb budget
    /// on the one outcome that needs no explanation. A refresh that failed —
    /// leaving overlays, capabilities, or nav customization stale for the rest
    /// of the session — is the line a report needs.
    static func recordRefreshOutcome(
        phase: String,
        since mark: DispatchTime,
        failureReason: String?
    ) {
        var attrs: [String: DiagLogAttributeValue] = [
            "phase": .string(phase),
            "duration_ms": .int(milliseconds(since: mark)),
            "outcome": .string(failureReason == nil ? "success" : "failure"),
        ]
        if let failureReason {
            attrs["reason"] = .string(failureReason)
        }
        DiagTrace.breadcrumb(
            failureReason == nil ? .verbose : .essential,
            level: failureReason == nil ? .info : .warning,
            category: .lifecycle,
            tag: "Startup",
            message: "content refresh finished",
            attrs: attrs
        )
    }

    // MARK: - Emission

    private static func record(
        _ verbosity: DiagnosticsVerbosity = .essential,
        level: DiagnosticsLogLevel = .info,
        tag: String = "Startup",
        phase: String,
        message: String,
        state: String? = nil,
        outcome: String? = nil,
        launchType: String? = nil,
        includesDuration: Bool = true,
        duration: Int? = nil
    ) {
        // Advance the chain even when the tier suppresses the line, so a
        // suppressed verbose step cannot silently fold its time into the next
        // essential one's `duration_ms`. One `now` for both the delta and the
        // new mark, so the segments tile the timeline exactly.
        //
        // `duration` overrides only what is *reported*, for the one event whose
        // documented interval is not the inter-phase gap (the background dwell
        // on `foreground`). The mark still advances, so the chain keeps tiling
        // and the next phase's delta stays honest.
        var attrs: [String: DiagLogAttributeValue] = ["phase": .string(phase)]
        if includesDuration {
            let now = DispatchTime.now()
            lock.lock()
            let previous = lastMark
            lastMark = now
            lock.unlock()
            attrs["duration_ms"] = .int(duration ?? milliseconds(from: previous, to: now))
        }
        if let state { attrs["state"] = .string(state) }
        if let outcome { attrs["outcome"] = .string(outcome) }
        if let launchType { attrs["launch_type"] = .string(launchType) }
        DiagTrace.breadcrumb(
            verbosity,
            level: level,
            category: .lifecycle,
            tag: tag,
            message: message,
            attrs: attrs
        )
    }
}
#endif

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
              Continuum --debug-dv-fixture <input-file> [options]

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
