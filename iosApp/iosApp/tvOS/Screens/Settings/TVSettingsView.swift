#if os(tvOS)
import SwiftUI

/// Skyline-styled tvOS settings: a two-pane layout instead of a stock
/// full-width `Form`. The left rail holds the profile card, the category
/// list, and Sign Out; the right pane renders the focused category's
/// controls inline. The pane follows rail focus live (like the system
/// Settings app's split screens), so there is no drill-in navigation —
/// which also sidesteps the tvOS 26 push-from-tab-Form problem that used
/// to force every sub-screen through a `fullScreenCover`. Option pickers
/// mount as root overlays so their focus graph is fully isolated.
///
/// Focus model: one native graph with one preferred owner. Each pane is a
/// `.focusSection()`; vertical movement stays in-pane and Left/Right bridges
/// panes natively. The detail pane gives its preferred row user-initiated
/// default priority so it wins the initial cross-pane focus resolution before
/// geometric proximity can select a lower row. The outer scope still chooses
/// the active pane for page entry and modal restoration (see docs/tvos-focus.md).
struct TVSettingsView: View {
    @State private var viewModel = TVSettingsViewModel()
    @State private var diagnosticsModel = DiagnosticsViewModel()
    @State private var showSignOutConfirm = false
    @State private var showPrivacyPolicy = false
    @State private var showOpenSourceAcknowledgements = false
    @State private var selectedCategory: TVSettingsCategory = .general
    @State private var activePicker: TVSettingsPickerRequest?
    @State private var pendingPickerFocus: TVSettingsDetailFocus?
    @State private var isRestoringDetailFocus = false
    @State private var preferredFocusOwner: FocusOwner = .rail
    @State private var preferredDetailFocus: TVSettingsDetailFocus = .top
    @FocusState private var railFocus: RailItem?
    @FocusState private var detailFocus: TVSettingsDetailFocus?
    @Environment(\.resetFocus) private var resetFocus
    @Namespace private var settingsFocusScope
    @Namespace private var railFocusScope
    @Namespace private var detailFocusScope
    @Environment(AppRouter.self) private var router

