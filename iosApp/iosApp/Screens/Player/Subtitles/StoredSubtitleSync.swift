import Foundation
import Observation

/// The server calls ``StoredSubtitleSyncModel`` makes, injectable for tests.
struct StoredSubtitleSyncService {
    var status: () async throws -> APIv2SubtitleSyncStatus
    var list: (_ mediaFileId: Int) async throws -> [DownloadedSubtitle]
    var read: (_ id: String, _ mediaFileId: Int) async throws -> DownloadedSubtitle
    var requestSync: (_ id: String) async throws -> SubtitleSyncJob
    var resetTiming: (_ id: String, _ mediaFileId: Int) async throws -> DownloadedSubtitle

    static let live = StoredSubtitleSyncService(
        status: { try await SiloAI.shared.subtitleSyncStatus() },
        list: { try await SiloAI.shared.downloadedSubtitles(mediaFileId: $0) },
        read: { try await SiloAI.shared.storedSubtitleSync(id: $0, mediaFileId: $1) },
        requestSync: { try await SiloAI.shared.requestStoredSubtitleSync(id: $0) },
        resetTiming: { try await SiloAI.shared.resetStoredSubtitleTiming(id: $0, mediaFileId: $1) }
    )
}

/// Timing and sync state of the playing file's stored (downloaded or
/// uploaded) subtitles: loads them, polls running sync jobs, and performs
/// "Sync Subtitle" and "Reset Timing". Mirrors the web player's
/// `useStoredSubtitleSync` so both clients describe the same state the same
/// way.
///
/// ``onTimingChanged`` fires once per observed timing change, so the player
/// fetches that track's cues again. A realtime `subtitle_timing_changed`
/// reports the change itself and marks the timing as already handled, so the
/// read that follows it does not ask for a second fetch.
@MainActor
@Observable
final class StoredSubtitleSyncModel {
    struct Entry: Equatable {
        var subtitle: DownloadedSubtitle
        /// A sync or timing request is on the wire.
        var isBusy = false
        /// The server refused to let this viewer retime the subtitle (403).
        var isForbidden = false
        /// The subtitle's format cannot be synced (422).
        var isUnsupported = false
        /// The last action's failure, in plain words.
        var error: String?
        /// Polling gave up; reopening the menu re-arms it.
        var pollExpired = false

        var isInProgress: Bool { subtitle.sync?.isInProgress == true }
        var canReset: Bool { !subtitle.timing.isIdentity }
        var statusLabel: String? { StoredSubtitleSyncLabel.status(for: subtitle) }
    }

    static let pollInterval: Duration = .seconds(3)
    static let pollLimit: TimeInterval = 5 * 60

    /// The server can align subtitles to audio.
    private(set) var isSyncAvailable = false
    private(set) var entries: [String: Entry] = [:]

    @ObservationIgnored var onTimingChanged: ((String) -> Void)?

    private enum KnownTiming: Equatable {
        case known(SubtitleTiming)
        /// A realtime event already reported this subtitle's change.
        case dirty
    }

    @ObservationIgnored private let service: StoredSubtitleSyncService
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var mediaFileId: Int?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var didProbe = false
    @ObservationIgnored private var knownTiming: [String: KnownTiming] = [:]
    @ObservationIgnored private var pollStarted: [String: Date] = [:]
    @ObservationIgnored private var reading: Set<String> = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(service: StoredSubtitleSyncService = .live, now: @escaping () -> Date = Date.init) {
        self.service = service
        self.now = now
    }

    /// Shown in place of the timing actions after the server refused them.
    static let forbiddenMessage = "Only the person who added this subtitle or an admin can change its timing."

    func entry(for storedId: String?) -> Entry? {
        storedId.flatMap { entries[$0] }
    }

    /// Whether "Sync Subtitle" applies to the entry.
    func canSync(_ entry: Entry) -> Bool {
        isSyncAvailable && !entry.isUnsupported
    }

    /// Whether the timing controls have anything to show for the entry.
    func showsTimingControls(_ entry: Entry) -> Bool {
        entry.isForbidden || canSync(entry) || entry.canReset || entry.error != nil
    }

