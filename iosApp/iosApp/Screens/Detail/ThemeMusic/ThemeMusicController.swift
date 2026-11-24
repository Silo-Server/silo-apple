import Foundation

/// One theme player's audio. The production output wraps `AVPlayer`; it holds
/// the only copy of the signed URL it was made with.
@MainActor
protocol ThemeAudioOutput: AnyObject {
    var volume: Float { get set }
    /// Loops in place. Only original audio can: it supports byte ranges.
    var isLooping: Bool { get set }
    var isPlaying: Bool { get }
    var onEnded: (() -> Void)? { get set }
    var onFailed: (() -> Void)? { get set }
    /// Playback advanced past the start.
    var onProgress: (() -> Void)? { get set }
    func play()
    func pause()
    /// Stops for good and releases the item and its URL.
    func tearDown()
}

/// Plays a detail page's local theme music, following the web player
/// (`web/src/lib/themeMusic.ts` in silo-server): the first theme of the
/// selected set, faded in, kept playing across pages with the same owner and
/// theme, looped in place when original or with a fresh grant when converted,
/// and retried once with a fresh grant after a failure. Themes are optional, so
/// a refused grant or a failed stream only leaves the page silent.
@MainActor
final class ThemeMusicController {
    typealias Grant = @MainActor (_ ownerId: String, _ themeId: String) async throws -> ThemeMusicGrant
    typealias MakeOutput = @MainActor (ThemeMusicGrant) -> ThemeAudioOutput
    /// Ramps `output` to a volume, then calls the completion.
    typealias Fade = @MainActor (ThemeAudioOutput, Float, @escaping @MainActor () -> Void) -> Void

    enum StopMode {
        /// Fade out.
        case fade
        /// Stop at once with no player taking over: the profile changed, or a
        /// hidden page has nothing playing yet. A theme still fading out
        /// finishes its fade.
        case silence
        /// Stop at once for a player that is starting, silencing any theme
        /// still fading out as well.
        case handOff
    }

    /// Background level under the page, as on the web.
    static let themeVolume: Float = 0.35

    private let grant: Grant
    private let makeOutput: MakeOutput
    private let fade: Fade

    private var output: ThemeAudioOutput?
    private var load: Task<Void, Never>?
    /// Bumped by every load and stop; a callback or grant from an older one is ignored.
    private var generation = 0
    private var owner = ""
    private var theme = ""
    private var loop = false
    private var converted = false
    private var played = false
    private var retry = 0
    private var suspended = false
    /// The theme played to its end and nothing replays it; the page keeps it
    /// selected so staying open or returning does not start it again.
    private var finished = false
    /// Stopped outputs still fading out, so an immediate stop can silence them.
    private var retiring: [ObjectIdentifier: ThemeAudioOutput] = [:]

    init(grant: @escaping Grant, makeOutput: @escaping MakeOutput, fade: @escaping Fade = { ThemeVolumeRamp.fade($0, to: $1, done: $2) }) {
        self.grant = grant
        self.makeOutput = makeOutput
        self.fade = fade
    }

    /// Plays `selection`'s first theme, or stops when there is none.
    func select(_ selection: ThemeSongSet?, loop: Bool) {
        self.loop = loop
        output?.isLooping = loop && !converted
        guard let selection, let song = selection.items.first else {
            stop()
            return
        }
        if owner == selection.ownerId && theme == song.id {
            if suspended {
                suspended = false
                if let output { resume(output) } else if !finished { startLoad() }
            }
            return
        }
        stop()
        owner = selection.ownerId
        theme = song.id
        retry = 0
        startLoad()
    }

    /// Fades out and pauses, keeping the theme so reselecting it resumes in place.
    func suspend() {
        suspended = true
        guard let output else {
            if !finished { stop(.silence) }
            return
        }
        fade(output, 0) { [weak self, weak output] in
            guard let self, let output, self.suspended, self.output === output else { return }
            output.pause()
        }
    }

