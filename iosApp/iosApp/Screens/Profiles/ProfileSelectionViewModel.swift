import Foundation

@Observable
@MainActor
class ProfileSelectionViewModel {
    var profiles: [UserProfile] = []
    var isLoading: Bool = false
    var isRefreshing: Bool = false
    var error: ErrorState?
    private(set) var isUsingTemporaryManagementContext: Bool = false
    private(set) var isClearingTemporaryManagementContext: Bool = false
    private var temporaryManagementProfileID: String?
    private var temporaryManagementCleanupTask: Task<Bool, Never>?

    private let auth = AuthService.shared

    init() {
        if let cached: [UserProfile] = ResponseCache.shared.get(CacheKey.profiles) {
            profiles = cached
        }
    }

    /// Fetch the user's profiles from the server.
    func loadProfiles() async {
        if profiles.isEmpty {
            isLoading = true
        } else {
            isRefreshing = true
        }
        error = nil
        defer {
            isLoading = false
            isRefreshing = false
        }

        do {
            let fresh = try await StartupContentPrefetcher.fetchProfiles()
            profiles = fresh
        } catch {
            if profiles.isEmpty {
                self.error = ErrorState(error)
            }
        }
    }

    var primaryProfile: UserProfile? {
        profiles.first(where: \.isPrimary)
            ?? (profiles.count == 1 ? profiles.first : nil)
    }

    /// Select a profile that has no PIN and navigate to home.
    func selectProfile(_ profile: UserProfile, router: AppRouter) async {
        do {
            guard await clearTemporaryManagementContextIfNeeded() else {
                throw ProfileManagementError.temporaryContextCleanupFailed
            }
            try await auth.selectProfile(
                profileId: profile.id,
                requiresPIN: profile.hasPin
            )
            StartupContentPrefetcher.prefetchAuthenticatedContent()
            // Change screens before the settings request suspends. The refresh
            // applies this profile's cached playback quality synchronously,
            // then updates it from the server while Home is already visible.
            router.resetToHome()
            await PlayerSettings.shared.refreshFromServer()
        } catch {
            self.error = ErrorState(error)
        }
    }

    /// Select a profile with a PIN.
    func selectProfileWithPIN(_ profile: UserProfile, pin: String, router: AppRouter) async throws {
        guard await clearTemporaryManagementContextIfNeeded() else {
            throw ProfileManagementError.temporaryContextCleanupFailed
        }
        try await auth.selectProfile(
            profileId: profile.id,
            pin: pin,
            requiresPIN: profile.hasPin
        )
        StartupContentPrefetcher.prefetchAuthenticatedContent()
        router.resetToHome()
        await PlayerSettings.shared.refreshFromServer()
    }

    /// The picker itself has no active profile, but the server requires the
    /// primary household profile (or admin role) for profile management.
    /// Borrow that context just long enough to create a profile, then clear it.
    func prepareForProfileManagement() async throws {
        guard let primaryProfile else {
            throw ProfileManagementError.primaryProfileUnavailable
        }
        try await auth.selectProfile(
            profileId: primaryProfile.id,
            requiresPIN: primaryProfile.hasPin,
            rememberSelection: false
        )
        temporaryManagementProfileID = primaryProfile.id
        isUsingTemporaryManagementContext = true
    }

    func prepareForProfileManagement(pin: String) async throws {
        guard let primaryProfile else {
            throw ProfileManagementError.primaryProfileUnavailable
        }
        try await auth.selectProfile(
            profileId: primaryProfile.id,
            pin: pin,
            requiresPIN: primaryProfile.hasPin,
            rememberSelection: false
        )
        temporaryManagementProfileID = primaryProfile.id
        isUsingTemporaryManagementContext = true
    }

    @discardableResult
    func clearTemporaryManagementContextIfNeeded() async -> Bool {
        if let temporaryManagementCleanupTask {
            return await temporaryManagementCleanupTask.value
        }
        guard isUsingTemporaryManagementContext,
              let temporaryManagementProfileID else { return true }
        let cleanupTask = Task { @MainActor in
            await auth.deactivateProfile(
                preserveRememberedProfile: true,
                expectedProfileID: temporaryManagementProfileID
            )
        }
        isClearingTemporaryManagementContext = true
        temporaryManagementCleanupTask = cleanupTask
        let deactivated = await cleanupTask.value
        temporaryManagementCleanupTask = nil
        isClearingTemporaryManagementContext = false
        let temporaryContextIsGone = auth.profileId != temporaryManagementProfileID
        if deactivated || temporaryContextIsGone {
            isUsingTemporaryManagementContext = false
            self.temporaryManagementProfileID = nil
        }
        return deactivated || temporaryContextIsGone
    }
}

private enum ProfileManagementError: LocalizedError {
    case primaryProfileUnavailable
    case temporaryContextCleanupFailed

    var errorDescription: String? {
        switch self {
        case .primaryProfileUnavailable:
            return "Couldn't find the primary profile needed to manage household profiles."
        case .temporaryContextCleanupFailed:
            return "Silo couldn't finish creating the profile. Please try selecting it again."
        }
    }
}
