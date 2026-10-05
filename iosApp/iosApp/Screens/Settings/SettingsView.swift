import SwiftUI

/// App settings screen.
///
/// iOS: a searchable, inset-grouped overview in the system Settings idiom.
/// macOS retains the compact native Settings list.
///
/// On tvOS this view delegates to ``TVSettingsView``, a root-menu Form
/// with drill-in sub-screens tuned for the 10-foot experience.
struct SettingsView: View {
    #if os(tvOS)
    var body: some View {
        TVSettingsView()
    }
    #else
    @State private var viewModel = SettingsViewModel()
    @State private var uiCustomization = UICustomizationPreferences.shared
    @Environment(AppRouter.self) private var router
    @State private var showSignOutConfirm = false
    #if os(iOS)
    @State private var diagnosticsModel = DiagnosticsViewModel()
    #endif
    #if os(macOS)
    @State private var launchPreferences = ProfileLaunchPreferences.shared
    @State private var accountSignIn = AccountSignInModel.live()
    #endif

    var body: some View {
        Group {
            #if os(iOS)
            iOSOverview
            #else
            macOSBody
            #endif
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
    }
    #endif

    #if os(macOS)
    private var macOSBody: some View {
        List {
            accountSection
            if accountSignIn.showsEntry {
                accountSignInSection
            }
            preferencesSection
            connectionSection
            aboutSection
            signOutSection
        }
        #if os(macOS)
        .settingsListChrome()
        #else
        .siloGroupedListStyle()
        #endif
        .navigationTitle("Settings")
        .siloNavigationTitleDisplayMode(.large)
        .siloToolbarColorSchemeDark()
        .task {
            await viewModel.loadSettings()
        }
        .task { await accountSignIn.load() }
    }

    // MARK: - Sign-in

    private var accountSignInSection: some View {
        Section {
            NavigationLink {
                AccountSignInView(model: accountSignIn)
            } label: {
                SettingsRowLabel(
                    title: "Sign-in",
                    systemImage: "person.badge.key.fill",
                    color: .blue,
                    value: accountSignIn.identities.first?.providerName
                )
            }
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
                        Text(viewModel.displayName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.siloOnSurface)
                            .lineLimit(1)

                        Text(viewModel.accountSubtitleLine)
                            .font(.footnote)
                            .foregroundStyle(Color.siloSecondaryText)
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
                    .foregroundStyle(Color.siloSecondaryText)
            }
        }
    }

    private func switchProfile() {
        router.switchProfile()
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
                    value: viewModel.subtitleLanguageName
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
                Text(SettingsViewModel.versionString)
                    .foregroundStyle(Color.siloSecondaryText)
            } label: {
                Text("Version")
                    .foregroundStyle(Color.siloOnSurface)
            }

            Link("Privacy Policy", destination: SiloLegalLinks.privacyPolicy)

            NavigationLink {
                AcknowledgementsView()
            } label: {
                SettingsRowLabel(
                    title: "Acknowledgements",
                    systemImage: "curlybraces",
                    color: .indigo
                )
            }

            Link("Source Code", destination: SiloLegalLinks.sourceCode)
        }
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

    /// The Mac keeps its chrome monochrome, so every tile is the same grey
    /// there; iOS keeps the per-row colours of its Settings app.
    private var tileFill: AnyShapeStyle {
        #if os(macOS)
        AnyShapeStyle(Color.siloIconTile)
        #else
        AnyShapeStyle(color.gradient)
        #endif
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7)
                .fill(tileFill)
                .frame(width: 29, height: 29)
                .overlay {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }

            Text(title)
                .foregroundStyle(Color.siloOnSurface)

            Spacer(minLength: 8)

            if let value {
                Text(value)
                    .foregroundStyle(Color.siloSecondaryText)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
#endif

#if !os(tvOS)
/// Disclosure chevron for `Button` rows that act like navigation rows
/// (`NavigationLink` rows draw their own).
struct SettingsRowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.siloSecondaryText.opacity(0.6))
            .accessibilityHidden(true)
    }
}
#endif