    var body: some View {
        ZStack {
            SettingsBackdrop()

            settingsContent

            if showSignOutConfirm {
                TVSettingsConfirmationOverlay(
                    title: "Sign Out",
                    message: "Choose whether to keep or remove this server from this Apple TV.",
                    confirmTitle: "Sign Out",
                    additionalDestructiveTitle: "Sign Out & Remove Server",
                    cancel: dismissSignOutConfirmation,
                    confirm: router.signOutAndReset,
                    additionalDestructiveAction: router.signOutRemoveServerAndReset
                )
                .transition(.opacity)
                .zIndex(1)
            }

            if let activePicker {
                TVSettingsPickerSheet(
                    title: activePicker.title,
                    options: activePicker.options,
                    selection: activePicker.selection,
                    subtitlePreviewAppearance: activePicker.subtitlePreviewAppearance,
                    onDismiss: dismissPicker
                )
                .onDisappear(perform: restorePickerFocus)
                .zIndex(2)
            }

            if showPrivacyPolicy {
                TVPrivacyPolicyOverlay(dismiss: dismissPrivacyPolicy)
                    .transition(.opacity)
                    .zIndex(3)
            }

            if showOpenSourceAcknowledgements {
                TVOpenSourceAcknowledgementsOverlay(
                    dismiss: dismissOpenSourceAcknowledgements
                )
                .transition(.opacity)
                .zIndex(4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: showSignOutConfirm)
        .task {
            await viewModel.load()
            await diagnosticsModel.load(profile: viewModel.activeProfile)
        }
        .onChange(of: railFocus) { _, focus in
            if focus != nil,
               activePicker == nil,
               !showSignOutConfirm,
               !showPrivacyPolicy,
               !showOpenSourceAcknowledgements,
               !isRestoringDetailFocus {
                preferredFocusOwner = .rail
            }

            // The pane previews whatever category the rail focus rests on.
            // Profile / Sign Out keep the last category visible.
            if case .category(let category) = focus {
                preferredDetailFocus = initialDetailFocus(for: category)
                if category != selectedCategory {
                    withAnimation(.easeOut(duration: ContinuumTheme.normalDuration)) {
                        selectedCategory = category
                    }
                }
            }
        }
        .onChange(of: detailFocus) { _, focus in
            if let focus,
               activePicker == nil,
               !showSignOutConfirm,
               !showPrivacyPolicy,
               !showOpenSourceAcknowledgements,
               !isRestoringDetailFocus {
                preferredDetailFocus = focus
                preferredFocusOwner = .detail
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
        .onChange(of: diagnosticsModel.shouldShowSettings) { _, isVisible in
            if !isVisible, selectedCategory == .diagnostics {
                selectedCategory = .general
            }
        }
    }

    private var settingsContent: some View {
        HStack(alignment: .top, spacing: 52) {
            rail
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 26)
                        .fill(Color.continuumSurface.opacity(0.74))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 26)
                        .strokeBorder(Color.continuumOutline, lineWidth: 1)
                }
                .frame(width: 490)
                .disabled(
                    showSignOutConfirm
                        || showPrivacyPolicy
                        || showOpenSourceAcknowledgements
                        || activePicker != nil
                        || isRestoringDetailFocus
                )
                .defaultFocus(
                    $railFocus,
                    .category(selectedCategory),
                    priority: preferredFocusOwner == .rail ? .userInitiated : .automatic
                )
                .prefersDefaultFocus(preferredFocusOwner == .rail, in: settingsFocusScope)
                .focusSection()
                .focusScope(railFocusScope)
                .onExitCommand(perform: exitSettingsToHome)

            detailPane
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .disabled(
                    showSignOutConfirm
                        || showPrivacyPolicy
                        || showOpenSourceAcknowledgements
                        || activePicker != nil
                )
                .defaultFocus(
                    $detailFocus,
                    preferredDetailFocus,
                    priority: .userInitiated
                )
                .prefersDefaultFocus(preferredFocusOwner == .detail, in: settingsFocusScope)
                .focusSection()
                .focusScope(detailFocusScope)
                .onExitCommand(perform: returnFocusToRail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusScope(settingsFocusScope)
        .safeAreaPadding(.horizontal, ContinuumTheme.Skyline.safeAreaX)
        .safeAreaPadding(.top, 48)
        .safeAreaPadding(.bottom, 44)
    }

    // MARK: - Left rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Settings")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(Color.continuumOnSurface)

                Text("Make Silo work the way you like.")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.continuumSecondaryText)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            profileRow
                .padding(.bottom, 22)

            ForEach(visibleCategories) { category in
                categoryRow(category)
            }

            Spacer(minLength: 24)

            signOutRow

            Text("Silo \(Self.versionString)")
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
                    imageUrl: viewModel.profileAvatarImageUrl,
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
            enterDetailPane(for: category)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: category.icon)
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                        .font(.system(size: 25, weight: .medium))

                    Text(category.railDescription)
                        .font(.system(size: 16))
                        .opacity(0.62)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
        }
        .buttonStyle(TVSettingsRailRowStyle(
            isSelected: category == selectedCategory && railFocus != .signOut
        ))
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
        router.switchProfile()
    }

    private func enterDetailPane(for category: TVSettingsCategory) {
        selectedCategory = category
        preferredFocusOwner = .detail
        let initialFocus = initialDetailFocus(for: category)
        preferredDetailFocus = initialFocus
        isRestoringDetailFocus = true
        railFocus = nil
        detailFocus = initialFocus
        Task { @MainActor in
            await Task.yield()
            resetFocus(in: settingsFocusScope)
            resetFocus(in: detailFocusScope)
            detailFocus = initialFocus
            try? await Task.sleep(for: .milliseconds(120))
            isRestoringDetailFocus = false
        }
    }

    private func initialDetailFocus(for category: TVSettingsCategory) -> TVSettingsDetailFocus {
        if category == .general {
            return .generalAppleTVUser
        }
        if category == .subtitles,
           viewModel.settingsServerUpgradeRequired || viewModel.subtitleMatchesSystemAppearance {
            return .subtitleUseDeviceSettings
        }
        return .top
    }

    private func returnFocusToRail() {
        guard activePicker == nil,
              !showSignOutConfirm,
              !showPrivacyPolicy,
              !showOpenSourceAcknowledgements,
              !isRestoringDetailFocus else {
            return
        }
        preferredFocusOwner = .rail
        detailFocus = nil
        railFocus = .category(selectedCategory)
        resetFocus(in: railFocusScope)
    }

    private func dismissSignOutConfirmation() {
        showSignOutConfirm = false
        preferredFocusOwner = .rail
        railFocus = .signOut
        Task { @MainActor in
            await Task.yield()
            resetFocus(in: railFocusScope)
            railFocus = .signOut
        }
    }

    private func presentPrivacyPolicy() {
        preferredFocusOwner = .detail
        preferredDetailFocus = .serverPrivacyPolicy
        railFocus = nil
        detailFocus = nil
        withAnimation(.easeOut(duration: ContinuumTheme.fastDuration)) {
            showPrivacyPolicy = true
        }
    }

    private func dismissPrivacyPolicy() {
        withAnimation(.easeOut(duration: ContinuumTheme.fastDuration)) {
            showPrivacyPolicy = false
        }
        preferredFocusOwner = .detail
        preferredDetailFocus = .serverPrivacyPolicy
        isRestoringDetailFocus = true
        Task { @MainActor in
            await Task.yield()
            resetFocus(in: settingsFocusScope)
            resetFocus(in: detailFocusScope)
            detailFocus = .serverPrivacyPolicy
            try? await Task.sleep(for: .milliseconds(120))
            isRestoringDetailFocus = false
        }
    }

    private func presentOpenSourceAcknowledgements() {
        preferredFocusOwner = .detail
        preferredDetailFocus = .serverOpenSourceLicenses
        railFocus = nil
        detailFocus = nil
        withAnimation(.easeOut(duration: ContinuumTheme.fastDuration)) {
            showOpenSourceAcknowledgements = true
        }
    }

    private func dismissOpenSourceAcknowledgements() {
        withAnimation(.easeOut(duration: ContinuumTheme.fastDuration)) {
            showOpenSourceAcknowledgements = false
        }
        preferredFocusOwner = .detail
        preferredDetailFocus = .serverOpenSourceLicenses
        isRestoringDetailFocus = true
        Task { @MainActor in
            await Task.yield()
            resetFocus(in: settingsFocusScope)
            resetFocus(in: detailFocusScope)
            detailFocus = .serverOpenSourceLicenses
            try? await Task.sleep(for: .milliseconds(120))
            isRestoringDetailFocus = false
        }
    }

    private func presentPicker(_ request: TVSettingsPickerRequest) {
        // Remove every underlying focus candidate in the same update that
        // mounts the modal. The picker then becomes the sole focus owner.
        preferredFocusOwner = .detail
        preferredDetailFocus = request.returnFocus
        railFocus = nil
        detailFocus = nil
        activePicker = request
    }

    private func dismissPicker() {
        guard let target = activePicker?.returnFocus else {
            activePicker = nil
            return
        }

        // Keep the rail out of the graph while SwiftUI removes the modal.
        // The exact row is restored from the overlay's onDisappear callback,
        // after its focus subtree has actually left the hierarchy.
        preferredFocusOwner = .detail
        preferredDetailFocus = target
        pendingPickerFocus = target
        isRestoringDetailFocus = true
        activePicker = nil
    }

    private func restorePickerFocus() {
        guard let target = pendingPickerFocus else { return }

        preferredFocusOwner = .detail
        preferredDetailFocus = target
        railFocus = nil
        detailFocus = nil
        resetFocus(in: settingsFocusScope)
        Task { @MainActor in
            await Task.yield()
            railFocus = nil
            resetFocus(in: settingsFocusScope)
            await Task.yield()
            detailFocus = nil
            await Task.yield()
            detailFocus = target
            try? await Task.sleep(for: .milliseconds(120))
            pendingPickerFocus = nil
            isRestoringDetailFocus = false
        }
    }

    private func exitSettingsToHome() {
        router.popToRoot()
        router.switchTab(to: .home)
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
        // Keep focused row scaling and shadows inside a deliberate gutter
        // instead of letting the scroll view trim their rounded edges.
        .contentMargins(.horizontal, 18, for: .scrollContent)
        .scrollClipDisabled()
        // Rebuild the scroll view per category so it opens at the top.
        // Safe: selection only changes while focus is in the rail.
        .id(selectedCategory)
        .transition(.opacity)
    }

    private var paneHeader: some View {
        HStack(alignment: .center, spacing: 20) {
            Image(systemName: selectedCategory.icon)
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(selectedCategory.tint)
                .frame(width: 62, height: 62)
                .background(selectedCategory.tint.opacity(0.13), in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(selectedCategory.tint.opacity(0.22), lineWidth: 1)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text(selectedCategory.eyebrow)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(selectedCategory.tint)

                Text(selectedCategory.title)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(Color.continuumOnSurface)

                Text(selectedCategory.blurb)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.continuumSecondaryText)
            }
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedCategory {
        case .general:
            TVGeneralSettingsPane(
                activeProfile: viewModel.activeProfile,
                detailFocus: $detailFocus,
                changePairedProfile: switchProfile
            )
        case .playback:
            TVPlaybackSettingsPane(
                viewModel: viewModel,
                detailFocus: $detailFocus,
                presentPicker: presentPicker
            )
        case .subtitles:
            TVSubtitleSettingsPane(
                viewModel: viewModel,
                detailFocus: $detailFocus,
                presentPicker: presentPicker
            )
        case .diagnostics:
            TVDiagnosticsSettingsPane(model: diagnosticsModel, detailFocus: $detailFocus)
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
            .focused($detailFocus, equals: .top)

            TVSettingsSectionHeader("ABOUT")

            TVSettingsInfoRow(title: "App Version", value: Self.versionString)

            Button(action: presentPrivacyPolicy) {
                HStack(spacing: 16) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 22, weight: .medium))
                    Text("Privacy Policy")
                        .font(.system(size: 26))
                    Spacer(minLength: 0)
                    Image(systemName: "qrcode")
                        .font(.system(size: 18, weight: .semibold))
                        .opacity(0.55)
                }
            }
            .buttonStyle(TVSettingsPaneRowStyle())
            .focused($detailFocus, equals: .serverPrivacyPolicy)

            Button(action: presentOpenSourceAcknowledgements) {
                HStack(spacing: 16) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 22, weight: .medium))
                    Text("Open Source Licenses")
                        .font(.system(size: 26))
                    Spacer(minLength: 0)
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .opacity(0.55)
                }
            }
            .buttonStyle(TVSettingsPaneRowStyle())
            .focused($detailFocus, equals: .serverOpenSourceLicenses)
        }
    }

    // MARK: - Rail model

    enum RailItem: Hashable {
        case profile
        case category(TVSettingsCategory)
        case signOut
    }

    private enum FocusOwner {
        case rail
        case detail
    }

    private var visibleCategories: [TVSettingsCategory] {
        TVSettingsCategory.allCases.filter { category in
            category != .diagnostics || diagnosticsModel.shouldShowSettings
        }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        guard let build = info?["CFBundleVersion"] as? String,
              !build.isEmpty,
              build != version else {
            return version
        }
        return "\(version) (\(build))"
    }
}

