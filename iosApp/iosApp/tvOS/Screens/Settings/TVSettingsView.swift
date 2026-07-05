#if os(tvOS)
import SwiftUI

/// Skyline-styled tvOS settings: a two-pane layout instead of a stock
/// full-width `Form`. The left rail holds the profile card, the category
/// list, and Sign Out; the right pane renders the focused category's
/// controls inline. The pane follows rail focus live (like the system
/// Settings app's split screens), so there is no drill-in navigation —
/// which also sidesteps the tvOS 26 push-from-tab-Form problem that used
/// to force every sub-screen through a `fullScreenCover`. Only option
/// pickers still present as covers (`TVSettingsPickerSheet`).
///
/// Focus model: one native graph. Each pane is a `.focusSection()`;
/// vertical movement stays in-pane and Left/Right bridges panes
/// geometrically. No manual focus mutation (see docs/tvos-focus.md).
struct TVSettingsView: View {
    @State private var viewModel = TVSettingsViewModel()
    @State private var showSignOutConfirm = false
    #if DEBUG
    @State private var debugSettings = TVDebugSettings.shared
    #endif
    @State private var selectedCategory: TVSettingsCategory = .general
    @FocusState private var railFocus: RailItem?
    @Environment(AppRouter.self) private var router

    var body: some View {
        HStack(alignment: .top, spacing: 64) {
            rail
                .frame(width: 430)
                .focusSection()

            detailPane
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaPadding(.horizontal, ContinuumTheme.Skyline.safeAreaX)
        .safeAreaPadding(.top, 64)
        .defaultFocus($railFocus, .category(selectedCategory))
        .task { await viewModel.load() }
        .onChange(of: railFocus) { _, focus in
            // The pane previews whatever category the rail focus rests on.
            // Profile / Sign Out keep the last category visible.
            if case .category(let category) = focus, category != selectedCategory {
                withAnimation(.easeOut(duration: ContinuumTheme.normalDuration)) {
                    selectedCategory = category
                }
            }
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

    // MARK: - Left rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.system(size: 44, weight: .bold))
                .foregroundColor(.continuumOnSurface)
                .padding(.leading, 20)
                .padding(.bottom, 26)

            profileRow
                .padding(.bottom, 22)

            ForEach(TVSettingsCategory.allCases) { category in
                categoryRow(category)
            }

            Spacer(minLength: 24)

            signOutRow

            Text("Silo \(Self.appVersion)")
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .tracking(1)
                .foregroundColor(.continuumSecondaryText.opacity(0.7))
                .padding(.leading, 20)
                .padding(.top, 10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.bottom, 24)
    }

    private var profileRow: some View {
        Button(action: switchProfile) {
            HStack(spacing: 18) {
                ProfileAvatarView(
                    avatar: viewModel.profileAvatar,
                    name: viewModel.displayName,
                    size: 68
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.displayName)
                        .font(.system(size: 27, weight: .semibold))
                        .lineLimit(1)
                    Text(viewModel.accountSubtitle)
                        .font(.system(size: 19))
                        .opacity(0.62)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .semibold))
                    .opacity(0.5)
            }
        }
        .buttonStyle(TVSettingsRailRowStyle())
        .focused($railFocus, equals: .profile)
    }

    private func categoryRow(_ category: TVSettingsCategory) -> some View {
        Button {
            selectedCategory = category
        } label: {
            HStack(spacing: 16) {
                Image(systemName: category.icon)
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 34)
                Text(category.title)
                    .font(.system(size: 27, weight: .medium))
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(TVSettingsRailRowStyle(isSelected: category == selectedCategory))
        .focused($railFocus, equals: .category(category))
    }

    private var signOutRow: some View {
        Button {
            showSignOutConfirm = true
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 34)
                Text("Sign Out")
                    .font(.system(size: 27, weight: .medium))
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(TVSettingsRailRowStyle(isDestructive: true))
        .focused($railFocus, equals: .signOut)
    }

    private func switchProfile() {
        AuthService.shared.profileId = nil
        router.showProfileSelection()
    }

    // MARK: - Detail pane

    private var detailPane: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                paneHeader

                paneContent
                    .padding(.top, 18)
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .padding(.bottom, 64)
        }
        // Rebuild the scroll view per category so it opens at the top.
        // Safe: selection only changes while focus is in the rail.
        .id(selectedCategory)
        .transition(.opacity)
    }

    private var paneHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(selectedCategory.eyebrow)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundColor(.continuumSecondaryText)

            Text(selectedCategory.title)
                .font(.system(size: 38, weight: .semibold))
                .foregroundColor(.continuumOnSurface)

            Text(selectedCategory.blurb)
                .font(.system(size: 20))
                .foregroundColor(.continuumSecondaryText)
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedCategory {
        case .general:
            TVGeneralSettingsPane()
        case .playback:
            TVPlaybackSettingsPane(viewModel: viewModel)
        case .subtitles:
            TVSubtitleSettingsPane(viewModel: viewModel)
        case .server:
            serverPane
        }
    }

    // MARK: - Server pane

    private var serverPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            TVSettingsSectionHeader("ACTIVE SERVER")

            TVSettingsInfoRow(
                title: "Server",
                value: viewModel.serverDisplayName.isEmpty
                    ? "Not configured"
                    : viewModel.serverDisplayName
            )

            if !viewModel.serverUrl.isEmpty,
               viewModel.serverDisplayName != viewModel.serverUrl {
                TVSettingsInfoRow(title: "Address", value: viewModel.serverUrl)
            }

            Button { router.navigate(to: .serverList) } label: {
                HStack(spacing: 16) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 22, weight: .medium))
                    Text("Manage Servers")
                        .font(.system(size: 26))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18, weight: .semibold))
                        .opacity(0.55)
                }
            }
            .buttonStyle(TVSettingsPaneRowStyle())

            TVSettingsSectionHeader("ABOUT")

            TVSettingsInfoRow(title: "App Version", value: Self.appVersion)

            #if DEBUG
            TVSettingsSectionHeader("DEBUGGING")

            TVSettingsToggleRow(
                title: "Show Focus Targets",
                isOn: debugSettings.showFocusTargets
            ) {
                debugSettings.setShowFocusTargets(!debugSettings.showFocusTargets)
            }

            TVSettingsFooter(
                "Overlays the predicted d-pad destination in each direction "
                    + "from the focused control. Stored on this Apple TV. "
                    + "Debug builds only."
            )
            #endif
        }
    }

    // MARK: - Rail model

    enum RailItem: Hashable {
        case profile
        case category(TVSettingsCategory)
        case signOut
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

// MARK: - Categories

enum TVSettingsCategory: String, CaseIterable, Identifiable {
    case general
    case playback
    case subtitles
    case server

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .playback: return "Playback"
        case .subtitles: return "Subtitles"
        case .server: return "Server"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .playback: return "play.rectangle"
        case .subtitles: return "captions.bubble"
        case .server: return "server.rack"
        }
    }

    var eyebrow: String {
        switch self {
        case .general, .playback, .subtitles: return "PREFERENCES"
        case .server: return "CONNECTION"
        }
    }

    var blurb: String {
        switch self {
        case .general:
            return "App-level options for this Apple TV."
        case .playback:
            return "Streaming quality and episode behavior for this Apple TV."
        case .subtitles:
            return "Language, behavior, and on-screen appearance."
        case .server:
            return "The Silo server this Apple TV is connected to."
        }
    }
}
#endif