    /// Points the model at the file now playing; `nil` when playback ends.
    /// A different file drops everything in flight.
    func bind(mediaFileId: Int?) {
        guard mediaFileId != self.mediaFileId else { return }
        generation &+= 1
        self.mediaFileId = mediaFileId
        entries = [:]
        knownTiming = [:]
        pollStarted = [:]
        reading = []
        pollTask?.cancel()
        pollTask = nil
    }

    /// Re-reads the file's stored subtitles and re-arms expired polls, so a
    /// job that finished while the menu was closed shows its result.
    func reload() async {
        guard let mediaFileId else { return }
        let current = generation
        pollStarted = [:]
        for id in entries.keys { entries[id]?.pollExpired = false }
        await probeIfNeeded()
        // Sync state is decoration; the tracks still play without it.
        guard let subtitles = try? await service.list(mediaFileId), current == generation else { return }
        for subtitle in subtitles { observe(subtitle) }
        updatePolling()
    }

    /// Records a subtitle returned by a provider download, polling its sync.
    func remember(_ subtitle: DownloadedSubtitle) {
        guard subtitle.mediaFileId == mediaFileId else { return }
        pollStarted[subtitle.id] = nil
        observe(subtitle)
        updatePolling()
        Task { await probeIfNeeded() }
    }

    /// The server announced new timing for `id` (realtime): reload its cues
    /// now and re-read its state.
    func timingChanged(id: String) {
        knownTiming[id] = .dirty
        onTimingChanged?(id)
        Task { await readOne(id) }
    }

    func requestSync(id: String) async {
        guard entries[id] != nil else { return }
        let current = generation
        patch(id) {
            $0.isBusy = true
            $0.error = nil
            $0.pollExpired = false
        }
        pollStarted[id] = nil
        do {
            let job = try await service.requestSync(id)
            guard current == generation else { return }
            patch(id) {
                $0.isBusy = false
                $0.subtitle = $0.subtitle.replacingSync(job)
            }
            updatePolling()
        } catch {
            guard current == generation else { return }
            handleActionError(error, id: id, fallback: "Couldn't sync this subtitle. Try again.")
        }
    }

    func resetTiming(id: String) async {
        guard let mediaFileId, entries[id] != nil else { return }
        let current = generation
        patch(id) {
            $0.isBusy = true
            $0.error = nil
        }
        do {
            let subtitle = try await service.resetTiming(id, mediaFileId)
            guard current == generation else { return }
            observe(subtitle)
            patch(id) { $0.isBusy = false }
        } catch {
            guard current == generation else { return }
            handleActionError(error, id: id, fallback: "Couldn't reset the timing. Try again.")
        }
    }

    // MARK: - Internals

    private func probeIfNeeded() async {
        guard !didProbe else { return }
        let current = generation
        guard let status = try? await service.status(), current == generation else { return }
        didProbe = true
        isSyncAvailable = status.isAvailable
    }

    private func patch(_ id: String, _ update: (inout Entry) -> Void) {
        guard var entry = entries[id] else { return }
        update(&entry)
        entries[id] = entry
    }

    /// Records a fresh server view of a subtitle and reports a timing change.
    private func observe(_ subtitle: DownloadedSubtitle) {
        let id = subtitle.id
        let previous = knownTiming[id]
        knownTiming[id] = .known(subtitle.timing)
        var entry = entries[id] ?? Entry(subtitle: subtitle)
        entry.subtitle = subtitle
        if !entry.isInProgress {
            pollStarted[id] = nil
            entry.pollExpired = false
        }
        entries[id] = entry
        if case .known(let timing)? = previous, timing != subtitle.timing {
            onTimingChanged?(id)
        }
    }

    private func readOne(_ id: String) async {
        guard let mediaFileId, !reading.contains(id) else { return }
        let current = generation
        reading.insert(id)
        defer {
            // A reset swapped in a new set; never unlock a newer context's read.
            if current == generation { reading.remove(id) }
        }
        do {
            let subtitle = try await service.read(id, mediaFileId)
            guard current == generation else { return }
            observe(subtitle)
        } catch {
            // A lost subtitle or file stops polling; a reload re-arms it.
            guard current == generation else { return }
            patch(id) { $0.pollExpired = true }
        }
    }

    private var pollingIds: [String] {
        entries.values.filter { $0.isInProgress && !$0.pollExpired }.map(\.subtitle.id).sorted()
    }

