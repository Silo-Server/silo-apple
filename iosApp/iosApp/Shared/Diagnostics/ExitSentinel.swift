#if os(iOS) || os(tvOS)
import Foundation

struct ExitSentinelMarker: Codable, Equatable {
    let runID: String
    let startedAt: String
    /// The diagnostics binding active when the run started. Optional so markers
    /// written before binding support (and early launches before the first
    /// status refresh) still decode. Capture attributes the report to this
    /// binding, not to whoever is active at relaunch.
    let binding: DiagnosticsBinding?
    /// The capturing profile active at run start, attribution only.
    let profileID: String?

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case startedAt = "started_at"
        case binding
        case profileID = "profile_id"
    }

    init(runID: String, startedAt: String, binding: DiagnosticsBinding? = nil, profileID: String? = nil) {
        self.runID = runID
        self.startedAt = startedAt
        self.binding = binding
        self.profileID = profileID
    }

    var startedAtDate: Date {
        DiagnosticsDates.date(from: startedAt) ?? .distantPast
    }
}

/// On-disk storage for the exit sentinel's two marker slots: the *current run's*
/// marker and a *preserved leftover* from an unclean previous run. Splitting the
/// slot bookkeeping out of `ExitSentinel` (which is tvOS-only) keeps the load-
/// bearing property — a crash leftover survives arming and later clearing the
/// current run — unit-testable on any platform.
///
/// The two slots are distinct files so arming the current run can never
/// overwrite an un-captured leftover. Decode is unchanged from the single-slot
/// layout (`ExitSentinelMarker`), so a marker written by an older build still
/// reads back and is promoted into the leftover slot on the first foreground.
struct ExitSentinelMarkerStore {
    let currentURL: URL
    let leftoverURL: URL
    private let fileManager: FileManager

    init(currentURL: URL, fileManager: FileManager = .default) {
        self.currentURL = currentURL
        self.leftoverURL = Self.leftoverURL(for: currentURL)
        self.fileManager = fileManager
    }

    func readCurrent() -> ExitSentinelMarker? { read(at: currentURL) }
    func readLeftover() -> ExitSentinelMarker? { read(at: leftoverURL) }

    func writeCurrent(_ marker: ExitSentinelMarker) { write(marker, to: currentURL) }

    /// Promote an unclean previous run's marker — one sitting in the current
    /// slot with a different run id — into the leftover slot *before* the caller
    /// overwrites the current slot with this run's marker, so the crash evidence
    /// survives even if `captureLeftoverIfNeeded()` can't consume it this launch
    /// (status/profile lookup temporarily unavailable) and the relaunch then
    /// backgrounds. Never clobbers a leftover a prior relaunch already failed to
    /// capture. Returns whatever leftover is now persisted (nil if none), so the
    /// caller can surface it for a capture retry.
    @discardableResult
    func preserveLeftoverFromCurrentSlot(currentRunID: String) -> ExitSentinelMarker? {
        guard let current = readCurrent(), current.runID != currentRunID else {
            // The current slot is empty or holds this run's own marker: nothing
            // to promote, but hand back any leftover a prior relaunch left.
            return readLeftover()
        }
        if let existing = readLeftover() {
            return existing
        }
        write(current, to: leftoverURL)
        return current
    }

    /// Clear only the current-run slot (normal background/terminate). The
    /// leftover slot is deliberately left intact so an un-captured crash marker
    /// is retried on the next launch instead of being lost.
    func clearCurrent() { remove(at: currentURL) }

    func clearLeftover() { remove(at: leftoverURL) }

    func clearAll() {
        remove(at: currentURL)
        remove(at: leftoverURL)
    }

    private func read(at url: URL) -> ExitSentinelMarker? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? DiagnosticsJSONCoding.makeDecoder().decode(ExitSentinelMarker.self, from: data)
    }

    private func write(_ marker: ExitSentinelMarker, to url: URL) {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var directory = url.deletingLastPathComponent()
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let data = try DiagnosticsJSONCoding.makeEncoder().encode(marker)
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
    }

    private func remove(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    /// Sibling of the current-run file that holds the preserved leftover — e.g.
    /// `exit-sentinel.json` → `exit-sentinel-leftover.json`. Derived from the
    /// current-run filename so an injected test URL gets a matching sibling
    /// rather than a shared fixed name.
    private static func leftoverURL(for currentURL: URL) -> URL {
        let ext = currentURL.pathExtension
        let base = currentURL.deletingPathExtension().lastPathComponent
        var url = currentURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(base)-leftover", isDirectory: false)
        if !ext.isEmpty {
            url.appendPathExtension(ext)
        }
        return url
    }
}
#endif

#if os(tvOS)
final class ExitSentinel {
    static let shared = ExitSentinel()

    // Consent gate, wired by DiagnosticsCoordinator to the same signal that
    // gates breadcrumb capture (mode != never for the active binding). While
    // disabled the sentinel neither arms nor reports, and any marker left on
    // disk is removed. Read under `lock` (see appDidEnterForeground) and
    // replaced only through `setCaptureEnabled` so the closure storage is
    // never accessed concurrently.
    private var captureEnabledGate: () -> Bool = { true }

