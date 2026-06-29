#if os(tvOS)
import SwiftUI

/// Native tvOS settings root menu — modeled on Apple TV's own Settings
/// app: a short `Form` of drill-in category rows (with their current
/// value summarized on the trailing edge) instead of one giant wall of
/// controls. Each category opens a dedicated sub-screen.
///
/// **Why covers instead of push.** `TVMainTabView` wraps a
/// sidebar-adaptive `TabView` in a single outer `NavigationStack` bound
/// to `router.path`. On tvOS 26, `NavigationLink` /
/// `.pickerStyle(.navigationLink)` pushes from inside a tab's `Form`
/// don't reach that outer stack — they either silently do nothing or
/// queue behind the tab and only appear when the user exits Settings.
/// A local `NavigationStack` doesn't capture them either. Presenting
/// sub-screens via `.fullScreenCover(item:)` bypasses the ambiguity
/// (plain `.sheet` renders as a narrow centered card on tvOS 26 that
/// clips a `Form`); each cover hosts its own `NavigationStack` + `Form`.
///
/// `FocusAwareLabel` / `FocusAwareValueRow` / `FocusAwareAccountRow`
/// flip each row's foreground to `continuumBackground` on focus so the
/// inherited app-wide white `.tint` doesn't wash out text on the focus
/// platter.
struct TVSettingsView: View {
    @State private var viewModel = TVSettingsViewModel()
    @State private var showSignOutConfirm = false
    @State private var activeScreen: SubScreen?
    @Environment(AppRouter.self) private var router

    var body: some View {
        Form {
            accountSection
            preferencesSection
            accountActionsSection
            aboutSection
        }
        .task { await viewModel.load() }
        .fullScreenCover(item: $activeScreen) { screen in
            subScreen(for: screen)
        }
        .onChange(of: viewModel.editorSubtitleLanguage) { _, _ in
            Task { await viewModel.saveProfilePrefs() }
        }
        .onChange(of: viewModel.editorSubtitleMode) { _, _ in
            Task { await viewModel.saveProfilePrefs() }
        }
        .onChange(of: viewModel.editorShowForcedSubtitles) { _, _ in
            Task { await viewModel.saveProfilePrefs() }
        }
        .onChange(of: viewModel.editorPreferredMetadataLanguage) { _, _ in
            Task { await viewModel.saveMetadataLanguage() }
        }
        .alert("Sign Out", isPresented: $showSignOutConfirm) {
            Button("Sign Out", role: .destructive) {
                router.signOutAndReset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will be returned to the login screen.")
        }
    }

    // MARK: - Account header (tappable — switches profile)

    private var accountSection: some View {
        Section {
            Button(action: switchProfile) {
                FocusAwareAccountRow(
                    name: viewModel.displayName,
                    subtitle: viewModel.accountSubtitle,
                    avatar: viewModel.profileAvatar
                )
            }
        }
    }

    private func switchProfile() {
        AuthService.shared.profileId = nil
        router.showProfileSelection()
    }

    // MARK: - Preferences (drill-in categories)

    private var preferencesSection: some View {
        Section("Preferences") {
            Button { activeScreen = .general } label: {
                FocusAwareRowLabel(title: "General")
            }

            Button { activeScreen = .playback } label: {
                FocusAwareValueRow(
                    title: "Playback",
                    value: TVSettingsOptions.label(
                        for: viewModel.preferredQuality,
                        in: TVSettingsOptions.quality
                    )
                )
            }

            Button { activeScreen = .subtitles } label: {
                FocusAwareValueRow(
                    title: "Subtitles",
                    value: TVSettingsOptions.label(
                        for: viewModel.editorSubtitleLanguage,
                        in: TVSettingsOptions.subtitleLanguage
                    )
                )
            }
        }
    }

    // MARK: - Account actions

    private var accountActionsSection: some View {
        Section("Account") {
            Button(role: .destructive) {
                showSignOutConfirm = true
            } label: {
                FocusAwareLabel(
                    title: "Sign Out",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    isDestructive: true
                )
            }
        }
    }

    // MARK: - About / Server

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Server", value: viewModel.serverDisplayName.isEmpty
                ? "Not configured"
                : viewModel.serverDisplayName)

            if !viewModel.serverUrl.isEmpty,
               viewModel.serverDisplayName != viewModel.serverUrl {
                LabeledContent("URL", value: viewModel.serverUrl)
            }

            Button { router.navigate(to: .serverList) } label: {
                FocusAwareLabel(title: "Manage Servers", systemImage: "server.rack")
            }

            LabeledContent("Version", value: Self.appVersion)
        }
    }

    // MARK: - Sub-screens

    @ViewBuilder
    private func subScreen(for screen: SubScreen) -> some View {
        switch screen {
        case .general:
            TVGeneralSettingsView()
        case .playback:
            TVPlaybackSettingsView(viewModel: viewModel)
        case .subtitles:
            TVSubtitleSettingsView(viewModel: viewModel)
        }
    }

    enum SubScreen: String, Identifiable {
        case general
        case playback
        case subtitles

        var id: String { rawValue }
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
#endif
