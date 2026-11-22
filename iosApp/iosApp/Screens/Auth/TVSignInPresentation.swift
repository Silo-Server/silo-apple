import Foundation

/// Copy for the TV sign-in screen, kept out of the view so the states read
/// the same everywhere and can be checked without rendering. Only platform
/// nouns differ between the Apple TV and Android TV screens.
enum TVSignInPresentation {
    /// `<host>/activate` as people type it, the same rule as Android's
    /// `DeviceCodeFormat.activateText`: the verification URL (or, when a
    /// server leaves it blank, the QR URL without its query) with no
    /// trailing slash. Only `https://` is dropped: browsers try https for a
    /// bare host, so an `http://` server keeps its scheme on screen.
    static func typedURL(_ verificationUri: String, complete verificationUriComplete: String = "") -> String {
        var text = verificationUri.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = String(verificationUriComplete.prefix { $0 != "?" }).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while text.hasSuffix("/") { text.removeLast() }
        let https = "https://"
        if text.lowercased().hasPrefix(https) { text.removeFirst(https.count) }
        return text
    }

    /// The host people can recognise for a server URL, port included so two
    /// servers on one machine stay apart. The same rule as Android's
    /// `DeviceCodeFormat.host`.
    static func host(of serverURL: String) -> String {
        var text = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        return String(text.prefix { $0 != "/" && $0 != "?" })
    }

    /// The status line under the code (a polite live region), or nil when
    /// the state speaks through its own panel.
    static func statusLine(for status: QRLoginViewModel.Status, codeWasRenewed: Bool, serverHost: String) -> String? {
        switch status {
        case .gettingCode: return AppLanguage.string(.tvSignInStatusGettingCode)
        case .waiting: return AppLanguage.string(codeWasRenewed ? LocalizedStringResource.tvSignInStatusNewCode : .tvSignInStatusWaiting)
        case .opened: return AppLanguage.string(.tvSignInStatusOpened)
        case .approved(let account):
            if let account { return AppLanguage.string(.tvSignInStatusSignedInAs(account)) }
            return AppLanguage.string(.tvSignInStatusSignedIn)
        case .couldNotFinish: return AppLanguage.string(.tvSignInStatusCouldntFinish)
        case .denied: return AppLanguage.string(.tvSignInStatusDenied)
        case .paused: return AppLanguage.string(.tvSignInStatusPaused)
        case .unreachable: return AppLanguage.string(.tvSignInStatusUnreachable(serverHost))
        case .rateLimited: return AppLanguage.string(.tvSignInStatusTooMany)
        case .updateRequired(let message): return message
        case .noDeviceSignIn: return AppLanguage.string(.tvSignInPasswordOnly)
        case .failed(let message): return message
        }
    }

    /// The paragraph under the headline. It points at the code on screen, so
    /// a declined sign-in, which withdraws the code, says what to do instead.
    static func codeLead(for status: QRLoginViewModel.Status, typedURL: String?) -> String {
        if status == .denied { return AppLanguage.string(.tvSignInDeclinedLead) }
        guard let typedURL else { return AppLanguage.string(.tvSignInAppleTvLeadNoPage) }
        return AppLanguage.string(.tvSignInAppleTvLead(typedURL))
    }

    /// What the one action button next to a state does, when it has one.
    enum StateAction: Equatable {
        case tryAgain
        case showNewCode
    }

    static func stateAction(for status: QRLoginViewModel.Status) -> StateAction? {
        switch status {
        case .couldNotFinish, .unreachable, .rateLimited, .failed: return .tryAgain
        case .denied, .paused: return .showNewCode
        default: return nil
        }
    }

    /// Whether the state's action should take focus when it appears. The
    /// ones that end the attempt do; retrying in the background does not
    /// steal focus from the password button.
    static func actionTakesFocus(_ status: QRLoginViewModel.Status) -> Bool {
        switch status {
        case .couldNotFinish, .denied, .paused, .failed: return true
        default: return false
        }
    }

    /// VoiceOver label for the QR code, with `spokenCode` (the code's
    /// characters, which the view spells out) where the code goes.
    static func qrAccessibilityLabel(typedURL: String, spokenCode: String) -> String {
        let slash = " \(AppLanguage.string(.tvSignInAppleTvSlash)) "
        return AppLanguage.string(.tvSignInAppleTvQrLabel(typedURL.replacingOccurrences(of: "/", with: slash), spokenCode))
    }

    /// The QR code's VoiceOver label up to the code, as the English reads.
    static func qrAccessibilityPrefix(typedURL: String) -> String {
        qrAccessibilityLabel(typedURL: typedURL, spokenCode: "")
    }

    /// Whether the code screen offers "Sign in with a password". Hidden when
    /// discovery says no listed provider takes a password (an OIDC-only
    /// server with local passwords off); the TV never runs browser sign-in,
    /// device sign-in covers those accounts. A directory (LDAP) provider keeps
    /// it: the password form sends no provider and the server routes by
    /// account. Unknown discovery keeps it too.
    static func offersPassword(_ options: SignInOptions?) -> Bool {
        options?.acceptsPasswords ?? true
    }

    /// Whether "Continue as …" is the TV's only way in: the server offers no
    /// device sign-in and takes no password, and discovery lists a network
    /// provider for this TV. The screen then shows no password form. Unknown
    /// discovery keeps the form.
    static func offersOnlyNetworkSignIn(_ options: SignInOptions?, deviceSignIn: Bool) -> Bool {
        guard let options, !deviceSignIn else { return false }
        return !options.acceptsPasswords && !options.networkProviders.isEmpty
    }

    /// The line under the TV's password form on a server whose discovery
    /// lists an OAuth provider: those accounts have no Silo password. Nil
    /// when it lists none. One provider is named; several read as single
    /// sign-on.
    static func phoneHint(_ options: SignInOptions?) -> String? {
        guard let providers = options?.oauthProviders, let first = providers.first else { return nil }
        guard providers.count == 1 else { return AppLanguage.string(.signInPhoneHintSso) }
        return AppLanguage.string(.tvSignInFormProviderHint(SignInOptions.providerName(for: first)))
    }
}
