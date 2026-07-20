#if os(iOS) || os(tvOS)
import Foundation

struct RecentPlaybackSessionEntry: Codable, Equatable {
    let sessionID: String
    let recordedAt: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case recordedAt = "recorded_at"
    }
}

final class RecentSessionTracker {
    static let shared = RecentSessionTracker()

    private static let defaultsKey = "diagnostics.recentPlaybackSessions.v1"
    private static let maxEntries = 10

    private let defaults: SharedDefaults
    private let lock = NSLock()

    init(defaults: SharedDefaults = .shared) {
        self.defaults = defaults
    }

    func record(sessionID: String, now: Date = Date()) {
        guard !sessionID.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        var entries = load()
        entries.removeAll { $0.sessionID == sessionID }
        entries.append(RecentPlaybackSessionEntry(
            sessionID: sessionID,
            recordedAt: DiagnosticsTimestamp.string(from: now)
        ))
        if entries.count > Self.maxEntries {
            entries = Array(entries.suffix(Self.maxEntries))
        }
        save(entries)
    }

    func recentSessionIDs(limit: Int = 10) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        return load()
            .suffix(max(0, limit))
            .reversed()
            .map(\.sessionID)
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
