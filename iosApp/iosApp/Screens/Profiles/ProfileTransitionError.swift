import Foundation

enum ProfileTransitionError: LocalizedError {
    case noActiveAccount
    case temporaryIdentityActive
    case identityChanged
    case accountEpochUnavailable

    var errorDescription: String? {
        switch self {
        case .noActiveAccount:
            return "Sign in before selecting a profile."
        case .temporaryIdentityActive:
            return "End remote playback before switching profiles."
        case .identityChanged:
            return "The active account changed while selecting the profile. Please try again."
        case .accountEpochUnavailable:
            return "Silo couldn't securely remember this profile. Please try again."
        }
    }
}
