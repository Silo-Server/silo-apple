#if os(tvOS)
import SwiftUI

/// Skyline-styled tvOS settings: a two-pane layout instead of a stock
/// full-width `Form`. The left rail holds the account header, the category
/// list, and Sign Out; the right pane renders the focused category's
/// controls inline. The pane follows rail focus live (like the system
/// Settings app's split screens), so there is no drill-in navigation.
/// Option pickers mount as root overlays so their focus graph is fully
/// isolated.
///
/// Focus model: one native graph with one preferred owner. Each pane is a
/// `.focusSection()`; vertical movement stays in-pane and Left/Right bridges
/// panes natively. Both panes give their entry target user-initiated default
/// priority: Right enters the top detail row and Left returns to the selected
/// category, regardless of the detail row's vertical position. The outer scope
/// chooses the active pane for entry and modal restoration (see docs/tvos-focus.md).
struct TVSettingsView: View {
    @State private var viewModel = SettingsViewModel()
    @State private var diagnosticsModel = DiagnosticsViewModel()
    @State private var experimental = ExperimentalFeatures.shared
    @State private var showSignOutConfirm = false
    @State private var showPrivacyPolicy = false
    @State private var showOpenSourceAcknowledgements = false
    @State private var selectedCategory: TVSettingsCategory = .general
    @State private var activePicker: TVSettingsPickerRequest?
    @State private var pendingPickerFocus: TVSettingsDetailFocus?
    @State private var isRestoringDetailFocus = false
    @State private var isRestoringRailFocus = false
    @State private var preferredFocusOwner: FocusOwner = .rail
    @State private var preferredRailFocus: RailItem = .category(.general)
    @State private var preferredDetailFocus: TVSettingsDetailFocus = .top
    /// The Settings › Account and Server row whose action opened a
    /// confirmation; focus returns to it, or to the row that took its place.
    @State private var accountsReturnRow: TVAccountsSettingsRow?
    @State private var hasLoadedAccounts = false
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
                // Spec §5.6: names the account and its server, says it
                // affects everyone on this Apple TV, and offers Remove
                // Account.
                let copy = viewModel.signOutConfirmation
                TVSettingsConfirmationOverlay(
                    title: copy.title,
                    message: copy.message,
                    confirmTitle: copy.confirmTitle,
                    additionalDestructiveTitle: copy.additionalDestructiveTitle,
                    cancel: dismissSignOutConfirmation,
                    confirm: router.signOutAndReset,
                    additionalDestructiveAction: router.signOutRemoveAccountAndReset
                )
                .onDisappear(perform: restoreSignOutFocus)
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
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: showSignOutConfirm)
        .onAppear(perform: focusGeneralOnEntry)
        .task {
            await viewModel.loadSettings()
            hasLoadedAccounts = true
            await diagnosticsModel.load(profile: viewModel.activeProfile)
        }
        .onChange(of: isAccountsOverlayPresented) { _, presented in
            guard !presented, selectedCategory == .accountAndServer,
                  let row = accountsReturnRow, accountsRows.contains(row) else { return }
            restoreDetailFocus(to: .accounts(row))
        }
        .onChange(of: accountsRows) { before, after in
            guard let row = accountsReturnRow, !after.contains(row) else { return }
            accountsReturnRow = nil
            guard selectedCategory == .accountAndServer,
                  let next = TVFocusNeighbor.replacement(for: row, before: before, after: after) ?? after.first else { return }
            preferredFocusOwner = .detail
            preferredDetailFocus = .accounts(next)
            restoreDetailFocus(to: .accounts(next))
        }
        .onChange(of: railFocus) { _, focus in
            if let focus,
               !isModalPresented,
               !isRestoringDetailFocus,
               !isRestoringRailFocus {
                preferredFocusOwner = .rail
                preferredRailFocus = focus
            }

            // The pane previews whatever category the rail focus rests on.
            // Sign Out keeps the last category visible.
            if case .category(let category) = focus {
                preferredDetailFocus = initialDetailFocus(for: category)
                if category != selectedCategory {
                    withAnimation(.easeOut(duration: SiloTheme.normalDuration)) {
                        selectedCategory = category
                    }
                }
            }
        }
        .onChange(of: detailFocus) { _, focus in
            if let focus,
               !isModalPresented,
               !isRestoringDetailFocus,
               !isRestoringRailFocus {
                preferredDetailFocus = focus
                preferredFocusOwner = .detail
            }
        }
        .onChange(of: diagnosticsModel.shouldShowSettings) { _, isVisible in
            if !isVisible, selectedCategory == .diagnostics {
                selectedCategory = .general
            }
        }
    }

    /// A picker, confirmation, or full-screen overlay owns focus.
    private var isModalPresented: Bool {
        activePicker != nil || showSignOutConfirm || showPrivacyPolicy || showOpenSourceAcknowledgements
            || isAccountsOverlayPresented
    }

    /// A confirmation from the app's presenter, raised by Settings ›
    /// Accounts.
    private var isAccountsOverlayPresented: Bool {
        router.removalRequest != nil
    }

    /// Settings always enters through General. Assign the concrete rail focus
    /// before tvOS performs its first geometric resolution, then re-assert it
    /// once the two focus scopes have mounted so no other row paints a
    /// simultaneous entry highlight.
    private func focusGeneralOnEntry() {
        selectedCategory = .general
        preferredFocusOwner = .rail
        preferredRailFocus = .category(.general)
        preferredDetailFocus = .generalAppleTVUser
        detailFocus = nil
        railFocus = .category(.general)

        Task { @MainActor in
            await Task.yield()
            guard !isModalPresented else { return }
            resetFocus(in: settingsFocusScope)
            resetFocus(in: railFocusScope)
            railFocus = .category(.general)
        }
    }

    private var settingsContent: some View {
        HStack(alignment: .top, spacing: 52) {
            rail
                .padding(.vertical, 24)
                .frame(width: 490)
                .disabled(isModalPresented || isRestoringDetailFocus)
                .defaultFocus(
                    $railFocus,
                    preferredFocusOwner == .detail ? .category(selectedCategory) : preferredRailFocus,
                    priority: .userInitiated
                )
                .prefersDefaultFocus(preferredFocusOwner == .rail, in: settingsFocusScope)
                .focusSection()
                .focusScope(railFocusScope)
                .onExitCommand(perform: exitSettingsToHome)

            detailPane
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .disabled(isModalPresented || isRestoringRailFocus)
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
        .safeAreaPadding(.horizontal, SiloTheme.Skyline.safeAreaX)
        .safeAreaPadding(.top, 48)
        .safeAreaPadding(.bottom, 44)
    }

    // MARK: - Left rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(Color.siloOnSurface)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)

            accountHeader
                .padding(.bottom, 22)

            ForEach(visibleCategories) { category in
                categoryRow(category)
            }

            Spacer(minLength: 24)

            signOutRow

            Text("Silo \(Self.versionString)")
                .font(.system(size: 18))
                .foregroundColor(.siloSecondaryText.opacity(0.7))
                .padding(.leading, 20)
                .padding(.top, 10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.bottom, 24)
    }

    /// The open account: its username, email, and server. Not a button:
    /// Who's Watching and Switch Account are elsewhere.
    private var accountHeader: some View {
        let header = viewModel.accountHeader
        return HStack(spacing: 18) {
            ProfileAvatarView(avatar: nil, imageUrl: nil, name: header.name, size: 68)

            VStack(alignment: .leading, spacing: 3) {
                Text(header.name)
                    .font(.system(size: 27, weight: .semibold))
                    .lineLimit(1)
                ForEach(header.detailLines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 19))
                        .opacity(0.62)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.siloOnSurface)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
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

    private func enterDetailPane(for category: TVSettingsCategory) {
        selectedCategory = category
        preferredFocusOwner = .detail
        let initialFocus = initialDetailFocus(for: category)
        preferredDetailFocus = initialFocus
        restoreDetailFocus(to: initialFocus)
        railFocus = nil
        detailFocus = initialFocus
    }

    /// Re-asserts `target` once the pane or overlay change has committed,
    /// holding `isRestoringDetailFocus` while the focus engine settles.
    private func restoreDetailFocus(to target: TVSettingsDetailFocus) {
        isRestoringDetailFocus = true
        Task { @MainActor in
            await Task.yield()
            resetFocus(in: settingsFocusScope)
            resetFocus(in: detailFocusScope)
            detailFocus = target
            try? await Task.sleep(for: .milliseconds(120))
            isRestoringDetailFocus = false
        }
    }

    private func initialDetailFocus(for category: TVSettingsCategory) -> TVSettingsDetailFocus {
        if category == .general {
            return .generalAppleTVUser
        }
        if category == .accountAndServer {
            return accountsRows.first.map(TVSettingsDetailFocus.accounts) ?? .serverPrivacyPolicy
        }
        if category == .subtitles,
           viewModel.prefs.serverUpgradeRequired || viewModel.subtitleMatchesSystemAppearance {
            return .subtitleUseDeviceSettings
        }
        return .top
    }

    private func returnFocusToRail() {
        guard !isModalPresented, !isRestoringDetailFocus else { return }
        preferredFocusOwner = .rail
        preferredRailFocus = .category(selectedCategory)
        detailFocus = nil
        railFocus = .category(selectedCategory)
        resetFocus(in: railFocusScope)
    }

    private func dismissSignOutConfirmation() {
        preferredFocusOwner = .rail
        preferredRailFocus = .signOut
        isRestoringRailFocus = true
        showSignOutConfirm = false
        railFocus = nil
    }

    private func restoreSignOutFocus() {
        guard isRestoringRailFocus else { return }
        // Restore after the confirmation's focus subtree has left, ignoring
        // transient rail focus while the dismissal animation completes.
        Task { @MainActor in
            await Task.yield()
            resetFocus(in: railFocusScope)
            railFocus = .signOut
            try? await Task.sleep(for: .milliseconds(120))
            isRestoringRailFocus = false
        }
    }

    private func presentPrivacyPolicy() {
        preferredFocusOwner = .detail
        preferredDetailFocus = .serverPrivacyPolicy
        railFocus = nil
        detailFocus = nil
        withAnimation(.easeOut(duration: SiloTheme.fastDuration)) {
            showPrivacyPolicy = true
        }
    }

    private func dismissPrivacyPolicy() {
        withAnimation(.easeOut(duration: SiloTheme.fastDuration)) {
            showPrivacyPolicy = false
        }
        preferredFocusOwner = .detail
        preferredDetailFocus = .serverPrivacyPolicy
        restoreDetailFocus(to: .serverPrivacyPolicy)
    }

    private func presentOpenSourceAcknowledgements() {
        preferredFocusOwner = .detail
        preferredDetailFocus = .serverOpenSourceLicenses
        railFocus = nil
        detailFocus = nil
        withAnimation(.easeOut(duration: SiloTheme.fastDuration)) {
            showOpenSourceAcknowledgements = true
        }
    }

    private func dismissOpenSourceAcknowledgements() {
        withAnimation(.easeOut(duration: SiloTheme.fastDuration)) {
            showOpenSourceAcknowledgements = false
        }
        preferredFocusOwner = .detail
        preferredDetailFocus = .serverOpenSourceLicenses
        restoreDetailFocus(to: .serverOpenSourceLicenses)
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

    /// TVMainTabView routes `.home` through `selectRoot`, which already pops
    /// to root; popping here as well would pop twice.
    private func exitSettingsToHome() {
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
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(
                    Color.siloIconTile,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(selectedCategory.title)
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(Color.siloOnSurface)

                Text(selectedCategory.blurb)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.siloSecondaryText)
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
                pairedProfileValue: viewModel.pairedProfileValue,
                pairedAccountLine: viewModel.pairedAccountLine,
                hasMultipleAccounts: viewModel.showsAskFor,
                detailFocus: $detailFocus,
                // With two or more accounts this goes through Choose an
                // Account.
                changePairedProfile: { Task { await router.accounts.changePairedProfile(router: router) } }
            )
        case .accountAndServer:
            // The accounts sit in the pane itself, like every other setting
            // here, with the open account's server and the app below them.
            VStack(alignment: .leading, spacing: 8) {
                TVAccountsSettingsSection(
                    model: accountsModel,
                    phase: TVUserListPhase(directory: router.accounts.directory, hasLoaded: hasLoadedAccounts),
                    addresses: Dictionary(router.accounts.directory.accounts.map { ($0.id, $0.serverAddress) },
                                          uniquingKeysWith: { first, _ in first }),
                    focus: $detailFocus,
                    actions: accountsActions
                )
                serverSections
            }
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
        }
    }

    // MARK: - Server and app

    /// Under the accounts: the open account's server, and about this app.
    private var serverSections: some View {
        VStack(alignment: .leading, spacing: 8) {
            TVSettingsSectionHeader("SERVER")

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
                    Text("Acknowledgements")
                        .font(.system(size: 26))
                    Spacer(minLength: 0)
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .opacity(0.55)
                }
            }
            .buttonStyle(TVSettingsPaneRowStyle())
            .focused($detailFocus, equals: .serverOpenSourceLicenses)

            TVSettingsSectionHeader("EXTRA FEATURES")

            ForEach(ExperimentalFeature.allCases) { feature in
                TVSettingsToggleRow(
                    title: feature.title,
                    isOn: experimental.isEnabled(feature)
                ) {
                    feature.setEnabled(!experimental.isEnabled(feature))
                }
                .focused($detailFocus, equals: .serverExperimental(feature))
            }
        }
    }

    // MARK: - Accounts pane

    private var accountsModel: AccountsSettingsViewModel {
        AccountsSettingsViewModel(directory: router.accounts.directory, device: router.accounts.device)
    }

    private var accountsRows: [TVAccountsSettingsRow] {
        TVAccountsSettingsSection.rows(in: accountsModel)
    }

    private var accountsActions: TVAccountsSettingsSection.Actions {
        TVAccountsSettingsSection.Actions(
            signOut: { account, row in
                noteAccountsAction(row)
                Task { await router.accounts.requestRemoval(.signOut(account), router: router) }
            },
            signInAgain: { account in
                Task { await router.accounts.openAccount(account, router: router) }
            },
            remove: { account, row in
                noteAccountsAction(row)
                Task { await router.accounts.requestRemoval(.remove(account), router: router) }
            },
            addAccount: { Task { await router.accounts.startAddAccount(router: router) } }
        )
    }

    /// The overlay takes focus; remember the row so it comes back here.
    private func noteAccountsAction(_ row: TVAccountsSettingsRow) {
        accountsReturnRow = row
        preferredFocusOwner = .detail
        preferredDetailFocus = .accounts(row)
    }

    // MARK: - Rail model

    enum RailItem: Hashable {
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

    private static let versionString: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        guard let build = info?["CFBundleVersion"] as? String,
              !build.isEmpty,
              build != version else {
            return version
        }
        return "\(version) (\(build))"
    }()
}

