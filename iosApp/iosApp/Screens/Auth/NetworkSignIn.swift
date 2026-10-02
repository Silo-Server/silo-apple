import Foundation

/// Sign-in through a network identity provider (`mode: network`, such as the
/// Tailscale plugin). The provider's network already knows who owns the
/// device behind a request, so "Continue as …" signs that person in with no
/// password and no browser (silo-server `docs/architecture/external-sign-in.md`,
/// "Network identity").
///
/// Discovery lists a network provider only to a request that came through
/// that provider's network: the button shows only while the saved server
/// address is the provider's one (for Tailscale, the server's tailnet name)
/// and this device is on that network. The sign-in posts `{}` to the
/// provider's `network_sign_in_path` on the saved base URL, and the token
/// pair it answers is installed like a password sign-in's.
enum NetworkSignIn {
    /// The server-relative part of every network sign-in: what follows the
    /// server's base URL. The id has the contract's shape (`^[1-9][0-9]*$`).
    private static let apiPathSuffix = try! NSRegularExpression(pattern: "/api/v2/auth/network/[1-9][0-9]*/sign-in$")

    /// The provider's sign-in as an API path below the saved base: the
    /// `/api/v2/auth/network/<id>/sign-in` its `network_sign_in_path` ends
    /// with. Anything before that (another address's path prefix) is dropped,
    /// so the request always goes to the saved base, as a native start does.
    /// Nil for a provider of another mode and for a path of any other shape,
    /// which offer no network sign-in.
    static func apiPath(of provider: APIv2AuthProvider) -> String? {
        guard provider.isNetwork,
              let path = provider.networkSignInPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/"), !path.hasPrefix("//"), let components = URLComponents(string: path),
              components.scheme == nil, components.host == nil,
              components.query == nil, components.fragment == nil else { return nil }
        let encoded = components.percentEncodedPath
        guard let match = apiPathSuffix.firstMatch(in: encoded, range: NSRange(encoded.startIndex..., in: encoded)),
              let suffix = Range(match.range, in: encoded) else { return nil }
        return String(encoded[suffix])
    }

    /// Whether `path` is a network sign-in: public (no bearer, no profile)
    /// and single dispatch, like `login`. Matched as a suffix, like the other
    /// public paths, because the request's URL path carries the saved base's
    /// own path prefix.
    static func isAPIPath(_ path: String) -> Bool {
        apiPathSuffix.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    // MARK: Copy

    /// "Continue as <name>" with the device owner's name from discovery,
    /// else "Continue with <provider>".
    static func buttonTitle(for provider: APIv2AuthProvider) -> String {
        if let name = provider.networkIdentity?.name { return "Continue as \(name)" }
        return "Continue with \(SignInOptions.providerName(for: provider))"
    }

    /// The line under a "Continue as" button naming the provider ("via
    /// Tailscale"). Nil when the button already names it.
    static func viaLine(for provider: APIv2AuthProvider) -> String? {
        guard provider.networkIdentity?.name != nil else { return nil }
        return "via \(SignInOptions.providerName(for: provider))"
    }

    /// What VoiceOver reads for the button: its title and the provider.
    static func accessibilityLabel(for provider: APIv2AuthProvider) -> String {
        [buttonTitle(for: provider), viaLine(for: provider)].compactMap { $0 }.joined(separator: ", ")
    }

    /// The provider does not vouch for this device (unknown, tagged, or left
    /// out by its policy).
    private static func deviceRefusedText(_ provider: APIv2AuthProvider) -> String {
        "\(SignInOptions.providerName(for: provider)) doesn't allow this device to sign in to this server."
    }

    /// Copy for a failed network sign-in; nil when it was canceled. The
    /// server's refusals read as sentences, never codes; the ones every
    /// external sign-in shares keep their usual copy.
    static func signInMessage(for error: Error, provider: APIv2AuthProvider) -> String? {
        if error is CancellationError { return nil }
        if let requirement = UpdateRequirement(error) { return requirement.message }
        let name = SignInOptions.providerName(for: provider)
        let status: Int
        switch error {
        case APIv2Error.problem(let problem):
            switch problem.identifier {
            case "network_identity_required":
                // The saved address is another one (the LAN address, say), or
                // this device is not on the provider's network right now.
                return "Open this server at its \(name) address to sign in this way."
            case "not_permitted":
                return deviceRefusedText(provider)
            case "email_in_use":
                return "An account with your email already exists. Sign in with your password, then connect "
                    + "\(name) in Settings → Sign-in."
            case "permission_denied":
                // The account the person resolved to is disabled.
                return ExternalSignInError.reasonText("account_disabled")
            case "account_required", "identity_linked_elsewhere", "provider_unavailable":
                return ExternalSignInError.reasonText(problem.identifier)
            default:
                status = problem.status
            }
        case APIv2Error.httpStatus(let code):
            status = code
        default:
            return LoginViewModel.message(for: error)
        }
        switch status {
        case 404: return AccountSignInModel.providerGoneMessage
        case 429: return LoginViewModel.rateLimitedMessage
        case 503: return ExternalSignInError.reasonText("provider_unavailable")
        default: return ExternalSignInError.reasonText("login_failed")
        }
    }

    /// Copy for a failed network link in Settings → Sign-in. The refusals
    /// about this device name the provider; the rest read as any other link's.
    static func linkMessage(for error: Error, provider: APIv2AuthProvider) -> String {
        if case APIv2Error.problem(let problem) = error {
            switch problem.identifier {
            case "network_identity_required":
                return "Open this server at its \(SignInOptions.providerName(for: provider)) address to connect it."
            case "not_permitted":
                return deviceRefusedText(provider)
            default:
                break
            }
        }
        return AccountSignInModel.message(for: error, action: .connect)
    }
}
