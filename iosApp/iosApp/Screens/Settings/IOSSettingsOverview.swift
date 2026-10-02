#if os(iOS)
import SwiftUI

/// Searchable iOS Settings overview in the system Settings idiom: an
/// inset-grouped list of one-line rows with graphite icon tiles. Search
/// still matches each row's longer description, which VoiceOver reads as
/// the row's hint.
struct IOSSettingsOverview: View {
    @Bindable var viewModel: SettingsViewModel
    @Bindable var diagnosticsModel: DiagnosticsViewModel
    @Bindable var uiCustomization: UICustomizationPreferences
    @Binding var showSignOutConfirm: Bool

    @Environment(AppRouter.self) private var router
    @State private var navPrefs = AppNavPreferences.shared
    @State private var launchPreferences = ProfileLaunchPreferences.shared
    @State private var experimental = ExperimentalFeatures.shared
    @State private var searchText = ""
    @State private var showsSignInTV = false
    @State private var accountSignIn = AccountSignInModel.live()

    var body: some View {
        List {
            Section {
                SettingsAccountCard(
                    avatar: viewModel.activeProfile?.avatarEmoji,
                    avatarImageUrl: viewModel.activeProfile?.avatarImageUrl,
                    name: displayName,
                    subtitle: subtitleLine,
                    isAdministrator: viewModel.userInfo?.isAdmin == true,
                    action: switchProfile
                )
            }

            SettingsSearchField(text: $searchText)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            if hasSearchResults {
                preferencesSection
                playbackSection

                if diagnosticsModel.shouldShowSettings && matchesDiagnostics {
                    diagnosticsSection
                }

                if matchesAccountSignIn {
                    accountSignInSection
                }

                if matchesConnectionSection {
                    connectionSection
                }

                if matchesExperimentalSection {
                    experimentalSection
                }

                if matchesAboutSection {
                    aboutSection
                }

                if matchesSignOut {
                    signOutSection
                }
            } else {
                ContentUnavailableView.search
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                    .listRowBackground(Color.clear)
            }
        }
        .siloGroupedListStyle()
        .siloScrollContentBackgroundHidden()
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(Color.siloBackground.ignoresSafeArea())
        .navigationTitle("Settings")
        .siloNavigationTitleDisplayMode(.large)
        .siloToolbarColorSchemeDark()
        .onAppear(perform: navPrefs.refresh)
        .task { await accountSignIn.load() }
        .sheet(isPresented: $showsSignInTV) {
            SignInTVView(onSwitchAccount: { server, link, choosingAccount in
                showsSignInTV = false
                router.switchAccount(forTVApproval: link, on: server, choosingAccount: choosingAccount)
            }, onClose: { showsSignInTV = false })
        }
    }

