#if os(tvOS)
import Foundation

/// Persists the one `TrailerReturnRecord` written when a detail page hands a
/// remote trailer off to the YouTube app, so a cold relaunch can restore the
/// detail page the user left from (see the record's doc comment for why only
/// the jetsam case needs this).
///
/// Lifecycle is deliberately narrow:
/// - Written at handoff, just before the deep link opens.
/// - Cleared immediately if the system rejects that launch.
/// - Consumed (read + deleted) exactly once per process, at the cold-launch
///   authenticated landing in `ContentView` — whether or not the restore
///   happens, so a stale record can never linger across sittings.
/// - Cleared on any warm return to the detail page (`scenePhase` → active
///   while the page is alive): the page survived suspension, so there is
///   nothing to restore and the record must not outlive its story.
///
/// Eligibility (freshness window, server/profile identity) is decided by
/// `TrailerReturnPolicy`, which stays platform-free and unit-tested; this
/// store owns only persistence and the process-once gate.
///
/// Plain `UserDefaults.standard`: nothing outside the app process (Top
/// Shelf) reads this, so the App Group suite mirroring that
/// `TVLibraryScopeStore` does is not needed. Identity lives inside the
/// record rather than the key, so a profile switch invalidates by
/// comparison instead of by key bookkeeping.
struct TVTrailerReturnStore {
    static let shared = TVTrailerReturnStore()

    private static let recordKey = "trailerReturn.record"

    /// Process-wide gate so the cold-launch restore runs once even if the
    /// authenticated shell re-mounts (sign-out → sign-in) in the same run.
    /// A re-mount is not a cold launch, and restoring there would replay a
    /// consumed story.
    @MainActor private static var didAttemptColdLaunchRestore = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Record a handoff from the detail page for `contentId`. No-op when no
    /// profile or server is active — an anonymous record could be honored by
    /// whoever signs in next, and an empty serverId would match an equally
    /// degenerate active server at consume time instead of failing closed.
    func saveHandoff(contentId: String) {
        guard let profileId = AuthService.shared.profileId, !profileId.isEmpty,
              let serverId = ServerRegistry.shared.activeServerId, !serverId.isEmpty else {
            return
        }
        let record = TrailerReturnRecord(
            contentId: contentId,
            serverId: serverId,
            profileId: profileId,
            savedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.recordKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.recordKey)
    }

    /// The contentId to restore on this cold launch, or nil. First call per
    /// process does the work; every call deletes any stored record.
    @MainActor
    func consumeColdLaunchRestore(now: Date = Date()) -> String? {
        defer { clear() }
        guard !Self.didAttemptColdLaunchRestore else { return nil }
        Self.didAttemptColdLaunchRestore = true

        guard let data = defaults.data(forKey: Self.recordKey),
              let record = try? JSONDecoder().decode(TrailerReturnRecord.self, from: data) else {
            return nil
        }
        guard TrailerReturnPolicy.shouldRestore(
            record: record,
            now: now,
            activeServerId: ServerRegistry.shared.activeServerId,
            activeProfileId: AuthService.shared.profileId
        ) else {
            return nil
        }
        return record.contentId
    }
}
#endif
