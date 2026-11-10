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
    /// Rows show view-model text resolved in the app language; reading the
    /// locale re-renders them when it changes.
    @Environment(\.locale) private var locale
    #if os(iOS)
    @State private var diagnosticsModel = DiagnosticsViewModel()
    #endif
    #if os(macOS)
    @State private var launchPreferences = ProfileLaunchPreferences.shared
    @State private var accountSignIn = AccountSignInModel.live()
    #endif

    var body: some View {
        let _ = locale
        Group {
            #if os(iOS)
            iOSOverview
            #else
            macOSBody
            #endif
        }
    }
    #endif

    #if os(iOS)
    private var iOSOverview: some View {
        IOSSettingsOverview(
            viewModel: viewModel,
            diagnosticsModel: diagnosticsModel,
            uiCustomization: uiCustomization
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
        .settingsListChrome()
        .navigationTitle(Text(.settingsTitle))
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
                    title: .settingsSignInTitle,
                    systemImage: "person.badge.key.fill",
                    color: .blue,
                    value: accountSignIn.identities.first.map { .verbatim($0.providerName) }
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
            .accessibilityHint(Text(.settingsOverviewSwitchProfileHint))

        } footer: {
            if viewModel.userInfo?.isAdmin == true {
                Text(.settingsOverviewAdministratorFooter)
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
                    title: .settingsGeneral,
                    systemImage: "gearshape.fill",
                    color: .purple,
                    value: launchPreferences.behavior.title
                )
            }

            NavigationLink {
                InterfaceCustomizationView()
            } label: {
                SettingsRowLabel(
                    title: .settingsInterfaceTitle,
                    systemImage: "rectangle.3.group.fill",
                    color: .indigo,
                    value: .verbatim(uiCustomization.cardPresentation.posterSize.title)
                )
            }

            NavigationLink {
                PlaybackSettingsView(viewModel: viewModel)
            } label: {
                SettingsRowLabel(
                    title: .settingsPlayback,
                    systemImage: "play.fill",
                    color: .blue,
                    value: .verbatim(viewModel.preferredQualityLabel)
                )
            }

            NavigationLink {
                SubtitleSettingsView(viewModel: viewModel)
            } label: {
                SettingsRowLabel(
                    title: .settingsSubtitles,
                    systemImage: "captions.bubble.fill",
                    color: .pink,
                    value: .verbatim(viewModel.subtitleLanguageName)
                )
            }

            if DownloadManager.shared.downloadsEnabled {
                NavigationLink {
                    DownloadsSettingsView()
                } label: {
                    SettingsRowLabel(
                        title: .settingsDownloadsTitle,
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
                router.navigate(to: .accounts)
            } label: {
                HStack(spacing: 0) {
                    SettingsRowLabel(
                        title: .accountsTitle,
                        systemImage: "person.2.fill",
                        color: .teal,
                        value: .verbatim(viewModel.serverDisplayName)
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
        Section(.settingsAboutTitle) {
            SettingsRowLabel(
                title: .settingsAboutVersion,
                systemImage: "info",
                color: .gray,
                value: .verbatim(SettingsViewModel.versionString)
            )

            externalLink(.settingsAboutPrivacyPolicy, systemImage: "hand.raised.fill", SiloLegalLinks.privacyPolicy)

            NavigationLink {
                AcknowledgementsView()
            } label: {
                SettingsRowLabel(
                    title: .settingsAboutAcknowledgements,
                    systemImage: "curlybraces",
                    color: .indigo
                )
            }

            externalLink(
                .settingsAboutSourceCode,
                systemImage: "chevron.left.forwardslash.chevron.right",
                SiloLegalLinks.sourceCode
            )
        }
    }

    /// A row that opens a web page, with the same icon tile as the rows
    /// around it so every label in the section shares one leading edge. The
    /// arrow marks it as opening in the browser.
    private func externalLink(
        _ title: LocalizedStringResource,
        systemImage: String,
        _ destination: URL
    ) -> some View {
        Link(destination: destination) {
            HStack {
                SettingsRowLabel(title: title, systemImage: systemImage, color: .gray)
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.siloSecondaryText.opacity(0.6))
            }
            .contentShape(Rectangle())
        }
    }

    // MARK: - Sign Out

    private var signOutSection: some View {
        Section {
            // The router confirms first, naming the account and its downloads.
            Button(role: .destructive) {
                router.signOutAndReset()
            } label: {
                Text(.settingsSignOut)
                    .font(.siloBody.weight(.semibold))
                    .foregroundStyle(Color.siloErrorInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SiloTheme.smallPadding)
                    .background(
                        RoundedRectangle(cornerRadius: SiloTheme.cornerRadius, style: .continuous)
                            .fill(Color.siloErrorInk.opacity(0.12))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
    #endif
}

#if os(macOS)

// MARK: - Row primitives

/// Settings-app style row label: a colored rounded-square icon badge,
/// the row title, and an optional trailing value in secondary color.
struct SettingsRowLabel: View {
    let title: LocalizedStringResource
    let systemImage: String
    let color: Color
    var value: LocalizedStringResource? = nil

    /// The Mac keeps its chrome monochrome, so every tile is the same grey
    /// whatever `color` a row passes.
    private var tileFill: Color { .siloIconTile }

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
