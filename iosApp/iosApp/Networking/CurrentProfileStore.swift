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
    /// next account's avatar, and doesn't clear a newer load's `inFlight`.
    private var generation = 0
    private var inFlight: Task<Void, Never>?

    private let activeProfileId: @MainActor () -> String?
    private let fetchProfiles: @MainActor () async throws -> [UserProfile]

    init(
        activeProfileId: @escaping @MainActor () -> String? = { AuthService.shared.profileId },
        fetchProfiles: @escaping @MainActor () async throws -> [UserProfile] = { try await AuthService.shared.getProfiles() }
    ) {
        self.activeProfileId = activeProfileId
        self.fetchProfiles = fetchProfiles
    }

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
            defer {
                if gen == generation { inFlight = nil }
            }
            guard let profileId = activeProfileId() else { return }
            guard let profiles = try? await fetchProfiles(),
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
