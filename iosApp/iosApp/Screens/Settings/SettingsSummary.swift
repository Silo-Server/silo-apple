import Foundation

/// Account, subtitle-language and version text shown by the iOS settings
/// overview (`IOSSettingsOverview`) and the macOS settings list
/// (`SettingsView`).
struct SettingsSummary: Equatable {
    let profileName: String?
    let username: String?
    let serverURL: String

    init(profileName: String?, username: String?, serverURL: String) {
        self.profileName = profileName
        self.username = username
        self.serverURL = serverURL
    }

    init(viewModel: SettingsViewModel) {
        self.init(
            profileName: viewModel.activeProfile?.name,
            username: viewModel.userInfo?.username,
            serverURL: viewModel.serverUrl
        )
    }

    /// The active profile's name, else the account username, else a prompt.
    var displayName: String {
        if let name = profileName, !name.isEmpty {
            return name
        }
        if let username, !username.isEmpty {
            return username
        }
        return "Switch Profile"
    }

    /// "user · host", leaving out the username when it already is the
    /// display name.
    var subtitleLine: String {
        let host = serverHost
        switch (username, host) {
        case let (user?, host?) where !user.isEmpty && user != displayName:
            return "\(user) · \(host)"
        case let (_, host?):
            return host
        case let (user?, _) where !user.isEmpty && user != displayName:
            return user
        default:
            return "Tap to switch profile"
        }
    }

    /// The server URL's host, or the raw string when it doesn't parse to one.
    var serverHost: String? {
        guard let url = URL(string: serverURL), let host = url.host else {
            return serverURL.isEmpty ? nil : serverURL
        }
        return host
    }

    static func subtitleLanguageName(_ tag: String) -> String {
        if tag == PlaybackPrefSentinel.none || tag.isEmpty { return "None" }
        return PlaybackLanguageOption.label(forCode: tag)
    }

    /// "x.y (build)", or just "x.y" when the build is missing, empty or equal
    /// to the marketing version.
    static func versionString(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        guard let build = infoDictionary?["CFBundleVersion"] as? String,
              !build.isEmpty,
              build != version else {
            return version
        }
        return "\(version) (\(build))"
    }
}
