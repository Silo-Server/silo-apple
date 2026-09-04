import SwiftUI

/// App settings screen.
///
/// iOS: a searchable, card-based overview aligned with the web app's
/// information hierarchy. macOS retains the compact native Settings list.
///
/// On tvOS this view delegates to ``TVSettingsView``, a root-menu Form
/// with drill-in sub-screens tuned for the 10-foot experience.
struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()
    @State private var uiCustomization = UICustomizationPreferences.shared
    @State private var launchPreferences = ProfileLaunchPreferences.shared
    @Environment(AppRouter.self) private var router
    @State private var showSignOutConfirm = false
    #if os(iOS)
    @State private var diagnosticsModel = DiagnosticsViewModel()
    #endif

    var body: some View {
        #if os(tvOS)
        TVSettingsView()
        #elseif os(iOS)
        iOSOverview
        #else
        macOSBody
        #endif
    }

    #if os(iOS)
    private var iOSOverview: some View {
        IOSSettingsOverview(
            viewModel: viewModel,
            diagnosticsModel: diagnosticsModel,
            uiCustomization: uiCustomization,
            showSignOutConfirm: $showSignOutConfirm
        )
        .task {
            await viewModel.loadSettings()
            await diagnosticsModel.load(profile: viewModel.activeProfile)
        }
        .alert("Sign Out", isPresented: $showSignOutConfirm) {
            Button("Sign Out", role: .destructive) {
                router.signOutAndReset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to sign out?")
        }
    }
    #endif

    #if os(macOS)
    private var macOSBody: some View {
        List {
            accountSection
            preferencesSection
            connectionSection
            aboutSection
            signOutSection
        }
        .continuumGroupedListStyle()
        .navigationTitle("Settings")
        .continuumNavigationTitleDisplayMode(.large)
        .continuumToolbarColorSchemeDark()
        .task {
            await viewModel.loadSettings()
        }
        .alert("Sign Out", isPresented: $showSignOutConfirm) {
            Button("Sign Out", role: .destructive) {
                router.signOutAndReset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to sign out?")
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            Button(action: switchProfile) {
                HStack(spacing: 14) {
                    ProfileAvatarView(
                        avatar: viewModel.activeProfile?.avatarEmoji,
                        imageUrl: viewModel.activeProfile?.avatarImageUrl,
                        name: viewModel.activeProfile?.name
                            ?? viewModel.userInfo?.username
                            ?? "",
                        size: 56
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.continuumOnSurface)
                            .lineLimit(1)

                        Text(subtitleLine)
                            .font(.footnote)
                            .foregroundStyle(Color.continuumSecondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    SettingsRowChevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Switches to a different profile")

        } footer: {
            if viewModel.userInfo?.isAdmin == true {
                Text("Signed in as an administrator.")
                    .foregroundStyle(Color.continuumSecondaryText)
            }
        }
    }

    private func switchProfile() {
        router.switchProfile()
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

    // MARK: - Preferences

    private var preferencesSection: some View {
        Section {
            NavigationLink {
                GeneralSettingsView()
            } label: {
                SettingsRowLabel(
                    title: "General",
                    systemImage: "gearshape.fill",
                    color: .purple,
                    value: launchPreferences.behavior.title
                )
            }

            NavigationLink {
                InterfaceCustomizationView()
            } label: {
                SettingsRowLabel(
                    title: "Interface",
                    systemImage: "rectangle.3.group.fill",
                    color: .indigo,
                    value: uiCustomization.cardPresentation.preset?.title ?? "Custom"
                )
            }

            NavigationLink {
                PlaybackSettingsView(viewModel: viewModel)
            } label: {
                SettingsRowLabel(
                    title: "Playback",
                    systemImage: "play.fill",
                    color: .blue,
                    value: viewModel.preferredQualityLabel
                )
            }

            NavigationLink {
                SubtitleSettingsView(viewModel: viewModel)
            } label: {
                SettingsRowLabel(
                    title: "Subtitles",
                    systemImage: "captions.bubble.fill",
                    color: .pink,
                    value: subtitleLanguageName(viewModel.editorSubtitleLanguage)
                )
            }

            if DownloadManager.shared.downloadsEnabled {
                NavigationLink {
                    DownloadsSettingsView()
                } label: {
                    SettingsRowLabel(
                        title: "Downloads",
                        systemImage: "arrow.down.circle.fill",
                        color: .blue
                    )
                }
            }
        }
    }

    private func subtitleLanguageName(_ tag: String) -> String {
        if tag == PlaybackPrefSentinel.none || tag.isEmpty { return "None" }
        return PlaybackLanguageOption.label(forCode: tag)
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
            Button {
                router.navigate(to: .serverList)
            } label: {
                HStack(spacing: 0) {
                    SettingsRowLabel(
                        title: "Server",
                        systemImage: "server.rack",
                        color: .teal,
                        value: viewModel.serverDisplayName
                    )
                    SettingsRowChevron()
                        .padding(.leading, 8)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent {
                Text(versionString)
                    .foregroundStyle(Color.continuumSecondaryText)
            } label: {
                Text("Version")
                    .foregroundStyle(Color.continuumOnSurface)
            }

            Link("Privacy Policy", destination: SiloLegalLinks.privacyPolicy)

            NavigationLink {
                OpenSourceAcknowledgementsView()
            } label: {
                SettingsRowLabel(
                    title: "Open Source Licenses",
                    systemImage: "curlybraces",
                    color: .indigo
                )
            }
        }
    }

    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String, build != short {
            return "\(short) (\(build))"
        }
        return short
    }

    // MARK: - Sign Out

    private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                showSignOutConfirm = true
            } label: {
                Text("Sign Out")
                    .frame(maxWidth: .infinity)
            }
        }
    }
    #endif
}

#if os(macOS)

// MARK: - Row primitives

/// Settings-app style row label: a colored rounded-square icon badge,
/// the row title, and an optional trailing value in secondary color.
struct SettingsRowLabel: View {
    let title: String
    let systemImage: String
    let color: Color
    var value: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7)
                .fill(color.gradient)
                .frame(width: 29, height: 29)
                .overlay {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }

            Text(title)
                .foregroundStyle(Color.continuumOnSurface)

            Spacer(minLength: 8)

            if let value {
                Text(value)
                    .foregroundStyle(Color.continuumSecondaryText)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Disclosure chevron for `Button` rows that act like navigation rows
/// (`NavigationLink` rows draw their own).
struct SettingsRowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.continuumSecondaryText.opacity(0.6))
            .accessibilityHidden(true)
    }
}

#endif
