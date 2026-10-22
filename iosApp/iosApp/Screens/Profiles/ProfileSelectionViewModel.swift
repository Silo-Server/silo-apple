import Foundation

@Observable
@MainActor
class ProfileSelectionViewModel {
    var profiles: [UserProfile] = []
    var isLoading: Bool = false
    var isRefreshing: Bool = false
    var error: ErrorState?
    /// The account holds a temporary password: the server refuses profiles
    /// until it is replaced, so the picker hands over to the password change.
    private(set) var requiresPasswordChange = false
    private(set) var isUsingTemporaryManagementContext: Bool = false
    private(set) var isClearingTemporaryManagementContext: Bool = false
    private var temporaryManagementProfileID: String?
    private var temporaryManagementCleanupTask: Task<Bool, Never>?

    /// The profile just picked on a fresh Apple TV, while the TV asks
    /// whether to open it automatically from now on. Home waits for the answer.
    var rememberOffer: UserProfile?

    private let auth = AuthService.shared
    private let launchPreferences = ProfileLaunchPreferences.shared

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
            if PasswordChangeModel.isRequired(by: error) {
                requiresPasswordChange = true
            } else if profiles.isEmpty {
                self.error = ErrorState(error)
            }
        }
    }

    /// The signed-in account's username, shown under the title. Nil until
    /// `loadAccount` finishes, or when the read fails.
    private(set) var accountName: String?

    func loadAccount() async {
        accountName = try? await SiloAPI.shared.currentUser().username
    }

    var primaryProfile: UserProfile? {
        profiles.first(where: \.isPrimary)
            ?? (profiles.count == 1 ? profiles.first : nil)
    }

    /// Select a profile that has no PIN and navigate to home.
    func selectProfile(_ profile: UserProfile, router: AppRouter) async {
        do {
            try await select(profile, pin: nil, router: router)
        } catch {
            if PasswordChangeModel.isRequired(by: error) {
                requiresPasswordChange = true
            } else {
                self.error = ErrorState(error)
            }
        }
    }

    /// Select a profile with a PIN. Throws so the PIN prompt can handle a
    /// wrong PIN itself.
    func selectProfileWithPIN(_ profile: UserProfile, pin: String, router: AppRouter) async throws {
        try await select(profile, pin: pin, router: router)
    }

    private func select(_ profile: UserProfile, pin: String?, router: AppRouter) async throws {
        guard await clearTemporaryManagementContextIfNeeded() else {
            throw ProfileManagementError.temporaryContextCleanupFailed
        }
        try await auth.selectProfile(
            profileId: profile.id,
            pin: pin,
            requiresPIN: profile.hasPin
        )
        #if os(iOS)
        // Identity is committed at this point, so reveal Home immediately.
        // Optional settings and content warm-up must never hold the profile
        // card on screen behind a slow server request.
        router.resetToHome()
        StartupContentPrefetcher.prefetchAuthenticatedContent()
        Task { await PlayerSettings.shared.refreshFromServer() }
        #else
        StartupContentPrefetcher.prefetchAuthenticatedContent()
        await PlayerSettings.shared.refreshFromServer()
        #if os(tvOS)
        if launchPreferences.isRememberOfferPending {
            rememberOffer = profile
            return
        }
        #endif
        router.resetToHome()
        #endif
    }

    /// Records the answer to the TV's offer and continues to Home. If the
    /// answer cannot be saved, the offer stays open so it can be answered
    /// again.
    func answerRememberOffer(remember: Bool, router: AppRouter) {
        guard launchPreferences.answerRememberOffer(remember: remember) else { return }
        rememberOffer = nil
        router.resetToHome()
    }

    /// The picker itself has no active profile, but the server requires the
    /// primary household profile (or admin role) for profile management.
    /// Borrow that context just long enough to create a profile, then clear it.
    func prepareForProfileManagement(pin: String? = nil) async throws {
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
        let cleanupTask = Task {
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
