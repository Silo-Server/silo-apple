import CryptoKit
import Foundation
import Security

/// The TV's secret for one pairing session (one phone connection). Every
/// device request the TV starts in the session carries `binding`, the
/// SHA-256 of the secret, and every poll carries `secret`, so a server that
/// supports binding mints tokens only to the TV holding it. A phone that
/// compared one request's code can then trust any later request whose lookup
/// shows the same binding. The secret leaves the TV only over HTTPS to a
/// server whose capability says `session_binding`.
struct PairingSessionBinding: Equatable, Sendable {
    /// base64url without padding of the 32 random bytes (43 characters).
    let secret: String
    /// base64url without padding of SHA-256 of those bytes (43 characters).
    let binding: String

    init(secretBytes: Data) {
        secret = Self.base64url(secretBytes)
        binding = Self.base64url(Data(SHA256.hash(data: secretBytes)))
    }

    /// A fresh secret from the system's cryptographic random source, or nil
    /// if it fails; the session then sends no binding, and the phone compares
    /// each request's code instead.
    static func random() -> PairingSessionBinding? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return PairingSessionBinding(secretBytes: Data(bytes))
    }

    /// Whether a request to `serverURL` may carry the binding: the server
    /// supports it and is reached over HTTPS. Over plain HTTP the secret
    /// would be readable by the same on-path attacker binding defends
    /// against, so that request carries neither value.
    static func applies(to serverURL: String, supportsBinding: Bool) -> Bool {
        supportsBinding && URL(string: serverURL)?.scheme?.lowercased() == "https"
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// What the phone does with one target's request once its lookup and match
/// code check out (contract §C.5). The first request a person compares
/// supplies the trusted binding; later requests with that binding are
/// approved without another comparison.
enum PairingApprovalDecision: Equatable, Sendable {
    /// Ask the person to compare this request's code. On confirm,
    /// `trustOnConfirm` (the lookup's binding, when nothing is trusted yet)
    /// becomes the trusted binding.
    case compare(trustOnConfirm: String?)
    /// Same binding as a compared request: approve without asking.
    case approve
    /// Another session's binding: never approve this request.
    case refuse

    static func decide(trusted: String?, lookupBinding: String?) -> PairingApprovalDecision {
        guard let trusted else { return .compare(trustOnConfirm: lookupBinding) }
        guard let lookupBinding else { return .compare(trustOnConfirm: nil) }
        return lookupBinding == trusted ? .approve : .refuse
    }
}