    /// Ends the theme.
    func stop(_ mode: StopMode = .fade) {
        suspended = false
        finished = false
        generation += 1
        load?.cancel()
        owner = ""
        theme = ""
        if mode == .handOff {
            retiring.values.forEach { $0.tearDown() }
            retiring = [:]
        }
        guard let output else { return }
        self.output = nil
        detach(output)
        if mode != .fade || !output.isPlaying {
            output.tearDown()
        } else {
            let key = ObjectIdentifier(output)
            retiring[key] = output
            fade(output, 0) { [weak self] in
                guard let self, self.retiring.removeValue(forKey: key) != nil else { return }
                output.tearDown()
            }
        }
    }

    /// Resolves once no grant request is in flight. For tests.
    func waitUntilSettled() async {
        while let task = load {
            await task.value
            if load == task { load = nil }
        }
    }

    private func startLoad() {
        generation += 1
        let generation = generation
        let owner = owner
        let theme = theme
        load?.cancel()
        load = Task { [weak self, grant] in
            guard let granted = try? await grant(owner, theme) else { return }
            guard let self, generation == self.generation, !Task.isCancelled else { return }
            self.attach(granted, generation: generation)
        }
    }

    private func attach(_ granted: ThemeMusicGrant, generation: Int) {
        clearOutput()
        let output = makeOutput(granted)
        self.output = output
        converted = granted.isConverted
        played = false
        finished = false
        output.volume = 0
        output.isLooping = loop && !converted
        output.onProgress = { [weak self, weak output] in
            guard let self, let output, generation == self.generation else { return }
            let started = !self.played
            self.played = true
            self.retry = 0
            // The fade-in waits for audible audio: a converted theme is
            // downloaded first, and a fade run meanwhile would end before it.
            if started && !self.suspended { self.fade(output, Self.themeVolume) {} }
        }
        output.onEnded = { [weak self] in
            // A converted stream cannot seek back and its URL may have
            // expired, so a loop replays it with a fresh grant. One that ended
            // without playing spends the same single retry as a failure, so a
            // conversion that fails cleanly cannot replay forever.
            guard let self, generation == self.generation else { return }
            if self.converted && self.loop && !self.suspended && (self.played || self.spendRetry()) {
                self.startLoad()
                return
            }
            // Nothing replays it: let the player go.
            self.finished = true
            self.clearOutput()
        }
        output.onFailed = { [weak self] in
            guard let self, generation == self.generation else { return }
            self.clearOutput()
            if !self.suspended && self.spendRetry() { self.startLoad() }
        }
        resume(output)
    }

    private func resume(_ output: ThemeAudioOutput) {
        guard !suspended else { return }
        output.play()
        // Before its audio has started, `onProgress` fades it in.
        if played { fade(output, Self.themeVolume) {} }
    }

    private func spendRetry() -> Bool {
        defer { retry += 1 }
        return retry == 0
    }

    private func detach(_ output: ThemeAudioOutput) {
        output.onEnded = nil
        output.onFailed = nil
        output.onProgress = nil
    }

    private func clearOutput() {
        guard let output else { return }
        self.output = nil
        detach(output)
        output.tearDown()
    }
}

/// The production volume ramp: twelve steps over 300 ms, as on the web. A new
/// ramp on the same output replaces the one in progress.
@MainActor
enum ThemeVolumeRamp {
    private static var ramps: [ObjectIdentifier: Task<Void, Never>] = [:]

    static func fade(_ output: ThemeAudioOutput, to target: Float, done: @escaping @MainActor () -> Void) {
        let key = ObjectIdentifier(output)
        ramps[key]?.cancel()
        let start = output.volume
        let task = Task { @MainActor [weak output] in
            for step in 1...12 {
                try? await Task.sleep(for: .milliseconds(25))
                guard !Task.isCancelled else { return }
                guard let output else {
                    ramps[key] = nil
                    return
                }
                output.volume = max(0, min(1, start + (target - start) * Float(step) / 12))
            }
            ramps[key] = nil
            done()
        }
        ramps[key] = task
    }
}
