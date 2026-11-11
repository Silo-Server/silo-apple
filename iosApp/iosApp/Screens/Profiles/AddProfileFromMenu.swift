import SwiftUI

/// Presents Add Profile from the profile menu (`AppRouter.addProfileRequest`,
/// spec §4.3) over the screen the menu was opened from. Applied once at the
/// root, like the sign-out confirmation, so the iPhone and iPad panel, the
/// Mac menu and the Apple TV menu share it. Closing it without creating a
/// profile leaves that screen as it was.
struct AddProfileFromMenuModifier: ViewModifier {
    let router: AppRouter

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.fullScreenCover(item: request) { request in
            AddProfileFromMenuView(router: router, request: request)
        }
        #else
        content.sheet(item: request) { request in
            AddProfileFromMenuView(router: router, request: request)
                .presentationDetents([.large])
        }
        #endif
    }

    private var request: Binding<AddProfileRequest?> {
        Binding(
            get: { router.addProfileRequest },
            set: { router.addProfileRequest = $0 }
        )
    }
}

/// The steps the picker's Add takes: the primary profile's PIN when it has
/// one, then the new-profile form.
private struct AddProfileFromMenuView: View {
    let router: AppRouter
    let request: AddProfileRequest
    @State private var isUnlocked: Bool
    @State private var wrongPINCount = 0
    @State private var pinError: String?
    @State private var isVerifyingPIN = false
    @Environment(\.dismiss) private var dismiss

    init(router: AppRouter, request: AddProfileRequest) {
        self.router = router
        self.request = request
        _isUnlocked = State(initialValue: !request.primary.hasPin)
    }

    var body: some View {
        if isUnlocked {
            CreateProfileView { router.finishAddProfile() }
        } else {
            PINEntryView(
                profile: request.primary,
                errorMessage: pinError,
                errorCount: wrongPINCount,
                isVerifying: isVerifyingPIN,
                onCancel: { dismiss() }
            ) { pin in
                verify(pin)
            }
        }
    }

    /// The prompt stays open while the server checks the PIN and after a
    /// rejected one; anything else closes it and reports the error. The
    /// check can outlive the prompt (the cover can be dismissed while the
    /// server answers), so its result applies only while this request is
    /// still the one on screen.
    private func verify(_ pin: String) {
        isVerifyingPIN = true
        pinError = nil
        Task {
            defer { isVerifyingPIN = false }
            do {
                // The open profile stays open. The proof the server returns
                // for this PIN replaces the stored one, so the create that
                // follows is authorized by it.
                try await AuthService.shared.renewOpenProfileProof(profileId: request.primary.id, pin: pin)
                guard router.isPresenting(request) else { return }
                MarqueeHaptics.success()
                isUnlocked = true
            } catch {
                guard router.isPresenting(request) else { return }
                if case ProfileTransitionError.incorrectPIN = error {
                    wrongPINCount += 1
                    pinError = AppLanguage.string(.pinWrong)
                } else if case ProfileTransitionError.pinLockedOut = error {
                    // Clears the entry; the lockout is not another wrong PIN.
                    wrongPINCount += 1
                    pinError = error.localizedDescription
                } else if case ProfileTransitionError.identityChanged = error {
                    // The profile was closed or replaced while the PIN was
                    // checked: the screen that replaced it is already up.
                    router.closeAddProfile(request)
                } else {
                    router.closeAddProfile(request, reporting: error.localizedDescription)
                }
            }
        }
    }
}