    @ViewBuilder
    private var preferencesSection: some View {
        if matchesGeneral || matchesInterface {
            Section("Preferences") {
                if matchesGeneral {
                    NavigationLink {
                        GeneralSettingsView()
                    } label: {
                        SettingsOverviewRow(
                            title: "General",
                            subtitle: "Profile selection and app startup",
                            systemImage: "gearshape.fill",
                            value: launchPreferences.behavior.title
                        )
                    }
                }

                if matchesInterface {
                    NavigationLink {
                        InterfaceCustomizationView()
                    } label: {
                        SettingsOverviewRow(
                            title: "Interface",
                            subtitle: "Navigation, cards, and poster presentation",
                            systemImage: "rectangle.3.group.fill",
                            value: uiCustomization.cardPresentation.preset?.title ?? "Custom"
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var playbackSection: some View {
        if matchesPlaybackSection {
            Section("Playback") {
                if matchesPlayback {
                    NavigationLink {
                        PlaybackSettingsView(viewModel: viewModel)
                    } label: {
                        SettingsOverviewRow(
                            title: "Playback",
                            subtitle: "Quality, language, and episode behavior",
                            systemImage: "play.fill",
                            value: viewModel.preferredQualityLabel
                        )
                    }
                }

                if matchesSubtitles {
                    NavigationLink {
                        SubtitleSettingsView(viewModel: viewModel)
                    } label: {
                        SettingsOverviewRow(
                            title: "Subtitles",
                            subtitle: "Language, behavior, and appearance",
                            systemImage: "captions.bubble.fill",
                            value: subtitleLanguageName(viewModel.prefs.subtitleLanguage)
                        )
                    }
                }

                if matchesDownloads {
                    NavigationLink {
                        DownloadsSettingsView()
                    } label: {
                        SettingsOverviewRow(
                            title: "Downloads",
                            subtitle: "Quality, cleanup, and storage",
                            systemImage: "arrow.down.circle.fill"
                        )
                    }
                }
            }
        }
    }

    private var diagnosticsSection: some View {
        Section("Support") {
            NavigationLink {
                DiagnosticsSettingsView(
                    model: diagnosticsModel,
                    profile: viewModel.activeProfile
                )
            } label: {
                SettingsOverviewRow(
                    title: "Diagnostics",
                    subtitle: "Capture, review, and send support reports",
                    systemImage: "stethoscope",
                    value: diagnosticsModel.featureState.title
                )
            }
        }
    }

    /// Shown only when the server has an external sign-in provider or the
    /// account already has a provider identity.
    private var accountSignInSection: some View {
        Section("Account") {
            NavigationLink {
                AccountSignInView(model: accountSignIn)
            } label: {
                SettingsOverviewRow(
                    title: "Sign-in",
                    subtitle: "Connect or disconnect your sign-in provider",
                    systemImage: "person.badge.key.fill",
                    value: accountSignIn.identities.first?.providerName
                )
            }
            .accessibilityIdentifier("settings.accountSignIn")
        }
    }

    private var matchesAccountSignIn: Bool {
        accountSignIn.showsEntry && matches("sign-in", "sign in", "account", "provider", "sso", "single sign-on", "connect")
    }

    private var connectionSection: some View {
        Section("Connection") {
            Button {
                router.navigate(to: .serverList)
            } label: {
                SettingsOverviewRow(
                    title: "Server",
                    subtitle: "Manage this device's Silo connection",
                    systemImage: "server.rack",
                    value: viewModel.serverDisplayName,
                    showsChevron: true
                )
            }
            if matchesSignInTV {
                Button {
                    showsSignInTV = true
                } label: {
                    SettingsOverviewRow(
                        title: "Sign in a TV",
                        subtitle: "Approve a TV's sign-in code with this account",
                        systemImage: "tv",
                        showsChevron: true
                    )
                }
            }
        }
    }

    private var matchesSignInTV: Bool {
        matches("sign in a tv", "tv", "apple tv", "android tv", "code", "device")
    }

    private var aboutSection: some View {
        Section("About") {
            SettingsOverviewRow(
                title: "Version",
                subtitle: "Installed Silo app version",
                systemImage: "info.circle.fill",
                value: versionString
            )

            Link(destination: SiloLegalLinks.privacyPolicy) {
                SettingsOverviewRow(
                    title: "Privacy Policy",
                    subtitle: "Learn how Silo handles your information",
                    systemImage: "hand.raised.fill",
                    showsChevron: true
                )
            }

            NavigationLink {
                OpenSourceAcknowledgementsView()
            } label: {
                SettingsOverviewRow(
                    title: "Open Source Licenses",
                    subtitle: "Acknowledgements, licenses, and exact source revisions",
                    systemImage: "curlybraces"
                )
            }
        }
    }

    private var experimentalSection: some View {
        // A query naming the section shows every row; otherwise each row
        // appears only for its own terms.
        Section("Experimental") {
            if matchesExperimentalName || matchesAudiobooks {
                SettingsOverviewToggleRow(
                    title: "Show Audiobooks",
                    subtitle: "Add Audiobooks to the main navigation",
                    systemImage: "book.closed.fill",
                    isOn: Binding(
                        get: { navPrefs.showAudiobooks },
                        set: { navPrefs.setShowAudiobooks($0) }
                    )
                )
            }

            ForEach(ExperimentalFeature.allCases.filter {
                matchesExperimentalName || matches($0.title, $0.subtitle)
            }, id: \.self) { feature in
                SettingsOverviewToggleRow(
                    title: feature.title,
                    subtitle: feature.subtitle,
                    systemImage: feature.systemImage,
                    isOn: Binding(
                        get: { experimental.isEnabled(feature) },
                        set: { feature.setEnabled($0) }
                    )
                )
            }
        }
    }

    private var signOutSection: some View {
        Section {
            Button("Sign Out", role: .destructive) {
                showSignOutConfirm = true
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(Color.red)
        }
    }

    private var displayName: String {
        if let name = viewModel.activeProfile?.name, !name.isEmpty {
            return name
        }
        if let username = viewModel.userInfo?.username, !username.isEmpty {
            return username
        }
        return "Switch Profile"
    }

    private var subtitleLine: String {
        let host = serverHost
        let username = viewModel.userInfo?.username
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

    private var serverHost: String? {
        guard let url = URL(string: viewModel.serverUrl), let host = url.host else {
            return viewModel.serverUrl.isEmpty ? nil : viewModel.serverUrl
        }
        return host
    }

    private func switchProfile() {
        router.switchProfile()
    }

    private func subtitleLanguageName(_ tag: String) -> String {
        if tag == PlaybackPrefSentinel.none || tag.isEmpty { return "None" }
        return PlaybackLanguageOption.label(forCode: tag)
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        guard let build = info?["CFBundleVersion"] as? String,
              !build.isEmpty,
              build != version else {
            return version
        }
        return "\(version) (\(build))"
    }

    private var matchesPlayback: Bool {
        matches("playback", "quality", "audio", "dolby vision", "episodes", "skipping", "skip interval", "rewind", "fast forward", "audiobooks")
    }

    private var matchesInterface: Bool {
        matches("interface", "appearance", "navigation", "menu", "cards", "posters", "captions")
    }

    private var matchesGeneral: Bool {
        matches("general", "profile", "selection", "launch", "startup", "automatic", "every time", "hours", "who's watching", "pin")
    }

    private var matchesSubtitles: Bool {
        matches("subtitles", "captions", "language", "behavior", "appearance")
    }

    private var matchesDownloads: Bool {
        DownloadManager.shared.downloadsEnabled
            && matches("downloads", "offline", "quality", "cleanup", "storage")
    }

    private var matchesDiagnostics: Bool {
        matches("diagnostics", "support", "reports", "debug", "crash")
    }

    private var matchesAudiobooks: Bool {
        matches("audiobooks", "navigation", "library")
    }

    private var matchesConnectionSection: Bool {
        matches("server", "connection", viewModel.serverDisplayName) || matchesSignInTV
    }

    private var matchesAboutSection: Bool {
        matches(
            "about",
            "version",
            versionString,
            "privacy",
            "policy",
            "information",
            "open source",
            "licenses",
            "acknowledgements"
        )
    }

    private var matchesExperimentalName: Bool {
        matches("experimental", "beta", "testing")
    }

    private var matchesExperimentalSection: Bool {
        matchesExperimentalName
            || matchesAudiobooks
            || ExperimentalFeature.allCases.contains { matches($0.title, $0.subtitle) }
    }

    private var matchesSignOut: Bool {
        matches("sign out", "account")
    }

    private var matchesPlaybackSection: Bool {
        matchesPlayback || matchesSubtitles || matchesDownloads
    }

    private var hasSearchResults: Bool {
        matchesGeneral
            || matchesInterface
            || matchesPlaybackSection
            || (diagnosticsModel.shouldShowSettings && matchesDiagnostics)
            || matchesAccountSignIn
            || matchesConnectionSection
            || matchesExperimentalSection
            || matchesAboutSection
            || matchesSignOut
    }

    private func matches(_ terms: String...) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return terms.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
#endif
