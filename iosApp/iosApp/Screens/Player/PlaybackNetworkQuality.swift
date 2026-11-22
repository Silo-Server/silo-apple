//
//  PlaybackNetworkQuality.swift
//  Silo (iOS + tvOS + macOS)
//
//  Which quality pair playback asks for on the current connection.
//
//  On iPhone and iPad a connection that costs data — mobile data, a hotspot
//  the system marks expensive, or Low Data Mode — uses the cellular pair
//  (`playback.cellular_preferred_quality` + `playback.cellular_max_bitrate_kbps`)
//  instead of the main one. The server never learns which network the device
//  is on, so the client sends the chosen pair as `quality_preference` and
//  `bandwidth_cap_kbps`, and replans with the other pair when the connection
//  changes mid-playback. Apple TV and Mac always use the main pair.
//

import Foundation
import Network

/// The network tier playback uses for quality selection:
/// - `unmetered`: uses the main quality pair;
/// - `metered`: cellular or an expensive hotspot without Low Data Mode — uses the cellular pair;
/// - `lowData`: iOS Low Data Mode (`NWPath.isConstrained`) — applies the 2 Mbps ceiling on top of the cellular pair.
enum PlaybackNetworkTier: Equatable, Sendable {
    case unmetered
    case metered
    case lowData

    var isMetered: Bool { self != .unmetered }

    var logLabel: String {
        switch self {
        case .unmetered: return "unmetered"
        case .metered: return "metered"
        case .lowData: return "low data mode"
        }
    }
}

/// The rule for classifying a connection's playback tier.
enum PlaybackNetworkPath {
    static func tier(usesCellular: Bool, isExpensive: Bool, isConstrained: Bool) -> PlaybackNetworkTier {
        if isConstrained { return .lowData }
        if usesCellular || isExpensive { return .metered }
        return .unmetered
    }

    static func tier(_ path: NWPath) -> PlaybackNetworkTier {
        tier(
            usesCellular: path.usesInterfaceType(.cellular),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }

    static func isMetered(usesCellular: Bool, isExpensive: Bool, isConstrained: Bool) -> Bool {
        tier(usesCellular: usesCellular, isExpensive: isExpensive, isConstrained: isConstrained).isMetered
    }

    static func isMetered(_ path: NWPath) -> Bool {
        tier(path).isMetered
    }
}

/// The device's connection, followed for the whole app so the first playback
/// already knows it. Off iPhone and iPad it never starts and always reads
/// unmetered.
final class PlaybackNetworkMonitor: @unchecked Sendable {
    static let shared = PlaybackNetworkMonitor()

    /// Removes its observer when cancelled or released.
    final class ObserverToken {
        private let onCancel: () -> Void
        private var isCancelled = false

        fileprivate init(onCancel: @escaping () -> Void) {
            self.onCancel = onCancel
        }

        func cancel() {
            guard !isCancelled else { return }
            isCancelled = true
            onCancel()
        }

        deinit { cancel() }
    }

    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    private var currentTier: PlaybackNetworkTier = .unmetered
    private var observers: [UUID: @Sendable () -> Void] = [:]

    /// Begin following the connection. Safe to call more than once.
    func start() {
        guard PlayerSettings.offersCellularQuality else { return }
        lock.withLock {
            guard monitor == nil else { return }
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                self?.update(path)
            }
            monitor.start(queue: DispatchQueue(label: "org.siloserver.silo.playback-network-path")) // i18n-ignore: queue label
            self.monitor = monitor
        }
    }

    /// The last connection tier seen.
    var tier: PlaybackNetworkTier {
        lock.withLock { currentTier }
    }

    /// Whether the last connection seen is metered (cellular, expensive, or Low Data Mode).
    var isMetered: Bool {
        tier.isMetered
    }

    /// Call `handler`, on no particular thread, each time the connection
    /// tier changes.
    func observe(_ handler: @escaping @Sendable () -> Void) -> ObserverToken {
        let id = UUID()
        lock.withLock { observers[id] = handler }
        return ObserverToken { [weak self] in
            self?.lock.withLock { _ = self?.observers.removeValue(forKey: id) }
        }
    }

    private func update(_ path: NWPath) {
        // No connection says nothing about the next one; keep the last answer
        // so going offline for a moment does not count as a change.
        guard path.status == .satisfied else { return }
        let next = PlaybackNetworkPath.tier(path)
        let handlers = lock.withLock { () -> [@Sendable () -> Void] in
            guard next != currentTier else { return [] }
            currentTier = next
            return Array(observers.values)
        }
        for handler in handlers {
            handler()
        }
    }
}

/// The connection tier, as observable state. A detail page ranks its files
/// with the connection's quality pair, so reading this in a view redraws it
/// when the connection changes, and Play then starts the file the page shows.
/// The monitor itself is not observable.
@Observable
final class PlaybackConnection {
    static let shared = PlaybackConnection()

    private(set) var tier: PlaybackNetworkTier = .unmetered
    var isMetered: Bool { tier.isMetered }
    @ObservationIgnored private var observation: PlaybackNetworkMonitor.ObserverToken?

