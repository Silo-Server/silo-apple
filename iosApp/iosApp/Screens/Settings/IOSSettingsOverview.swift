#if os(iOS)
import SwiftUI

/// Searchable, card-based iOS Settings overview. Its information hierarchy
/// intentionally mirrors the web client while navigation and controls remain
/// native SwiftUI for Dynamic Type, VoiceOver, and predictable gestures.
struct IOSSettingsOverview: View {
    @Bindable var viewModel: SettingsViewModel
    @Bindable var diagnosticsModel: DiagnosticsViewModel
    @Bindable var uiCustomization: UICustomizationPreferences
    @Binding var showSignOutConfirm: Bool

    @Environment(AppRouter.self) private var router
    @State private var navPrefs = AppNavPreferences.shared
    @State private var launchPreferences = ProfileLaunchPreferences.shared
    @State private var searchText = ""

    var body: some View {
        ZStack {
            SettingsBackdrop()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    pageHeader

                    SettingsAccountCard(
                        avatar: viewModel.activeProfile?.avatarEmoji,
                        name: displayName,
                        subtitle: subtitleLine,
                        isAdministrator: viewModel.userInfo?.isAdmin == true,
                        action: switchProfile
                    )

                    if matchesProfileLaunch {
                        profileLaunchSection
                    }

                    SettingsSearchField(text: $searchText)

                    if hasSearchResults {
                        interfaceSection
                        playbackSection

                        if diagnosticsModel.shouldShowSettings && matchesDiagnostics {
                            diagnosticsSection
                        }

                        if matchesLibrarySection {
                            librarySection
                        }

                        if matchesConnectionSection {
                            connectionSection
                        }

                        if matchesAboutSection {
                            aboutSection
                        }

                        if matchesSignOut {
                            signOutButton
                        }
                    } else {
                        ContentUnavailableView.search
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 36)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("")
        .continuumNavigationTitleDisplayMode(.inline)
        .continuumNavigationBarBackgroundHidden()
        .continuumToolbarColorSchemeDark()
        .onAppear(perform: navPrefs.refresh)
    }

    private var profileLaunchSection: some View {
        SettingsOverviewSection("Account") {
            Menu {
                Picker("Profile at Launch", selection: $launchPreferences.behavior) {
                    ForEach(ProfileLaunchBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
            } label: {
                SettingsOverviewRow(
                    title: "Profile at Launch",
                    subtitle: launchPreferences.behavior.standardDescription,
                    systemImage: "person.crop.circle.badge.clock",
                    tint: .purple,
                    value: launchPreferences.behavior.title
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint(launchPreferences.behavior.standardDescription)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Settings")
                .font(.largeTitle)
                .bold()
                .foregroundStyle(Color.continuumOnSurface)

            Text("Make Silo work the way you like.")
                .font(.subheadline)
                .foregroundStyle(Color.continuumSecondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var interfaceSection: some View {
        if matchesInterface {
            SettingsOverviewSection("Interface") {
                NavigationLink {
                    InterfaceCustomizationView()
                } label: {
                    SettingsOverviewRow(
                        title: "Interface",
                        subtitle: "Navigation, cards, and poster presentation",
                        systemImage: "rectangle.3.group.fill",
                        tint: .indigo,
                        value: uiCustomization.cardPresentation.preset?.title ?? "Custom"
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var playbackSection: some View {
        if matchesPlaybackSection {
            SettingsOverviewSection("Playback") {
                if matches("playback", "quality", "audio", "dolby vision", "episodes", "skipping") {
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
                    .buttonStyle(.plain)
                }

                if matchesPlayback && matchesSubtitles {
                    SettingsOverviewDivider()
                }

                if matchesSubtitles {
                    NavigationLink {
                        SubtitleSettingsView(viewModel: viewModel)
                    } label: {
                        SettingsOverviewRow(
                            title: "Subtitles",
                            subtitle: "Language, behavior, and appearance",
                            systemImage: "captions.bubble.fill",
                            tint: .pink,
                            value: subtitleLanguageName(viewModel.editorSubtitleLanguage)
                        )
                    }
                    .buttonStyle(.plain)
                }

                if matchesDownloads {
                    if matchesPlayback || matchesSubtitles {
                        SettingsOverviewDivider()
                    }

                    NavigationLink {
                        DownloadsSettingsView()
                    } label: {
                        SettingsOverviewRow(
                            title: "Downloads",
                            subtitle: "Quality, cleanup, and storage",
                            systemImage: "arrow.down.circle.fill"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var diagnosticsSection: some View {
        SettingsOverviewSection("Support") {
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
                    tint: .orange,
                    value: diagnosticsModel.featureState.title
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var librarySection: some View {
        SettingsOverviewSection("Library & Data") {
            if matchesAudiobooks {
                SettingsOverviewToggleRow(
                    title: "Show Audiobooks",
                    subtitle: "Add Audiobooks to the main navigation",
                    systemImage: "book.closed.fill",
                    tint: .indigo,
                    isOn: Binding(
                        get: { navPrefs.showAudiobooks },
                        set: { navPrefs.setShowAudiobooks($0) }
                    )
                )
            }

            if matchesAudiobooks && matchesWatchlist {
                SettingsOverviewDivider()
            }

            if matchesWatchlist {
                NavigationLink {
                    WatchlistView()
                } label: {
                    SettingsOverviewRow(
                        title: "Watchlist",
                        subtitle: "Titles you plan to watch",
                        systemImage: "bookmark.fill",
                        tint: .orange
                    )
                }
                .buttonStyle(.plain)
            }

            if (matchesAudiobooks || matchesWatchlist) && matchesFavorites {
                SettingsOverviewDivider()
            }

            if matchesFavorites {
                NavigationLink {
                    FavoritesView()
                } label: {
                    SettingsOverviewRow(
                        title: "Favorites",
                        subtitle: "Your saved movies and shows",
                        systemImage: "heart.fill",
                        tint: .red
                    )
                }
                .buttonStyle(.plain)
            }

            if (matchesAudiobooks || matchesWatchlist || matchesFavorites) && matchesHistory {
                SettingsOverviewDivider()
            }

            if matchesHistory {
                NavigationLink {
                    HistoryView()
                } label: {
                    SettingsOverviewRow(
                        title: "Watch History",
                        subtitle: "Review recently watched titles",
                        systemImage: "clock.fill",
                        tint: .gray
                    )
                }
                .buttonStyle(.plain)
            }

            if (matchesAudiobooks || matchesWatchlist || matchesFavorites || matchesHistory)
                && matchesCollections {
                SettingsOverviewDivider()
            }

            if matchesCollections {
                NavigationLink {
                    CollectionsView()
                } label: {
                    SettingsOverviewRow(
                        title: "Collections",
                        subtitle: "Browse grouped movies and shows",
                        systemImage: "square.stack.fill",
                        tint: .purple
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var connectionSection: some View {
        SettingsOverviewSection("Connection") {
            Button {
                router.navigate(to: .serverList)
            } label: {
                SettingsOverviewRow(
                    title: "Server",
                    subtitle: "Manage this device's Silo connection",
                    systemImage: "server.rack",
                    tint: .teal,
                    value: viewModel.serverDisplayName
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var aboutSection: some View {
        SettingsOverviewSection("About") {
            SettingsOverviewRow(
                title: "Version",
                subtitle: "Installed Silo app version",
                systemImage: "info.circle.fill",
                tint: .gray,
                value: versionString,
                showsChevron: false
            )
        }
    }

    private var signOutButton: some View {
        Button(role: .destructive) {
            showSignOutConfirm = true
        } label: {
            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.red)
        .background(Color.red.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.red.opacity(0.18), lineWidth: 1)
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
        matches("playback", "quality", "audio", "dolby vision", "episodes", "skipping")
    }

    private var matchesInterface: Bool {
        matches("interface", "appearance", "navigation", "menu", "cards", "posters", "captions")
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

    private var matchesWatchlist: Bool {
        matches("watchlist", "saved", "library")
    }

    private var matchesFavorites: Bool {
        matches("favorites", "saved", "library")
    }

    private var matchesHistory: Bool {
        matches("watch history", "recently watched", "history", "library")
    }

    private var matchesCollections: Bool {
        matches("collections", "groups", "library")
    }

    private var matchesConnectionSection: Bool {
        matches("server", "connection", viewModel.serverDisplayName)
    }

    private var matchesAboutSection: Bool {
        matches("about", "version", versionString)
    }

    private var matchesSignOut: Bool {
        matches("sign out", "account")
    }

    private var matchesProfileLaunch: Bool {
        matches("profile", "launch", "automatic", "ask every time", "who's watching", "account")
    }

    private var matchesPlaybackSection: Bool {
        matchesPlayback || matchesSubtitles || matchesDownloads
    }

    private var matchesLibrarySection: Bool {
        matchesAudiobooks || matchesWatchlist || matchesFavorites || matchesHistory || matchesCollections
    }

    private var hasSearchResults: Bool {
        matchesInterface
            || matchesProfileLaunch
            || matchesPlaybackSection
            || (diagnosticsModel.shouldShowSettings && matchesDiagnostics)
            || matchesLibrarySection
            || matchesConnectionSection
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
