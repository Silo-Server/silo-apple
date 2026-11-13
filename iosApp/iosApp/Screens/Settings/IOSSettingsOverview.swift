#if os(iOS)
import SwiftUI

/// Searchable iOS Settings overview in the system Settings idiom: an
/// inset-grouped list of one-line rows with graphite icon tiles. Search
/// still matches each row's longer description, which VoiceOver reads as
/// the row's hint.
struct IOSSettingsOverview: View {
    let viewModel: SettingsViewModel
    let diagnosticsModel: DiagnosticsViewModel
    let uiCustomization: UICustomizationPreferences

    @Environment(AppRouter.self) private var router
    @State private var navPrefs = AppNavPreferences.shared
    @State private var launchPreferences = ProfileLaunchPreferences.shared
    @State private var experimental = ExperimentalFeatures.shared
    @State private var searchText = ""
    @State private var showsSignInTV = false
    @State private var accountSignIn = AccountSignInModel.live()
    @Environment(\.locale) private var locale

    var body: some View {
        List {
            Section {
                SettingsAccountCard(
                    avatar: viewModel.activeProfile?.avatarEmoji,
                    avatarImageUrl: viewModel.activeProfile?.avatarImageUrl,
                    name: viewModel.displayName,
                    subtitle: .verbatim(viewModel.accountSubtitleLine),
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
        .navigationTitle(Text(.settingsTitle))
        .siloNavigationTitleDisplayMode(.large)
        .siloToolbarColorSchemeDark()
        .onAppear(perform: navPrefs.refresh)
        .task { await accountSignIn.load() }
        .sheet(isPresented: $showsSignInTV) {
            SignInTVView(onAddAccount: { server, link, choosingAccount in
                showsSignInTV = false
                router.addAccount(forTVApproval: link, on: server, choosingAccount: choosingAccount)
            }, onClose: { showsSignInTV = false })
        }
    }

    @ViewBuilder
    private var preferencesSection: some View {
        if matchesGeneral || matchesInterface {
            Section(.settingsOverviewPreferences) {
                if matchesGeneral {
                    NavigationLink {
                        GeneralSettingsView()
                    } label: {
                        SettingsOverviewRow(
                            title: .settingsGeneral,
                            subtitle: .settingsOverviewGeneralSubtitle,
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
                            title: .settingsInterfaceTitle,
                            subtitle: .settingsOverviewInterfaceSubtitle,
                            systemImage: "rectangle.3.group.fill",
                            value: uiCustomization.cardPresentation.posterSize.title
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var playbackSection: some View {
        if matchesPlaybackSection {
            Section(.settingsPlayback) {
                if matchesPlayback {
                    NavigationLink {
                        PlaybackSettingsView(viewModel: viewModel)
                    } label: {
                        SettingsOverviewRow(
                            title: .settingsPlayback,
                            subtitle: .settingsOverviewPlaybackSubtitle,
                            systemImage: "play.fill",
                            value: .verbatim(viewModel.preferredQualityLabel)
                        )
                    }
                }

                if matchesSubtitles {
                    NavigationLink {
                        SubtitleSettingsView(viewModel: viewModel)
                    } label: {
                        SettingsOverviewRow(
                            title: .settingsSubtitles,
                            subtitle: .settingsOverviewSubtitlesSubtitle,
                            systemImage: "captions.bubble.fill",
                            value: .verbatim(viewModel.subtitleLanguageName)
                        )
                    }
                }

                if matchesDownloads {
                    NavigationLink {
                        DownloadsSettingsView()
                    } label: {
                        SettingsOverviewRow(
                            title: .settingsDownloadsTitle,
                            subtitle: .settingsOverviewDownloadsSubtitle,
                            systemImage: "arrow.down.circle.fill"
                        )
                    }
                }
            }
        }
    }

    private var diagnosticsSection: some View {
        Section(.settingsOverviewSupport) {
            NavigationLink {
                DiagnosticsSettingsView(
                    model: diagnosticsModel,
                    profile: viewModel.activeProfile
                )
            } label: {
                SettingsOverviewRow(
                    title: .settingsDiagnostics,
                    subtitle: .settingsOverviewDiagnosticsSubtitle,
                    systemImage: "stethoscope",
                    value: diagnosticsModel.featureState.title
                )
            }
        }
    }

    /// Shown only when the server has an external sign-in provider or the
    /// account already has a provider identity.
    private var accountSignInSection: some View {
        Section(.settingsOverviewAccount) {
            NavigationLink {
                AccountSignInView(model: accountSignIn)
            } label: {
                SettingsOverviewRow(
                    title: .settingsSignInTitle,
                    subtitle: .settingsOverviewSignInSubtitle,
                    systemImage: "person.badge.key.fill",
                    value: accountSignIn.identities.first.map { .verbatim($0.providerName) }
                )
            }
            .accessibilityIdentifier("settings.accountSignIn")
        }
    }

    private var matchesAccountSignIn: Bool {
        accountSignIn.showsEntry && matches(.settingsSearchIosTermsAccountSignIn, "sign-in", "sign in", "account", "provider", "sso", "single sign-on", "connect")
    }

    private var connectionSection: some View {
        Section(.settingsOverviewConnection) {
            Button {
                router.navigate(to: .accounts)
            } label: {
                SettingsOverviewRow(
                    title: .accountsTitle,
                    subtitle: .settingsOverviewAccountsSubtitle,
                    systemImage: "person.2.fill",
                    value: .verbatim(viewModel.serverDisplayName),
                    showsChevron: true
                )
            }
            if matchesSignInTV {
                Button {
                    showsSignInTV = true
                } label: {
                    SettingsOverviewRow(
                        title: .signInTvSettingsLabel,
                        subtitle: .settingsOverviewSignInTvSubtitle,
                        systemImage: "tv",
                        showsChevron: true
                    )
                }
            }
        }
    }

    private var matchesSignInTV: Bool {
        matches(.settingsSearchIosTermsSignInTv, "sign in a tv", "tv", "apple tv", "android tv", "code", "device")
    }

    private var aboutSection: some View {
        Section(.settingsAboutTitle) {
            SettingsOverviewRow(
                title: .settingsAboutVersion,
                subtitle: .settingsOverviewVersionSubtitle,
                systemImage: "info.circle.fill",
                value: .verbatim(SettingsViewModel.versionString)
            )

            Link(destination: SiloLegalLinks.privacyPolicy) {
                SettingsOverviewRow(
                    title: .settingsAboutPrivacyPolicy,
                    subtitle: .settingsOverviewPrivacyPolicySubtitle,
                    systemImage: "hand.raised.fill",
                    showsChevron: true
                )
            }

            NavigationLink {
                AcknowledgementsView()
            } label: {
                SettingsOverviewRow(
                    title: .settingsAboutAcknowledgements,
                    subtitle: .settingsOverviewAcknowledgementsSubtitle,
                    systemImage: "curlybraces"
                )
            }

            Link(destination: SiloLegalLinks.sourceCode) {
                SettingsOverviewRow(
                    title: .settingsAboutSourceCode,
                    subtitle: .settingsOverviewSourceCodeSubtitle,
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    showsChevron: true
                )
            }
        }
    }

    private var experimentalSection: some View {
        // A query naming the section shows every row; otherwise each row
        // appears only for its own terms.
        Section(.settingsExperimentalExtraFeatures) {
            if matchesExperimentalName || matchesAudiobooks {
                SettingsOverviewToggleRow(
                    title: .settingsExperimentalShowAudiobooks,
                    subtitle: .settingsExperimentalShowAudiobooksSubtitle,
                    systemImage: "book.closed.fill",
                    isOn: Binding(
                        get: { navPrefs.showAudiobooks },
                        set: { navPrefs.setShowAudiobooks($0) }
                    )
                )
            }

            ForEach(ExperimentalFeature.allCases.filter {
                matchesExperimentalName || matches(feature: $0)
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
            // Signs out of the current account; the router confirms first,
            // naming the account, its server, and its downloads.
            Button(.settingsSignOut, role: .destructive) {
                router.signOutAndReset()
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(Color.red)
        }
    }

    private func switchProfile() {
        router.switchProfile()
    }

    private var matchesPlayback: Bool {
        matches(.settingsSearchIosTermsPlayback, "playback", "quality", "resolution", "bitrate", "buffering", "speed", "limit", "cellular", "mobile data", "audio", "dolby vision", "episodes", "skipping", "skip interval", "rewind", "fast forward", "audiobooks", "spoilers", "blur", "thumbnails", "descriptions")
    }

    private var matchesInterface: Bool {
        matches(.settingsSearchIosTermsInterface, "interface", "appearance", "cards", "posters", "title art", "theme music", "theme song")
    }

    private var matchesGeneral: Bool {
        matches(.settingsSearchIosTermsGeneral, "general", "profile", "selection", "launch", "startup", "automatic", "every time", "hours", "who's watching", "pin")
    }

    private var matchesSubtitles: Bool {
        matches(.settingsSearchIosTermsSubtitles, "subtitles", "captions", "language", "behavior", "appearance")
    }

    private var matchesDownloads: Bool {
        DownloadManager.shared.downloadsEnabled
            && matches(.settingsSearchIosTermsDownloads, "downloads", "offline", "quality", "cleanup", "storage")
    }

    private var matchesDiagnostics: Bool {
        matches(.settingsSearchTermsDiagnostics, "diagnostics", "support", "reports", "debug", "crash")
    }

    private var matchesAudiobooks: Bool {
        matches(.settingsSearchIosTermsAudiobooks, "audiobooks", "navigation", "library")
    }

    private var matchesConnectionSection: Bool {
        matches(.settingsSearchIosTermsConnection, "server", "connection", "account", "sign out", viewModel.serverDisplayName)
            || matchesSignInTV
    }

    private var matchesAboutSection: Bool {
        matches(
            .settingsSearchIosTermsAbout,
            "about",
            "version",
            SettingsViewModel.versionString,
            "privacy",
            "policy",
            "information",
            "open source",
            "licenses",
            "acknowledgements",
            "source code",
            "AGPL",
            "credits",
            "attribution",
            "TMDB"
        )
    }

    private var matchesExperimentalName: Bool {
        matches(.settingsSearchIosTermsExtraFeatures, "extra features", "experimental")
    }

    private var matchesExperimentalSection: Bool {
        matchesExperimentalName
            || matchesAudiobooks
            || ExperimentalFeature.allCases.contains { matches(feature: $0) }
    }

    private var matchesSignOut: Bool {
        matches(.settingsSearchTermsSignOut, "sign out", "account")
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

    /// The English terms always match (they are matching data, never shown),
    /// and so do the catalog's terms in the app language. Translations may
    /// separate them with their own script's comma.
    private func matches(_ catalogTerms: LocalizedStringResource, _ terms: String...) -> Bool {
        guard let query else { return true }
        let translated = AppLanguage.string(catalogTerms, locale: locale)
            .split(whereSeparator: { ",、，،".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return Self.matches(query, terms + translated)
    }

    /// An extra feature's row matches its title and subtitle as shown, and
    /// in English.
    private func matches(feature: ExperimentalFeature) -> Bool {
        guard let query else { return true }
        return Self.matches(query, [feature.title, feature.subtitle].flatMap {
            [AppLanguage.string($0, locale: locale), AppLanguage.string($0, locale: Self.english)]
        })
    }

    private static let english = Locale(identifier: "en")

    /// The trimmed search text; nil when empty, which matches every row.
    private var query: String? {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? nil : query
    }

    private static func matches(_ query: String, _ terms: [String]) -> Bool {
        terms.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
#endif