    private let store: ExitSentinelMarkerStore
    private let lock = NSLock()
    private var leftoverMarker: ExitSentinelMarker?

    /// Serializes replacing the consent gate with the lock that guards its
    /// read, so the coordinator can update it off the main actor safely.
    func setCaptureEnabled(_ isEnabled: @escaping () -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        captureEnabledGate = isEnabled
    }

    init(markerURL: URL? = nil, fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let resolvedMarkerURL = markerURL ?? appSupport
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("exit-sentinel.json", isDirectory: false)
        self.store = ExitSentinelMarkerStore(currentURL: resolvedMarkerURL, fileManager: fileManager)
    }

    func appDidEnterForeground(now: Date = Date()) {
        // Resolve the binding/profile before taking `lock`: reading the binding
        // hits the coordinator's breadcrumb-context lock, and the coordinator
        // takes that lock before wiring our capture gate — grabbing it here,
        // outside `lock`, keeps the two locks from nesting in opposite orders.
        let binding = DiagnosticsCoordinator.currentDiagnosticsBinding
        let profileID = AuthService.shared.profileId

        lock.lock()
        defer { lock.unlock() }

        guard captureEnabledGate() else {
            leftoverMarker = nil
            store.clearAll()
            return
        }

        // Preserve an unclean previous run's marker into the leftover slot
        // before arming (overwriting) the current slot below, so a crash marker
        // is not destroyed before captureLeftoverIfNeeded() consumes it. Also
        // surfaces any leftover a prior relaunch failed to capture so it retries.
        let preserved = store.preserveLeftoverFromCurrentSlot(currentRunID: DiagLog.captureSessionID)
        if leftoverMarker == nil {
            leftoverMarker = preserved
        }

        let existing = store.readCurrent()
        if let existing, existing.runID == DiagLog.captureSessionID {
            // The current run's marker already exists. Rewrite it only to fill
            // in the binding once it becomes known — the first foreground can
            // precede the first status refresh — keeping the original start
            // time so the run's duration is unchanged.
            if existing.binding == nil, binding != nil {
                store.writeCurrent(ExitSentinelMarker(
                    runID: existing.runID,
                    startedAt: existing.startedAt,
                    binding: binding,
                    profileID: profileID
                ))
            }
            return
        }
        store.writeCurrent(ExitSentinelMarker(
            runID: DiagLog.captureSessionID,
            startedAt: DiagnosticsTimestamp.string(from: now),
            binding: binding,
            profileID: profileID
        ))
    }

    /// Fill in the diagnostics binding on the *current run's* marker as soon as
    /// diagnostics resolves it, rather than waiting for the next foreground. The
    /// sentinel arms in `SiloApp.init` — before the first status refresh — so on
    /// a first login after install (or after a purge), with no last-known
    /// snapshot, the marker is written with `binding == nil`. The coordinator
    /// calls this on refresh completion so a crash later in this same foreground
    /// is attributed to the right account instead of being treated as a legacy
    /// (unbound) marker on relaunch. No-op if there is no marker, it belongs to
    /// another run, or it is already bound; the original `startedAt` is kept so
    /// the run's duration is unchanged. Resolving binding/profile before calling
    /// keeps this off the coordinator's breadcrumb-context lock (see
    /// `appDidEnterForeground`).
    func bindCurrentMarker(binding: DiagnosticsBinding, profileID: String?) {
        lock.lock()
        defer { lock.unlock() }

        guard captureEnabledGate() else { return }
        guard let existing = store.readCurrent(),
              existing.runID == DiagLog.captureSessionID,
              existing.binding == nil else {
            return
        }
        store.writeCurrent(ExitSentinelMarker(
            runID: existing.runID,
            startedAt: existing.startedAt,
            binding: binding,
            profileID: profileID
        ))
    }

    func purge() {
        lock.lock()
        defer { lock.unlock() }

        leftoverMarker = nil
        store.clearAll()
    }

    func appDidLaunch(now: Date = Date()) {
        appDidEnterForeground(now: now)
    }

    func appDidEnterBackground() {
        clearMarker()
    }

    func appWillTerminate() {
        clearMarker()
    }

    func captureLeftoverIfNeeded() async {
        let marker = currentLeftoverMarker()
        guard let marker else { return }
        let captured = await DiagnosticsCoordinator.shared.captureAbnormalExit(marker: marker)
        if captured {
            clearLeftoverMarker()
        }
    }

    private func currentLeftoverMarker() -> ExitSentinelMarker? {
        lock.lock()
        defer { lock.unlock() }
        return leftoverMarker
    }

    private func clearLeftoverMarker() {
        lock.lock()
        defer { lock.unlock() }
        leftoverMarker = nil
        store.clearLeftover()
    }

    /// Clears only the current-run slot; the preserved leftover slot survives a
    /// normal background/terminate so an un-captured crash marker is retried on
    /// the next launch.
    private func clearMarker() {
        lock.lock()
        defer { lock.unlock() }

        store.clearCurrent()
    }
}
#endif
