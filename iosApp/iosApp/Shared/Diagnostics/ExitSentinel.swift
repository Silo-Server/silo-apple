#if os(iOS) || os(tvOS)
import Darwin
import Foundation

struct ExitSentinelMarker: Codable, Equatable {
    let runID: String
    var startedAt: String
    /// The diagnostics binding active when the run started. Optional so markers
    /// written before binding support (and early launches before the first
    /// status refresh) still decode. Capture attributes the report to this
    /// binding, not to whoever is active at relaunch.
    var binding: DiagnosticsBinding?
    /// The capturing profile active at run start, attribution only.
    var profileID: String?
    /// The process environment the run was armed in. Optional fields so
    /// markers written before they existed still decode; see
    /// `ExitSentinelLeftoverPolicy` for how a missing value is judged.
    var bootTime: TimeInterval?
    var bootSessionUUID: String?
    var appVersion: String?
    var appBuild: String?
    var debuggerAttached: Bool?

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case startedAt = "started_at"
        case binding
        case profileID = "profile_id"
        case bootTime = "boot_time"
        case bootSessionUUID = "boot_session_uuid"
        case appVersion = "app_version"
        case appBuild = "app_build"
        case debuggerAttached = "debugger_attached"
    }

    init(
        runID: String,
        startedAt: String,
        binding: DiagnosticsBinding? = nil,
        profileID: String? = nil,
        environment: ExitSentinelEnvironment? = nil
    ) {
        self.runID = runID
        self.startedAt = startedAt
        self.binding = binding
        self.profileID = profileID
        self.bootTime = environment?.bootTime
        self.bootSessionUUID = environment?.bootSessionUUID
        self.appVersion = environment?.appVersion
        self.appBuild = environment?.appBuild
        self.debuggerAttached = environment?.debuggerAttached
    }

    var startedAtDate: Date {
        DiagnosticsDates.date(from: startedAt) ?? .distantPast
    }

    /// A copy re-attributed to another binding/profile and evidence window,
    /// keeping the environment the run was armed in.
    func rebound(startedAt: String, binding: DiagnosticsBinding, profileID: String?) -> ExitSentinelMarker {
        var marker = self
        marker.startedAt = startedAt
        marker.binding = binding
        marker.profileID = profileID
        return marker
    }
}

/// What a marker records about the process that armed it, so the next launch
/// can tell a crash apart from an exit the app could never have prevented.
struct ExitSentinelEnvironment: Equatable {
    /// `kern.boottime` in seconds since 1970; nil when sysctl fails.
    var bootTime: TimeInterval?
    /// `kern.bootsessionuuid`, new on every boot; nil when sysctl fails.
    var bootSessionUUID: String? = nil
    var appVersion: String
    var appBuild: String
    var debuggerAttached: Bool

    static func current() -> ExitSentinelEnvironment {
        ExitSentinelEnvironment(
            bootTime: systemBootTime(),
            bootSessionUUID: systemBootSessionUUID(),
            appVersion: AppleDeviceIdentity.bundleAppVersion,
            appBuild: AppleDeviceIdentity.bundleAppBuild,
            debuggerAttached: isDebuggerAttached()
        )
    }

    static func systemBootTime() -> TimeInterval? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, u_int(mib.count), &bootTime, &size, nil, 0) == 0, bootTime.tv_sec > 0 else {
            return nil
        }
        return TimeInterval(bootTime.tv_sec) + TimeInterval(bootTime.tv_usec) / 1_000_000
    }

    static func systemBootSessionUUID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let uuid = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return uuid.isEmpty ? nil : uuid
    }

    static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else {
            return false
        }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }
}

/// Decides whether an unclean previous run is worth a report. The sentinel is
/// armed for the whole foreground session, so a power cut, a reboot, an app
/// update, or Xcode stopping a debug session all leave a marker behind that
/// says nothing about Silo's own stability.
enum ExitSentinelLeftoverPolicy {
    enum Decision: Equatable {
        case report
        case dropRebooted
        case dropBuildChanged
        case dropDebuggerAttached
    }

    /// The fallback when either run has no boot session UUID. `kern.boottime`
    /// moves when the system clock is corrected, so only a larger jump counts
    /// as a different boot. A reboot is always further apart than this: the
    /// old boot's uptime before the app armed the marker plus the time the
    /// device takes to boot again. A clock step bigger than this (NTP after a
    /// long sleep) still looks like a reboot, which is why the UUID wins.
    static let bootTimeTolerance: TimeInterval = 10