    private init() {
        // Subscribe before the first read, so a change between them isn't lost.
        observation = PlaybackNetworkMonitor.shared.observe {
            DispatchQueue.main.async { PlaybackConnection.shared.refresh() }
        }
        tier = PlaybackNetworkMonitor.shared.tier
    }

    private func refresh() {
        tier = PlaybackNetworkMonitor.shared.tier
    }
}

/// Replans an active playback when the connection tier changes and the
/// target quality pair differs. Owned by the player.
@MainActor
final class PlaybackNetworkQualityController {
    enum ReplanOutcome {
        case issued
        /// Another replan is running; try again after the next wait.
        case busy
        /// No session this can replan (none yet, offline, Watch Party).
        case unavailable
    }

    /// The connection tier the session in progress asked for; nil while
    /// there is no session to follow.
    private(set) var sessionTier: PlaybackNetworkTier?

    /// Set while a fixed quality the viewer picked in the player applies: for
    /// the rest of that title, reloads included. Picking Auto is not such a
    /// pick; it hands quality back to the saved settings for the connection.
    private(set) var viewerPickedQuality = false

    /// How long the connection must stay changed before playback follows.
    /// Each follow is a full reload, and a phone on steady Wi-Fi can read as
    /// metered for several seconds while Wi-Fi Assist or a roam between access
    /// points puts its path on cellular. Leaving Wi-Fi for mobile data holds
    /// far longer than that.
    private let debounce: Duration
    private let currentTier: () -> PlaybackNetworkTier
    private let pair: (PlaybackNetworkTier) -> AppleQualityAxes
    private let replan: (AppleQualityAxes) -> ReplanOutcome
    private var pendingCheck: Task<Void, Never>?

    /// Whether a check is waiting out the debounce. Read by tests.
    var hasPendingCheck: Bool { pendingCheck != nil }

    init(
        debounce: Duration = .seconds(30),
        tier: @escaping () -> PlaybackNetworkTier,
        pair: @escaping (PlaybackNetworkTier) -> AppleQualityAxes,
        replan: @escaping (AppleQualityAxes) -> ReplanOutcome
    ) {
        self.debounce = debounce
        self.currentTier = tier
        self.pair = pair
        self.replan = replan
    }

    /// A session started with the pair for this connection tier.
    /// `keepsViewerPick` is true for a reload of the title the viewer picked
    /// a fixed quality for; any other title starts on the saved settings.
    func sessionStarted(tier: PlaybackNetworkTier, keepsViewerPick: Bool) {
        sessionTier = tier
        viewerPickedQuality = keepsViewerPick
    }

    /// Stop following: the player has no session, or follows a Watch Party.
    func stop() {
        pendingCheck?.cancel()
        pendingCheck = nil
        sessionTier = nil
    }

    /// The viewer picked a fixed rung: it holds over the connection's pair.
    func viewerDidPickQuality() {
        viewerPickedQuality = true
        pendingCheck?.cancel()
        pendingCheck = nil
    }

    /// The viewer picked Auto, which follows the saved settings for the
    /// connection. Later connection changes replan again; the session now
    /// uses this tier's cap.
    func viewerDidPickAuto(tier: PlaybackNetworkTier) {
        viewerPickedQuality = false
        if sessionTier != nil {
            sessionTier = tier
        }
    }

    /// The connection changed. Checks once it has held for ``debounce``; a
    /// newer change restarts the wait.
    func connectionDidChange() {
        guard sessionTier != nil, !viewerPickedQuality else {
            pendingCheck?.cancel()
            pendingCheck = nil
            return
        }
        // Without this line a report shows a reload but not what caused it,
        // and a blip that never reloaded leaves no trace at all.
        let side = currentTier().logLabel
        cmpLog("[CMP-NET] connection now \(side); quality follows if it holds for \(debounce)")
        scheduleCheck(after: debounce)
    }

    private func scheduleCheck(after wait: Duration) {
        pendingCheck?.cancel()
        pendingCheck = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.pendingCheck = nil
            self?.checkConnection()
        }
    }

    /// Replan when the connection's pair is not the one the session uses.
    /// Internal so tests can run a check without waiting out the debounce.
    func checkConnection() {
        guard !viewerPickedQuality, let current = sessionTier else { return }
        let nextTier = currentTier()
        guard nextTier != current else { return }
        let target = pair(nextTier)
        guard target != pair(current) else {
            // Both tiers ask for the same thing; nothing to reload.
            sessionTier = nextTier
            return
        }
        switch replan(target) {
        case .issued:
            sessionTier = nextTier
            switch nextTier {
            case .unmetered:
                cmpLog("[CMP-NET] connection stayed unmetered; reloading at the main quality")
            case .metered:
                cmpLog("[CMP-NET] connection stayed metered; reloading at the cellular quality")
            case .lowData:
                cmpLog("[CMP-NET] connection stayed in low data mode; reloading at the low-data ceiling")
            }
        case .busy:
            // The change has already held; only the reload in flight is in
            // the way, so ask again soon rather than waiting out the debounce.
            scheduleCheck(after: min(debounce, .seconds(4)))
        case .unavailable:
            break
        }
    }
}