enum TVSettingsDetailFocus: Hashable {
    case top
    case generalAppleTVUser
    case generalProfileLaunch
    case generalCardPreset
    case generalTopMenu
    case playbackAudioLanguage
    case playbackBufferAhead
    case playbackDeinterlaceMode
    case playbackDeinterlaceFieldRate
    case playbackNextUpPrompt
    case subtitleBehavior
    case subtitleUseDeviceSettings
    case subtitleMetadataLanguage
    case subtitleFontSize
    case subtitleFontFamily
    case subtitleFontColor
    case subtitleOutlineColor
    case subtitleBackgroundStyle
    case subtitleBackgroundOpacity
    case subtitleBackgroundColor
    case subtitlePosition
    case serverPrivacyPolicy
    case serverOpenSourceLicenses
}

// MARK: - Categories

enum TVSettingsCategory: String, CaseIterable, Identifiable {
    case general
    case playback
    case subtitles
    case diagnostics
    case server

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .playback: return "Playback"
        case .subtitles: return "Subtitles"
        case .diagnostics: return "Diagnostics"
        case .server: return "Server"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .playback: return "play.rectangle"
        case .subtitles: return "captions.bubble"
        case .diagnostics: return "stethoscope"
        case .server: return "server.rack"
        }
    }

    var eyebrow: String {
        switch self {
        case .general, .playback, .subtitles: return "PREFERENCES"
        case .diagnostics: return "SUPPORT"
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
        case .diagnostics:
            return "Review and send diagnostics to this Silo server."
        case .server:
            return "The Silo server this Apple TV is connected to."
        }
    }

    var railDescription: String {
        switch self {
        case .general: return "App and navigation"
        case .playback: return "Quality and episodes"
        case .subtitles: return "Language and appearance"
        case .diagnostics: return "Reports and support"
        case .server: return "Connection and version"
        }
    }

    var tint: Color {
        switch self {
        case .general, .playback, .subtitles:
            return .continuumAccent
        case .diagnostics:
            return .orange
        case .server:
            return .teal
        }
    }
}
#endif