enum TVSettingsDetailFocus: Hashable {
    case top
    case generalAppleTVUser
    case generalProfileLaunch
    case generalAskFor
    case generalAdvisoryAge
    case generalCardPreset
    case generalTopMenu
    case playbackMaxBitrate
    case playbackAudioLanguage
    case playbackBufferAhead
    case playbackDeinterlaceMode
    case playbackDeinterlaceFieldRate
    case playbackNextUpPrompt
    case playbackIntroSkipMode
    case playbackAutoPlayNext
    case playbackSkipCredits
    case playbackVideoSkipBack
    case playbackVideoSkipForward
    case playbackAudiobookSkipBack
    case playbackAudiobookSkipForward
    case subtitleBehavior
    case subtitleUseDeviceSettings
    case subtitleMetadataLanguage
    case subtitleFontSize
    case subtitleFontFamily
    case subtitleFontColor
    case subtitleTextOpacity
    case subtitleOutlineColor
    case subtitleBackgroundStyle
    case subtitleBackgroundOpacity
    case subtitleBackgroundColor
    case subtitlePosition
    case serverPrivacyPolicy
    case serverOpenSourceLicenses
    case serverExperimental(ExperimentalFeature)
    case accounts(TVAccountsSettingsRow)
}

// MARK: - Categories

enum TVSettingsCategory: String, CaseIterable, Identifiable {
    case general
    case playback
    case subtitles
    case diagnostics
    case accountAndServer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .playback: return "Playback"
        case .subtitles: return "Subtitles"
        case .diagnostics: return "Diagnostics"
        case .accountAndServer: return "Account and Server"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .playback: return "play.rectangle"
        case .subtitles: return "captions.bubble"
        case .diagnostics: return "stethoscope"
        case .accountAndServer: return "person.2"
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
        case .accountAndServer:
            return "Silo accounts on this Apple TV, the server of the one open now, and this app's version."
        }
    }

    var railDescription: String {
        switch self {
        case .general: return "App and navigation"
        case .playback: return "Quality and episodes"
        case .subtitles: return "Language and appearance"
        case .diagnostics: return "Reports and support"
        case .accountAndServer: return "Accounts, server, and version"
        }
    }

}
#endif
