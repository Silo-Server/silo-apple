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

/// The rule for when a connection counts as metered.
enum PlaybackNetworkPath {
    static func isMetered(usesCellular: Bool, isExpensive: Bool, isConstrained: Bool) -> Bool {
        usesCellular || isExpensive || isConstrained
    }

    static func isMetered(_ path: NWPath) -> Bool {
        isMetered(
            usesCellular: path.usesInterfaceType(.cellular),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
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
    private var metered = false
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
            monitor.start(queue: DispatchQueue(label: "org.siloserver.silo.playback-network-path"))
            self.monitor = monitor
        }
    }

    /// Whether the last connection seen is metered.
    var isMetered: Bool {
        lock.withLock { metered }
    }

    /// Call `handler`, on no particular thread, each time the connection
    /// changes between metered and unmetered.
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
        let next = PlaybackNetworkPath.isMetered(path)
        let handlers = lock.withLock { () -> [@Sendable () -> Void] in
            guard next != metered else { return [] }
            metered = next
            return Array(observers.values)
        }
        for handler in handlers {
            handler()
        }
    }
}

/// Replans an active playback when the connection moves between metered and
/// unmetered and the two quality pairs differ. Owned by the player.
@MainActor
final class PlaybackNetworkQualityController {
    enum ReplanOutcome {
        case issued
        /// Another replan is running; try again after the next wait.
        case busy
        /// No session this can replan (none yet, offline, Watch Party).
        case unavailable
    }

    /// Whether the session in progress asked for the metered pair; nil while
    /// there is no session to follow.
    private(set) var sessionUsesMeteredPair: Bool?

    /// Set while a fixed quality the viewer picked in the player applies: for
    /// the rest of that title, reloads included. Picking Auto is not such a
    /// pick; it hands quality back to the saved settings for the connection.
    private(set) var viewerPickedQuality = false

    /// How long the connection must stay changed before playback follows, so
    /// a brief flap does not reload the stream twice.
    private let debounce: Duration
    private let isMetered: () -> Bool
    private let pair: (_ metered: Bool) -> AppleQualityAxes
    private let replan: (AppleQualityAxes) -> ReplanOutcome
    private var pendingCheck: Task<Void, Never>?

    /// Whether a check is waiting out the debounce. Read by tests.
    var hasPendingCheck: Bool { pendingCheck != nil }

    init(
        debounce: Duration = .seconds(4),
        isMetered: @escaping () -> Bool,
        pair: @escaping (_ metered: Bool) -> AppleQualityAxes,
        replan: @escaping (AppleQualityAxes) -> ReplanOutcome
    ) {
        self.debounce = debounce
        self.isMetered = isMetered
        self.pair = pair
        self.replan = replan
    }

    /// A session started with the pair for this side of the connection.
    /// `keepsViewerPick` is true for a reload of the title the viewer picked
    /// a fixed quality for; any other title starts on the saved settings.
    func sessionStarted(onMeteredNetwork: Bool, keepsViewerPick: Bool) {
        sessionUsesMeteredPair = onMeteredNetwork
        viewerPickedQuality = keepsViewerPick
    }

    /// Stop following: the player has no session, or follows a Watch Party.
    func stop() {
        pendingCheck?.cancel()
        pendingCheck = nil
        sessionUsesMeteredPair = nil
    }

    /// The viewer picked a fixed rung: it holds over the connection's pair.
    func viewerDidPickQuality() {
        viewerPickedQuality = true
        pendingCheck?.cancel()
        pendingCheck = nil
    }

    /// The viewer picked Auto, which follows the saved settings for the
    /// connection. Later connection changes replan again; the session now
    /// uses this side's cap.
    func viewerDidPickAuto(onMeteredNetwork: Bool) {
        viewerPickedQuality = false
        if sessionUsesMeteredPair != nil {
            sessionUsesMeteredPair = onMeteredNetwork
        }
    }

    /// The connection changed. Checks once it has held for ``debounce``; a
    /// newer change restarts the wait.
    func connectionDidChange() {
        pendingCheck?.cancel()
        guard sessionUsesMeteredPair != nil, !viewerPickedQuality else {
            pendingCheck = nil
            return
        }
        let debounce = debounce
        pendingCheck = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.pendingCheck = nil
            self?.checkConnection()
        }
    }

    /// Replan when the connection's pair is not the one the session uses.
    /// Internal so tests can run a check without waiting out the debounce.
    func checkConnection() {
        guard !viewerPickedQuality, let current = sessionUsesMeteredPair else { return }
        let metered = isMetered()
        guard metered != current else { return }
        let target = pair(metered)
        guard target != pair(current) else {
            // Both sides ask for the same thing; nothing to reload.
            sessionUsesMeteredPair = metered
            return
        }
        switch replan(target) {
        case .issued:
            sessionUsesMeteredPair = metered
        case .busy:
            connectionDidChange()
        case .unavailable:
            break
        }
    }
}
