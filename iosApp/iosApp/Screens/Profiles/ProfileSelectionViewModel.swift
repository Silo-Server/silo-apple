import Foundation

@Observable
@MainActor
class ProfileSelectionViewModel {
    var profiles: [UserProfile] = []
    var isLoading: Bool = false
    var isRefreshing: Bool = false
    var error: ErrorState?
    private(set) var isUsingTemporaryManagementContext: Bool = false

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
            try await auth.selectProfile(
                profileId: profile.id,
                requiresPIN: profile.hasPin
            )
            StartupContentPrefetcher.prefetchAuthenticatedContent()
            await PlayerSettings.shared.refreshFromServer()
            router.resetToHome()
        } catch {
            self.error = ErrorState(error)
        }
    }

    /// Select a profile with a PIN.
    func selectProfileWithPIN(_ profile: UserProfile, pin: String, router: AppRouter) async throws {
        try await auth.selectProfile(
            profileId: profile.id,
            pin: pin,
            requiresPIN: profile.hasPin
        )
        StartupContentPrefetcher.prefetchAuthenticatedContent()
        await PlayerSettings.shared.refreshFromServer()
        router.resetToHome()
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
        isUsingTemporaryManagementContext = true
    }

    @discardableResult
    func clearTemporaryManagementContextIfNeeded() async -> Bool {
        guard isUsingTemporaryManagementContext else { return true }
        let deactivated = await auth.deactivateProfile(preserveRememberedProfile: true)
        if deactivated {
            isUsingTemporaryManagementContext = false
        }
        return deactivated
    }
}

private enum ProfileManagementError: LocalizedError {
    case primaryProfileUnavailable

    var errorDescription: String? {
        switch self {
        case .primaryProfileUnavailable:
            return "Couldn't find the primary profile needed to manage household profiles."
        }
    }
}
