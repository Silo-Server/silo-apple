import Foundation

/// Session-scoped holder for the active profile so top-bar avatars render
/// from one cached value instead of every root page refetching the profile
/// list on appearance and briefly flashing the fallback initial.
///
/// Follows the `RequestsFeatureStore` precedent: a `@MainActor` `@Observable`
/// singleton, loaded once per session and reset on profile/server switch.
/// Reset + refresh hooks live in `AuthService`/`ServerRegistry`/`ContentView`
/// next to the existing capability-store calls.
@MainActor
@Observable
final class CurrentProfileStore {
    static let shared = CurrentProfileStore()

    /// Nil until the first successful load; the avatar renders a fallback.
    private(set) var profile: UserProfile?

    /// Bumped on every `reset()` so a load that finishes after a sign-out
    /// or profile switch discards its result instead of repopulating the
    /// next account's avatar.
    private var generation = 0
    private var inFlight: Task<Void, Never>?

    /// Load the active profile if it isn't cached yet. Concurrent callers
    /// share one request. Pass `force` to refetch after a known change.
    func refresh(force: Bool = false) async {
        if !force, profile != nil { return }
        if let inFlight {
            await inFlight.value
            return
        }
        let gen = generation
        let task = Task { @MainActor in
            defer { inFlight = nil }
            guard let profileId = AuthService.shared.profileId else { return }
            guard let profiles = try? await AuthService.shared.getProfiles(),
                  gen == generation else { return }
            profile = profiles.first(where: { $0.id == profileId })
        }
        inFlight = task
        await task.value
    }

    func reset() {
        generation &+= 1
        inFlight?.cancel()
        inFlight = nil
        profile = nil
    }
}
