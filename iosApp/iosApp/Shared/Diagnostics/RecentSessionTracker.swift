#if os(iOS) || os(tvOS)
import Foundation

struct RecentPlaybackSessionEntry: Codable, Equatable {
    let sessionID: String
    let recordedAt: String
    /// The diagnostics binding (server instance + account) active when the
    /// session was recorded. Playback session IDs are server-scoped, so a
    /// report may only surface sessions captured under its own binding.
    /// `nil` for legacy entries or sessions recorded before the binding was
    /// known; those never match a report binding and are excluded.
    let binding: DiagnosticsBinding?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case recordedAt = "recorded_at"
        case binding
    }
}

final class RecentSessionTracker {
    static let shared = RecentSessionTracker()

    private static let defaultsKey = "diagnostics.recentPlaybackSessions.v1"
    private static let maxEntries = 10
    static let retentionInterval = PendingReportStore.expiryInterval

    private let defaults: SharedDefaults
    private let lock = NSLock()

    init(defaults: SharedDefaults = .shared) {
        self.defaults = defaults
    }

    func record(
        sessionID: String,
        binding: DiagnosticsBinding? = DiagnosticsCoordinator.currentDiagnosticsBinding,
        now: Date = Date()
    ) {
        guard !sessionID.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        var entries = load()
        entries.removeAll { $0.sessionID == sessionID }
        entries.append(RecentPlaybackSessionEntry(
            sessionID: sessionID,
            recordedAt: DiagnosticsTimestamp.string(from: now),
            binding: binding
        ))
        if entries.count > Self.maxEntries {
            entries = Array(entries.suffix(Self.maxEntries))
        }
        save(entries)
    }

    /// Recent session IDs recorded under `binding`, newest first. Sessions
    /// from other server/accounts are excluded so they cannot leak into a
    /// report bound elsewhere.
    func recentSessionIDs(
        for binding: DiagnosticsBinding,
        limit: Int = 10,
        now: Date = Date()
    ) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        let entries = load()
        let cutoff = now.addingTimeInterval(-Self.retentionInterval)
        let retained = entries.filter { entry in
            guard let recordedAt = DiagnosticsDates.date(from: entry.recordedAt) else {
                return false
            }
            return recordedAt >= cutoff
        }
        if retained != entries {
            save(retained)
        }

        return retained
            .filter { $0.binding == binding }
            .suffix(max(0, limit))
            .reversed()
            .map(\.sessionID)
    }

    func purge(binding: DiagnosticsBinding) {
        lock.lock()
        defer { lock.unlock() }

        var entries = load()
        entries.removeAll { $0.binding == binding }
        save(entries)
    }

    func resetForTests() {
        lock.lock()
        defer { lock.unlock() }

        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private func load() -> [RecentPlaybackSessionEntry] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let entries = try? DiagnosticsJSONCoding.makeDecoder().decode(
                [RecentPlaybackSessionEntry].self,
                from: data
              ) else {
            return []
        }
        return entries
    }

    private func save(_ entries: [RecentPlaybackSessionEntry]) {
        guard let data = try? DiagnosticsJSONCoding.makeEncoder().encode(entries) else {
            return
        }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
#endif