    static func decide(_ marker: ExitSentinelMarker, current: ExitSentinelEnvironment) -> Decision {
        // A marker without a build was written by a build from before this
        // field existed, which is by construction not the running build. Drop
        // it: the update itself is the likely end of that run.
        guard marker.appBuild == current.appBuild, marker.appVersion == current.appVersion else {
            return .dropBuildChanged
        }
        if marker.debuggerAttached == true || current.debuggerAttached {
            return .dropDebuggerAttached
        }
        // The boot session UUID changes on every boot and on nothing else.
        if let markerSession = marker.bootSessionUUID, let currentSession = current.bootSessionUUID {
            return markerSession == currentSession ? .report : .dropRebooted
        }
        // An unknown boot time on either side cannot prove a reboot. Keep the
        // report rather than let a failing sysctl silence the sentinel.
        if let markerBoot = marker.bootTime,
           let currentBoot = current.bootTime,
           abs(markerBoot - currentBoot) > bootTimeTolerance {
            return .dropRebooted
        }
        return .report
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

    /// Attach the resolved binding/profile to this run's marker, or rebind it
    /// after a same-foreground server/account change. Filling an initially nil
    /// binding preserves the original launch time. Changing an already-bound
    /// identity starts a fresh marker window so breadcrumbs and log lines
    /// captured for the new account cannot reach back into the previous
    /// account's run segment.
    @discardableResult
    func bindCurrentRun(
        runID: String,
        binding: DiagnosticsBinding,
        profileID: String?,
        now: Date = Date()
    ) -> ExitSentinelMarker? {
        guard let existing = readCurrent(), existing.runID == runID else {
            return nil
        }
        guard existing.binding != binding || existing.profileID != profileID else {
            return existing
        }
        let marker = existing.rebound(
            startedAt: existing.binding == nil
                ? existing.startedAt
                : DiagnosticsTimestamp.string(from: now),
            binding: binding,
            profileID: profileID
        )
        writeCurrent(marker)
        return marker
    }

    /// Promote an unclean previous run's marker — one sitting in the current
    /// slot with a different run id — into the leftover slot *before* the caller
    /// overwrites the current slot with this run's marker, so the crash evidence
    /// survives even if `captureLeftoverIfNeeded()` can't consume it this launch
    /// (status/profile lookup temporarily unavailable) and the relaunch then
    /// backgrounds. Never clobbers a leftover a prior relaunch already failed to
    /// capture. Returns whatever leftover is now persisted (nil if none), so the
    /// caller can surface it for a capture retry.
    ///
    /// `shouldPreserve` vets the previous run at this, its only promotion: a
    /// rejected marker is removed instead of promoted. A leftover already in
    /// its slot was vetted when it was promoted and is not judged again, so a
    /// later reboot cannot discard a crash that is still waiting for capture.
    @discardableResult
    func preserveLeftoverFromCurrentSlot(
        currentRunID: String,
        shouldPreserve: (ExitSentinelMarker) -> Bool = { _ in true }
    ) -> ExitSentinelMarker? {
        guard let current = readCurrent(), current.runID != currentRunID else {
            // The current slot is empty or holds this run's own marker: nothing
            // to promote, but hand back any leftover a prior relaunch left.
            return readLeftover()
        }
        if let existing = readLeftover() {
            return existing
        }
        guard shouldPreserve(current) else {
            clearCurrent()
            return nil
        }
        write(current, to: leftoverURL)
        return current
    }

    /// Record that a debugger attached to this run after it was armed.
    func markCurrentRunDebuggerAttached(runID: String) {
        guard var marker = readCurrent(), marker.runID == runID, marker.debuggerAttached != true else {
            return
        }
        marker.debuggerAttached = true
        writeCurrent(marker)
    }

    /// Clear only the current-run slot (normal background/terminate). The
    /// leftover slot is deliberately left intact so an un-captured crash marker
    /// is retried on the next launch instead of being lost.
    func clearCurrent() { remove(at: currentURL) }

    /// Clear the current slot only when it belongs to `runID`. During cold
    /// launch the slot can still hold an unclean previous run that has not yet
    /// been promoted to the leftover slot; profile-gate disarming must preserve
    /// that crash evidence for `appDidEnterForeground()` to promote.
    @discardableResult
    func clearCurrent(runID: String) -> Bool {
        guard readCurrent()?.runID == runID else {
            return false
        }
        clearCurrent()
        return true
    }

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
    // disabled the sentinel neither arms nor reports. This process's current
    // marker is removed, but an unclean previous run is preserved for later
    // promotion/capture. Read under `lock` (see appDidEnterForeground) and
    // replaced only through `setCaptureEnabled` so the closure storage is
    // never accessed concurrently.
    private var captureEnabledGate: () -> Bool = { false }

    private let store: ExitSentinelMarkerStore
    private let environment: () -> ExitSentinelEnvironment
    private let lock = NSLock()
    private var leftoverMarker: ExitSentinelMarker?
    private var isForeground = false

    /// Serializes replacing the consent gate with the lock that guards its
    /// read, so the coordinator can update it off the main actor safely.
    func setCaptureEnabled(_ isEnabled: @escaping () -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        captureEnabledGate = isEnabled
    }

    init(
        markerURL: URL? = nil,
        fileManager: FileManager = .default,
        environment: @escaping () -> ExitSentinelEnvironment = { .current() }
    ) {
        self.environment = environment
        let resolvedMarkerURL = markerURL ?? DiagnosticsStorageRoot.baseDirectory(fileManager: fileManager)
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

        isForeground = true

        // Preserve an unclean previous run's marker into the leftover slot
        // before arming (overwriting) the current slot below, so a crash marker
        // is not destroyed before captureLeftoverIfNeeded() consumes it. Also
        // surfaces any leftover a prior relaunch failed to capture so it retries.
        let environment = environment()
        let preserved = store.preserveLeftoverFromCurrentSlot(currentRunID: DiagLog.captureSessionID) { marker in
            ExitSentinelLeftoverPolicy.decide(marker, current: environment) == .report
        }
        if leftoverMarker == nil {
            leftoverMarker = preserved
        }

        guard captureEnabledGate() else {
            store.clearCurrent(runID: DiagLog.captureSessionID)
            return
        }
        armCurrentRun(binding: binding, profileID: profileID, now: now, environment: environment)
    }

    /// Reconcile the marker after the latest async profile check. This is not a
    /// synthetic foreground event: a successful adult result arms only if a
    /// real lifecycle callback says the app is still foreground. A backgrounded
    /// app remains disarmed until its next real `appDidEnterForeground()`.
    func profileEligibilityDidResolve(
        binding: DiagnosticsBinding,
        profileID: String?,
        now: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard captureEnabledGate() else {
            store.clearCurrent(runID: DiagLog.captureSessionID)
            return
        }
        guard isForeground else { return }
        armCurrentRun(binding: binding, profileID: profileID, now: now, environment: environment())
    }

    /// Arm or update this process's marker. Caller holds `lock`.
    private func armCurrentRun(
        binding: DiagnosticsBinding?,
        profileID: String?,
        now: Date,
        environment: ExitSentinelEnvironment
    ) {
        let existing = store.readCurrent()
        if let existing, existing.runID == DiagLog.captureSessionID {
            if environment.debuggerAttached {
                store.markCurrentRunDebuggerAttached(runID: existing.runID)
            }
            // Fill an initially unknown binding, or rebind an existing marker
            // after a server/account switch in this same foreground run.
            if let binding {
                store.bindCurrentRun(
                    runID: existing.runID,
                    binding: binding,
                    profileID: profileID,
                    now: now
                )
            }
            return
        }
        store.writeCurrent(ExitSentinelMarker(
            runID: DiagLog.captureSessionID,
            startedAt: DiagnosticsTimestamp.string(from: now),
            binding: binding,
            profileID: profileID,
            environment: environment
        ))
    }

    /// Fill in the diagnostics binding on the *current run's* marker as soon as
    /// diagnostics resolves it, rather than waiting for the next foreground. The
    /// sentinel receives its first lifecycle callback before status/profile
    /// resolution. If it was already armed from last-known context, this fills
    /// an unknown binding; otherwise the later eligibility reconciliation arms
    /// it. If the marker is already bound to another account, rewrite it and
    /// begin a new evidence window for the new binding.
    /// Resolving binding/profile before calling keeps this off the coordinator's
    /// breadcrumb-context lock (see `appDidEnterForeground`).
    func bindCurrentMarker(binding: DiagnosticsBinding, profileID: String?, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        guard captureEnabledGate() else { return }
        store.bindCurrentRun(
            runID: DiagLog.captureSessionID,
            binding: binding,
            profileID: profileID,
            now: now
        )
    }

    /// Immediately remove only this run's armed marker when profile eligibility
    /// is forced closed. A previously preserved crash leftover remains available
    /// for its original adult profile; a newly confirmed adult profile re-arms
    /// the current run only when the tracked lifecycle is still foreground.
    func disarmCurrentRun() {
        lock.lock()
        defer { lock.unlock() }
        store.clearCurrent(runID: DiagLog.captureSessionID)
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
        clearMarkerAndLeaveForeground()
    }

    func appWillTerminate() {
        clearMarkerAndLeaveForeground()
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
    private func clearMarkerAndLeaveForeground() {
        lock.lock()
        defer { lock.unlock() }

        isForeground = false
        store.clearCurrent()
    }
}
#endif
