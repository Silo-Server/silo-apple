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
                        name: viewModel.displayName,
                        subtitle: viewModel.subtitleLine,
                        isAdministrator: viewModel.userInfo?.isAdmin == true,
                        action: { router.switchProfile() }
                    )

                    SettingsSearchField(text: $searchText)

                    if hasSearchResults {
                        preferencesSection
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
        .siloNavigationTitleDisplayMode(.inline)
        .siloNavigationBarBackgroundHidden()
        .siloToolbarColorSchemeDark()
        .onAppear(perform: navPrefs.refresh)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Settings")
                .font(.largeTitle)
                .bold()
                .foregroundStyle(Color.siloOnSurface)

            Text("Make Silo work the way you like.")
                .font(.subheadline)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var preferencesSection: some View {
        if matchesGeneral || matchesInterface {
            SettingsOverviewSection("Preferences") {
                if matchesGeneral {
                    NavigationLink {
                        GeneralSettingsView()
                    } label: {
                        SettingsOverviewRow(
                            title: "General",
                            subtitle: "Profile selection and app startup",
                            systemImage: "gearshape.fill",
                            tint: .purple,
                            value: launchPreferences.behavior.title
                        )
                    }
                    .buttonStyle(.plain)
                }

                if matchesGeneral && matchesInterface {
                    SettingsOverviewDivider()
                }

                if matchesInterface {
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
    }

    @ViewBuilder
    private var playbackSection: some View {
        if matchesPlaybackSection {
            SettingsOverviewSection("Playback") {
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
                            value: viewModel.subtitleLanguageName(viewModel.editorSubtitleLanguage)
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
                value: viewModel.versionString,
                showsChevron: false
            )

            SettingsOverviewDivider()

            Link(destination: SiloLegalLinks.privacyPolicy) {
                SettingsOverviewRow(
                    title: "Privacy Policy",
                    subtitle: "Learn how Silo handles your information",
                    systemImage: "hand.raised.fill",
                    tint: .teal
                )
            }
            .buttonStyle(.plain)
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

    private var matchesPlayback: Bool {
        matches("playback", "quality", "audio", "dolby vision", "episodes", "skipping")
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
        matches("server", "connection", viewModel.serverDisplayName)
    }

    private var matchesAboutSection: Bool {
        matches("about", "version", viewModel.versionString, "privacy", "policy", "information")
    }

    private var matchesSignOut: Bool {
        matches("sign out", "account")
    }

    private var matchesPlaybackSection: Bool {
        matchesPlayback || matchesSubtitles || matchesDownloads
    }

    private var matchesLibrarySection: Bool {
        matchesAudiobooks
    }

    private var hasSearchResults: Bool {
        matchesGeneral
            || matchesInterface
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