    private func updatePolling() {
        guard !pollingIds.isEmpty else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        let current = generation
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, current == self.generation, !Task.isCancelled else { return }
                guard await self.pollTick() else { return }
            }
        }
    }

    /// One poll of every running job. Returns false once nothing is left to poll.
    private func pollTick() async -> Bool {
        let ids = pollingIds
        guard !ids.isEmpty else {
            pollTask = nil
            return false
        }
        for id in ids {
            // The first tick starts the clock; remember() and reload() clear it.
            let started = pollStarted[id] ?? now()
            pollStarted[id] = started
            if now().timeIntervalSince(started) >= Self.pollLimit {
                pollStarted[id] = nil
                patch(id) { $0.pollExpired = true }
            } else {
                await readOne(id)
            }
        }
        return true
    }

    private func handleActionError(_ error: Error, id: String, fallback: String) {
        switch Self.httpStatus(of: error) {
        case 403:
            patch(id) {
                $0.isBusy = false
                $0.isForbidden = true
                $0.error = nil
            }
        case 422:
            patch(id) {
                $0.isBusy = false
                $0.isUnsupported = true
                $0.error = "This format can't be synced."
            }
        case 412:
            patch(id) {
                $0.isBusy = false
                $0.error = "The subtitle changed. Try again."
            }
        default:
            patch(id) {
                $0.isBusy = false
                $0.error = fallback
            }
        }
    }

    nonisolated static func httpStatus(of error: Error) -> Int? {
        switch error as? APIv2Error {
        case .problem(let problem)?: return problem.status
        case .httpStatus(let status)?: return status
        default: return nil
        }
    }
}

extension DownloadedSubtitle {
    func replacingSync(_ sync: SubtitleSyncJob?) -> DownloadedSubtitle {
        DownloadedSubtitle(id: id, mediaFileId: mediaFileId, provider: provider, language: language,
            format: format, releaseName: releaseName, score: score, hearingImpaired: hearingImpaired,
            createdAt: createdAt, timing: timing, sync: sync)
    }
}

/// The one-line timing description the web player shows for a stored
/// subtitle ("Synced −3.2 s", "Doesn't match this video", …).
enum StoredSubtitleSyncLabel {
    /// Nil when there is nothing to say: never synced and never adjusted.
    static func status(for subtitle: DownloadedSubtitle) -> String? {
        let timing = subtitle.timing
        switch subtitle.sync?.status ?? "" {
        case "pending", "running":
            return "Syncing…"
        case "no_match":
            return "Doesn't match this video"
        case "failed":
            return "Sync failed"
        case "already_synced":
            if timing.isIdentity { return "Already in sync" }
        case "synced":
            if timing.isIdentity { return "Original timing" }
            if subtitle.sync?.result == timing { return "Synced \(describe(timing))" }
        default:
            break
        }
        return timing.isIdentity ? nil : "Timing adjusted \(describe(timing))"
    }

    /// "+2.3 s" / "−0.4 s".
    static func offset(_ offsetMs: Int) -> String {
        let seconds = Double(abs(offsetMs)) / 1000
        return "\(offsetMs < 0 ? "\u{2212}" : "+")\(String(format: "%.1f", seconds)) s"
    }

    private static let frameRates: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]

    /// Names a scale as the frame-rate conversion it most likely is
    /// ("25→23.976 fps"), or as a plain speed factor. Original time `t`
    /// plays at `t * scale`, so a subtitle cut for the faster rate `from`
    /// stretched onto the slower video rate `to` has `scale = from / to`.
    static func scale(_ scale: Double) -> String? {
        guard scale.isFinite, scale != 1 else { return nil }
        for from in frameRates {
            for to in frameRates where from != to && abs(from / to - scale) <= 1e-6 {
                return "\(rate(from))→\(rate(to)) fps"
            }
        }
        let rounded = (scale * 10_000).rounded() / 10_000
        return "×\(rate(rounded)) speed"
    }

    private static func describe(_ timing: SubtitleTiming) -> String {
        let scaleText = scale(timing.scale)
        let offsetText = timing.offsetMs != 0 || scaleText == nil ? offset(timing.offsetMs) : nil
        return [offsetText, scaleText].compactMap { $0 }.joined(separator: " · ")
    }

    /// `25` → "25", `23.976` → "23.976", as JavaScript prints numbers.
    private static func rate(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
