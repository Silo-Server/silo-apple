import Foundation

enum ProfileTransitionError: LocalizedError {
    case noActiveAccount
    case temporaryIdentityActive
    case missingPINProof
    /// The server checked the PIN and it did not match.
    case incorrectPIN
    /// The server locked the profile after repeated wrong PINs (429), for
    /// `retryAfter` seconds when it said how long.
    case pinLockedOut(retryAfter: TimeInterval?)
    case noActiveServer
    case identityChanged
    case accountEpochUnavailable

    var errorDescription: String? {
        switch self {
        case .noActiveAccount:
            return AppLanguage.string(.profilesErrorSignInFirst)
        case .temporaryIdentityActive:
            return AppLanguage.string(.profilesErrorRemotePlayback)
        case .missingPINProof:
            return AppLanguage.string(.pinErrorMissingProof)
        case .incorrectPIN:
            return AppLanguage.string(.pinErrorIncorrectTryAgain)
        case .pinLockedOut(let retryAfter):
            // The header is server input: "inf" and "1e300" parse as numbers
            // and would trap in the Int conversion. A day is far past any
            // real lockout.
            guard let retryAfter, retryAfter > 0, retryAfter <= 86_400 else {
                return AppLanguage.string(.pinLockoutLater)
            }
            let minutes = Int((retryAfter / 60).rounded(.up))
            return AppLanguage.string(.pinLockoutMinutes(count: minutes, LocaleFormat.integer(minutes)))
        case .noActiveServer:
            return AppLanguage.string(.profilesErrorChooseServer)
        case .identityChanged:
            return AppLanguage.string(.profilesErrorAccountChanged)
        case .accountEpochUnavailable:
            return AppLanguage.string(.profilesErrorRememberFailed)
        }
    }
}
