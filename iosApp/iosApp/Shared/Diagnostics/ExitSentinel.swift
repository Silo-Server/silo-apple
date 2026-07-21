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

    private let markerURL: URL
    private let fileManager: FileManager
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
        self.fileManager = fileManager
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.markerURL = markerURL ?? appSupport
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("exit-sentinel.json", isDirectory: false)
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
            try? fileManager.removeItem(at: markerURL)
            return
        }

        let existing = readMarker()
        if let existing, existing.runID != DiagLog.captureSessionID {
            leftoverMarker = existing
        } else if let existing, existing.runID == DiagLog.captureSessionID {
            // The current run's marker already exists. Rewrite it only to fill
            // in the binding once it becomes known — the first foreground can
            // precede the first status refresh — keeping the original start
            // time so the run's duration is unchanged.
            if existing.binding == nil, binding != nil {
                writeMarker(ExitSentinelMarker(
                    runID: existing.runID,
                    startedAt: existing.startedAt,
                    binding: binding,
                    profileID: profileID
                ))
            }
            return
        }
        writeMarker(ExitSentinelMarker(
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
        guard let existing = readMarker(),
              existing.runID == DiagLog.captureSessionID,
              existing.binding == nil else {
            return
        }
        writeMarker(ExitSentinelMarker(
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
        try? fileManager.removeItem(at: markerURL)
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
    }

    private func readMarker() -> ExitSentinelMarker? {
        guard let data = try? Data(contentsOf: markerURL) else {
            return nil
        }
        return try? DiagnosticsJSONCoding.makeDecoder().decode(ExitSentinelMarker.self, from: data)
    }

    private func writeMarker(_ marker: ExitSentinelMarker) {
        do {
            try fileManager.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var directory = markerURL.deletingLastPathComponent()
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let data = try DiagnosticsJSONCoding.makeEncoder().encode(marker)
            try data.write(to: markerURL, options: .atomic)
        } catch {
            return
        }
    }

    private func clearMarker() {
        lock.lock()
        defer { lock.unlock() }

        try? fileManager.removeItem(at: markerURL)
    }
}
#endif
