import Foundation

enum ProfileTransitionError: LocalizedError {
    case noActiveAccount
    case temporaryIdentityActive
    case missingPINProof
    case noActiveServer
    case identityChanged
    case accountEpochUnavailable

    var errorDescription: String? {
        switch self {
        case .noActiveAccount:
            return "Sign in before selecting a profile."
        case .temporaryIdentityActive:
            return "End remote playback before switching profiles."
        case .missingPINProof:
            return "Silo couldn't verify that profile's PIN. Please try again."
        case .noActiveServer:
            return "Choose a server before selecting a profile."
        case .identityChanged:
            return "The active account changed while selecting the profile. Please try again."
        case .accountEpochUnavailable:
            return "Silo couldn't securely remember this profile. Please try again."
        }
    }
}
