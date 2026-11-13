import SwiftUI

/// "Who's watching?" profile picker over the shared backdrop.
struct ProfileSelectionView: View {
    @Environment(\.locale) private var locale
    var router: AppRouter
    @State private var viewModel = ProfileSelectionViewModel()
    @State private var launchPreferences = ProfileLaunchPreferences.shared
    @State private var pinEntryContext: PINEntryContext?
    @State private var wrongPINCount = 0
    @State private var pinError: String?
    @State private var isVerifyingPIN = false
    @State private var showCreateProfile: Bool = false
    /// The profile under a finger, then the one being opened; either tints
    /// the backdrop with that profile's color.
    @State private var pressedProfileID: String?
    @State private var selectingProfileID: String?
    /// The person asked for this picker (Switch Profile), so it shows even
    /// when there is only one profile to choose.
    @State private var requestedByPerson = false
    /// Whether the picker has settled what it shows. Until then an account
    /// whose only profile has no PIN draws the loading state instead of its
    /// tile, so a picker that opens that profile is never drawn (spec §4.2).
    @State private var hasSettled: Bool
    #if !os(tvOS)
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    #endif
    #if os(tvOS)
    /// A control on the picker. Focus is written only to seed the picker and
    /// to put it back once something that covered it closes; the focus
    /// engine owns movement (docs/tvos-focus.md).
    private enum PickerFocus: Hashable {
        case profile(String)
        case add
        case changeAccount
        case signOut
    }

    @FocusState private var pickerFocus: PickerFocus?
    /// The control that opened the PIN prompt, Create Profile or the
    /// sign-out confirmation, so focus goes back to it when that
    /// closes rather than to the first profile.
    @State private var returnFocus: PickerFocus?
    @Environment(\.isStartupSplashVisible) private var isStartupSplashVisible
    #endif

    private enum PINEntryPurpose: String {
        case profileSelection
        case profileManagement
    }

    private struct PINEntryContext: Identifiable {
        let profile: UserProfile
        let purpose: PINEntryPurpose

        var id: String {
            "\(purpose.rawValue)-\(profile.id)"
        }
    }

    private var isPINEntryPresented: Bool {
        pinEntryContext != nil
    }

    init(router: AppRouter) {
        self.router = router
        // A picker the person asked for shows even a single profile, at once.
        _hasSettled = State(initialValue: router.pickerRequestedByPerson && !router.skipsSingleProfilePicker)
    }

    var body: some View {
        ZStack {
            background

            pickerContent
                .disabled(viewModel.isClearingTemporaryManagementContext || isPINEntryPresented)
                .accessibilityHidden(isPINEntryPresented)
                .opacity(isPINEntryPresented ? 0 : 1)
        }
        .animation(.easeInOut(duration: 0.25), value: isPINEntryPresented)
        .task {
            MarqueeScene.shared.showActiveServer()
            MarqueeScene.shared.focus = .profiles
            requestedByPerson = router.pickerRequestedByPerson
            router.pickerRequestedByPerson = false
            async let account: Void = viewModel.loadAccount()
            await loadProfilesAndSettle()
            await account
        }
        .onChange(of: viewModel.requiresPasswordChange) { _, required in
            if required { router.showPasswordChange() }
        }
        .onChange(of: tintedProfileID) { _, id in
            MarqueeScene.shared.personalTint = id.map { ProfileTilePalette.tint(for: $0) }
        }
        .marqueeTransparentNavigation()
        .overlay {
            profileOverlay
        }
        #if os(tvOS)
        .fullScreenCover(isPresented: $showCreateProfile, onDismiss: handleCreateProfileDismissed) {
            CreateProfileView {
                showCreateProfile = false
                Task { await viewModel.loadProfiles() }
            }
        }
        #else
        .sheet(isPresented: $showCreateProfile, onDismiss: handleCreateProfileDismissed) {
            CreateProfileView {
                showCreateProfile = false
                Task { await viewModel.loadProfiles() }
            }
            .presentationDetents([.large])
        }
        #endif
        .sensoryFeedback(.error, trigger: wrongPINCount)
        #if os(tvOS)
        .defaultFocus($pickerFocus, defaultPickerFocus)
        .onAppear {
            if acceptsFocus { restoreFocus() }
        }
        .onChange(of: acceptsFocus) { _, accepts in
            if accepts { restoreFocus() }
        }
        .alert(
            Text(rememberOfferTitle),
            isPresented: Binding(
                get: { viewModel.rememberOffer != nil },
                // Only the buttons answer: Menu runs the cancel button's action.
                set: { _ in }
            )
        ) {
            Button(.launchOfferRemember) {
                viewModel.answerRememberOffer(remember: true, router: router)
            }
            Button(.launchOfferAsk, role: .cancel) {
                viewModel.answerRememberOffer(remember: false, router: router)
            }
        } message: {
            Text(.profilesRememberOfferBodyAppleTv)
        }
        #endif
    }

    #if os(tvOS)
    private var rememberOfferTitle: LocalizedStringResource {
        guard let name = viewModel.rememberOffer?.name else { return .profilesRememberOfferTitleUnnamed }
        return .launchOfferTitle(name)
    }

    /// The picker's controls are on screen and nothing covers them: not the
    /// startup splash (a cold launch builds the picker underneath it, where
    /// nothing can take focus), the PIN prompt, Create Profile, or the
    /// sign-out confirmation.
    private var acceptsFocus: Bool {
        !isStartupSplashVisible
            // Nothing is pushed over the picker, such as Change Account,
            // which then owns focus.
            && router.path.isEmpty
            && !isPINEntryPresented
            && !showCreateProfile
            && router.pendingRemoval == nil
            && !viewModel.isClearingTemporaryManagementContext
            && !showsLoading
    }

    /// The remembered profile, else the first; Change Account when the
    /// picker shows an error instead of profiles.
    private var defaultPickerFocus: PickerFocus {
        let profiles = viewModel.profiles
        guard let first = profiles.first else { return viewModel.error == nil ? .add : .changeAccount }
        let remembered = rememberedProfileID.flatMap { id in profiles.contains { $0.id == id } ? id : nil }
        return .profile(remembered ?? first.id)
    }

    /// Puts focus on the control that opened whatever just closed, or on the
    /// default one. Once the picker is enabled again in this update.
    private func restoreFocus() {
        Task { @MainActor in
            await Task.yield()
            guard acceptsFocus else { return }
            pickerFocus = returnFocus.flatMap(availableFocus) ?? defaultPickerFocus
        }
    }

    /// `target` while it is still on screen.
    private func availableFocus(_ target: PickerFocus) -> PickerFocus? {
        switch target {
        case .profile(let id):
            viewModel.profiles.contains { $0.id == id } ? target : nil
        case .add:
            viewModel.profiles.isEmpty && viewModel.error != nil ? nil : target
        case .changeAccount, .signOut:
            target
        }
    }
    #endif

    // MARK: - Background

    /// The shared backdrop shows through; this
    /// only darkens it so names stay legible.
    private var background: some View {
        MarqueeScrim(style: .ambient)
    }

    private var tintedProfileID: String? {
        pinEntryContext?.profile.id ?? selectingProfileID ?? pressedProfileID
    }

    /// Loads the list and opens its only profile when that is due;
    /// otherwise the picker draws.
    private func loadProfilesAndSettle() async {
        if viewModel.profiles.isEmpty {
            // Nothing is drawn yet, so a list of one can still open unseen.
            hasSettled = requestedByPerson && !router.skipsSingleProfilePicker
        }
        await viewModel.loadProfiles()
        await skipPickerIfSingleProfile()
        if !requestedByPerson { await openOnlyProfileIfNeeded() }
        // While the TV's remember offer waits on a profile that opened this
        // way, the picker stays undrawn behind it.
        if viewModel.rememberOffer == nil { hasSettled = true }
    }

    /// A household with one profile and no PIN doesn't need a picker after
    /// signing in: go straight to Home. A failed load keeps the request, so a
    /// successful Retry still skips, and so does the picker shown after a
    /// temporary password is replaced.
    private func skipPickerIfSingleProfile() async {
        guard router.skipsSingleProfilePicker, viewModel.error == nil,
              !viewModel.requiresPasswordChange else { return }
        router.skipsSingleProfilePicker = false
        guard viewModel.profiles.count == 1, let only = viewModel.profiles.first, !only.hasPin else { return }
        await viewModel.selectProfile(only, router: router)
    }

    /// With one profile and no PIN there is nothing to choose: open it
    /// (spec §4.2), unless the person asked for the picker, whatever Profile
    /// Selection says, as Android and Roku do. A profile already opened and
    /// waiting on the TV's remember offer isn't opened again.
    private func openOnlyProfileIfNeeded() async {
        guard viewModel.error == nil, !viewModel.requiresPasswordChange,
              router.authState == .needsProfile, viewModel.rememberOffer == nil,
              viewModel.profiles.count == 1, let only = viewModel.profiles.first, !only.hasPin else { return }
        await viewModel.selectProfile(only, router: router)
    }

    // MARK: - Content

    /// A temporary password hands over to the password change; until that
    /// lands, keep the loading state rather than flash a refusal.
    private var showsLoading: Bool {
        viewModel.requiresPasswordChange || (viewModel.isLoading && viewModel.profiles.isEmpty)
            || awaitsOnlyProfile
    }

    /// The list is one profile without a PIN and the picker has yet to
    /// settle: that profile is about to open, or a fresh list is about to
    /// show there is a choice after all.
    private var awaitsOnlyProfile: Bool {
        !hasSettled && viewModel.error == nil
            && viewModel.profiles.count == 1 && viewModel.profiles.first?.hasPin == false
    }

    @ViewBuilder
    private var pickerContent: some View {
        if viewModel.rememberOffer != nil, awaitsOnlyProfile {
            // The offer asks about a profile that opened without the picker;
            // only the backdrop shows behind it.
            Color.clear
        } else if showsLoading {
            LoadingView(message: AppLanguage.string(.profilesLoading))
        } else if let error = viewModel.error, viewModel.profiles.isEmpty {
            #if os(tvOS)
            // Apple TV shows refusals it can't fix here, such as a temporary
            // password, so changing account and signing out stay offered.
            VStack(spacing: 0) {
                errorView(error)
                footerActions
                    .frame(maxWidth: .infinity)
                    .focusSection()
                    .padding(.bottom, 60)
            }
            #else
            errorView(error)
            #endif
        } else {
            content
        }
    }

    private func errorView(_ error: ErrorState) -> some View {
        ErrorView(state: error, onRetry: {
            Task { await loadProfilesAndSettle() }
        })
    }

    private var content: some View {
        #if os(tvOS)
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            header
            accountLine
                .padding(.top, 14)
            tileRow
                .padding(.horizontal, 80)
                .frame(maxWidth: .infinity)
                .padding(.top, 84)
                // Room for a focused name in the last row, which drops below
                // the tile's frame, so it clears the footer.
                .padding(.bottom, ProfileTile.focusedNameDrop)
            Spacer(minLength: 0)
            // Full width so Down from any avatar column finds the section,
            // not only from the avatars directly above the two buttons.
            footerActions
                .frame(maxWidth: .infinity)
                .focusSection()
        }
        .padding(.vertical, 60)
        #else
        // Centered, like the picker on TV: there's no keyboard to make room
        // for, so the people sit in the middle and utilities at the bottom.
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: Self.topGap)
                    VStack(spacing: 10) {
                        header
                        accountLine
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                    tileRows(layout(in: geo.size))
                        .padding(.top, Self.gridGap)
                    Spacer(minLength: Self.footerGap)
                    footerActions
                        .frame(maxWidth: .infinity)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
                }
                .frame(maxWidth: 440)
                .padding(.horizontal, 24)
                .padding(.bottom, Self.bottomGap)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            MarqueeTopBar {
                SiloWordmarkView(width: 92)
            } trailing: { EmptyView() }
            .padding(.horizontal, 24)
            .padding(.top, 6)
        }
        #endif
    }

    private var header: some View {
        #if os(tvOS)
        Text(.profilesHeadline)
            .font(.system(size: titleSize, weight: .heavy))
            .kerning(-titleSize * 0.025)
            .foregroundStyle(Color.siloOnSurface)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
        #else
        MarqueeHeadline(title: AppLanguage.string(.profilesHeadline), alignment: .center)
        #endif
    }

    /// Which account these profiles belong to. The line keeps its height
    /// while the account loads so the picker doesn't shift when it appears.
    private var accountLine: some View {
        (viewModel.accountName.map { Text(.profilesSignedInAs($0)) } ?? Text(verbatim: " "))
            .font(.system(size: MarqueeMetrics.leadFont))
            .foregroundStyle(Color.siloOnSurface.opacity(0.62))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .opacity(viewModel.accountName == nil ? 0 : 1)
            .animation(.easeOut(duration: 0.25), value: viewModel.accountName)
    }

    /// Changing account and signing out are utilities, kept small and below
    /// the people. Signing out asks first, naming the account and server.
    private var footerActions: some View {
        #if os(tvOS)
        HStack(spacing: footerSpacing) {
            changeAccountButton
            signOutButton
        }
        #else
        // Longer translations don't fit side by side on a narrow phone;
        // stack them rather than truncate a label.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: footerSpacing) {
                changeAccountButton
                signOutButton
            }
            VStack(spacing: 4) {
                changeAccountButton
                signOutButton
            }
        }
        #endif
    }

    private var changeAccountButton: some View {
        Button {
            router.showChangeAccount()
        } label: {
            #if os(tvOS)
            Label(.profilesChangeAccount, systemImage: "person.2")
            #else
            Label(.profilesFooterChangeAccount, systemImage: "person.2")
            #endif
        }
        .buttonStyle(.marquee(footerKind, fullWidth: false, compact: true))
        #if os(tvOS)
        .focused($pickerFocus, equals: .changeAccount)
        #endif
    }

    private var signOutButton: some View {
        Button {
            #if os(tvOS)
            returnFocus = .signOut
            #endif
            router.signOutAndReset()
        } label: {
            Label(.commonSignOut, systemImage: "rectangle.portrait.and.arrow.forward")
        }
        .buttonStyle(.marquee(footerKind, fullWidth: false, compact: true))
        #if os(tvOS)
        .focused($pickerFocus, equals: .signOut)
        #endif
    }

    private var footerKind: MarqueeButtonStyle.Kind {
        #if os(tvOS)
        .glass
        #else
        .plain
        #endif
    }

    #if os(tvOS)
    private var tileRow: some View {
        let rememberedProfileID = self.rememberedProfileID
        let grid = LazyVGrid(
            columns: gridColumns,
            spacing: rowSpacing
        ) {
            ForEach(viewModel.profiles) { profile in
                TVProfileTile(
                    profile: profile,
                    isRemembered: profile.id == rememberedProfileID
                ) {
                    handleProfileTap(profile)
                }
                .focused($pickerFocus, equals: .profile(profile.id))
            }
            AddProfileTile(title: .profilesAdd) {
                returnFocus = .add
                handleAddProfileTap()
            }
            .focused($pickerFocus, equals: .add)
        }

        // A focus section, so Up from either footer button finds the
        // centered grid.
        return grid
            .focusSection()
    }
    #endif

    #if !os(tvOS)
    private enum PickerItem: Identifiable {
        case profile(UserProfile)
        case add

        var id: String {
            switch self {
            case .profile(let profile): profile.id
            case .add: "add-profile"
            }
        }
    }

    private static let topGap: CGFloat = 24
    private static let gridGap: CGFloat = 36
    private static let footerGap: CGFloat = 32
    private static let bottomGap: CGFloat = 20

    /// The room between the title and the footer decides how many avatars
    /// share a row and how large they are.
    private func layout(in size: CGSize) -> ProfilePickerLayout? {
        guard headerHeight > 0, footerHeight > 0 else { return nil }
        let fixed = Self.topGap + Self.gridGap + Self.footerGap + Self.bottomGap
        return ProfilePickerLayout(
            tileCount: viewModel.profiles.count + 1,
            width: min(size.width - 48, 440),
            height: size.height - headerHeight - footerHeight - fixed
        )
    }

    /// Rows are centered, so a short last row sits in the middle instead of
    /// hanging off the left.
    private func tileRows(_ layout: ProfilePickerLayout?) -> some View {
        let items = viewModel.profiles.map(PickerItem.profile) + [.add]
        let perRow = layout?.perRow ?? 3
        let rememberedProfileID = self.rememberedProfileID
        let rows = stride(from: 0, to: items.count, by: perRow).map {
            Array(items[$0..<min($0 + perRow, items.count)])
        }

        return VStack(spacing: layout?.rowSpacing ?? 0) {
            ForEach(rows, id: \.first?.id) { row in
                // Top-aligned so a "Last used" caption doesn't lift its
                // avatar above the rest of the row.
                HStack(alignment: .top, spacing: 0) {
                    ForEach(row) { item in
                        Group {
                            switch item {
                            case .profile(let profile):
                                ProfileTile(
                                    profile: profile,
                                    isRemembered: profile.id == rememberedProfileID,
                                    size: layout?.avatarSize ?? 0,
                                    onPressChange: { pressed in
                                        pressedProfileID = pressed ? profile.id : nil
                                    }
                                ) {
                                    handleProfileTap(profile)
                                }
                            case .add:
                                AddProfileTile(size: layout?.addSize ?? 0, title: .profilesAdd) { handleAddProfileTap() }
                            }
                        }
                        .frame(width: layout?.columnWidth ?? 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        // Nothing draws until the room is measured, so tiles never render at
        // a placeholder size and then jump.
        .opacity(layout == nil ? 0 : 1)
    }
    #endif

    /// "Last used": the profile Automatic opens for the open account.
    private var rememberedProfileID: String? {
        let account = ServerRegistry.shared.activeServerId.flatMap { AccountScope.localAccountId(onServer: $0) }
        return launchPreferences.rememberedProfile(forAccount: account)?.profileID
    }

    private func handleProfileTap(_ profile: UserProfile) {
        #if os(tvOS)
        returnFocus = .profile(profile.id)
        #endif
        if profile.hasPin {
            pinEntryContext = PINEntryContext(profile: profile, purpose: .profileSelection)
        } else {
            selectingProfileID = profile.id
            Task {
                await viewModel.selectProfile(profile, router: router)
                selectingProfileID = nil
            }
        }
    }

    private func handleAddProfileTap() {
        guard let primaryProfile = viewModel.primaryProfile else {
            viewModel.error = ErrorState(
                statusCode: nil,
                message: AppLanguage.string(.profilesErrorNoPrimaryCreate)
            )
            return
        }

        if primaryProfile.hasPin {
            pinEntryContext = PINEntryContext(profile: primaryProfile, purpose: .profileManagement)
            return
        }

        Task {
            do {
                try await viewModel.prepareForProfileManagement()
                showCreateProfile = true
            } catch {
                viewModel.error = ErrorState(error)
            }
        }
    }

    private func handleCreateProfileDismissed() {
        Task { await viewModel.clearTemporaryManagementContextIfNeeded() }
    }

    @ViewBuilder
    private var profileOverlay: some View {
        #if os(tvOS)
        if let context = pinEntryContext {
            pinEntryContent(for: context)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(10)
        }
        #else
        if let context = pinEntryContext {
            pinEntryContent(for: context)
                .transition(.opacity)
                .zIndex(10)
        }
        #endif
    }

    private func pinEntryContent(for context: PINEntryContext) -> some View {
        PINEntryView(
            profile: context.profile,
            errorMessage: pinError,
            errorCount: wrongPINCount,
            isVerifying: isVerifyingPIN,
            onCancel: closePINEntry
        ) { pin in
            handlePINEntry(context: context, pin: pin)
        }
    }

    /// On Apple TV, focus goes back to the control that opened the prompt
    /// once the picker is enabled again (`restoreFocus`).
    private func closePINEntry() {
        pinEntryContext = nil
        pinError = nil
    }

    /// The prompt stays open while the server checks the PIN. A rejected PIN
    /// keeps it open for another try; anything else closes it and shows the
    /// error on the picker.
    private func handlePINEntry(context: PINEntryContext, pin: String) {
        isVerifyingPIN = true
        pinError = nil

        Task {
            do {
                switch context.purpose {
                case .profileSelection:
                    try await viewModel.selectProfileWithPIN(context.profile, pin: pin, router: router)
                    MarqueeHaptics.success()
                    if viewModel.rememberOffer != nil {
                        // Home waits for the remember offer; leave the prompt first.
                        closePINEntry()
                    }
                case .profileManagement:
                    try await viewModel.prepareForProfileManagement(pin: pin)
                    MarqueeHaptics.success()
                    closePINEntry()
                    showCreateProfile = true
                }
                isVerifyingPIN = false
            } catch {
                isVerifyingPIN = false
                if case ProfileTransitionError.incorrectPIN = error {
                    wrongPINCount += 1
                    pinError = AppLanguage.string(.pinWrong)
                } else if case ProfileTransitionError.pinLockedOut = error {
                    // Clears the entry; the lockout is not another wrong PIN.
                    wrongPINCount += 1
                    pinError = error.localizedDescription
                } else {
                    closePINEntry()
                    viewModel.error = ErrorState(error)
                }
            }
        }
    }

    // MARK: - Platform sizing

    #if os(tvOS)
    private let titleSize: CGFloat = 64
    private let tileSpacing: CGFloat = 44
    private let rowSpacing: CGFloat = 60
    private let footerSpacing: CGFloat = 20
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.fixed(240), spacing: tileSpacing), count: min(max(viewModel.profiles.count + 1, 1), 6))
        // 6 × 240 + 5 × 44 = 1660, inside the 1740 pt safe width.
    }
    #else
    private let footerSpacing: CGFloat = 4
    #endif
}

#if !os(tvOS)
/// How "Who's watching?" arranges its tiles (profiles plus "Add profile") in
/// the room it has: two, three or four per row, whichever gives the largest
/// avatars that still fit without scrolling. When even four per row would
/// shrink avatars below a comfortable tap size, the picker keeps four per
/// row at full size and scrolls.
struct ProfilePickerLayout: Equatable {
    let perRow: Int
    let avatarSize: CGFloat
    /// Alone on the last row, "Add profile" is a utility, not a person, so
    /// it is drawn smaller than the avatars above it.
    let addSize: CGFloat
    let rowSpacing: CGFloat
    /// Every row uses the full rows' column width, so a short last row is
    /// centered rather than spread out.
    let columnWidth: CGFloat
    let scrolls: Bool

    /// Name, optional "Last used" caption and their spacing under an avatar.
    static let labelHeight: CGFloat = 48
    static let minimumAvatar: CGFloat = 64

    private struct Option {
        let perRow: Int
        let maxAvatar: CGFloat
        /// Room beside each avatar for its name.
        let gutter: CGFloat
        let rowSpacing: CGFloat
    }

    private static let options = [
        Option(perRow: 2, maxAvatar: 140, gutter: 36, rowSpacing: 28),
        Option(perRow: 3, maxAvatar: 104, gutter: 16, rowSpacing: 26),
        Option(perRow: 4, maxAvatar: 76, gutter: 10, rowSpacing: 22),
    ]

    init(tileCount: Int, width: CGFloat, height: CGFloat) {
        let count = max(tileCount, 1)
        func widthFit(_ option: Option) -> CGFloat {
            min(option.maxAvatar, width / CGFloat(option.perRow) - option.gutter)
        }
        func fit(_ option: Option) -> CGFloat {
            let rows = CGFloat((count + option.perRow - 1) / option.perRow)
            let heightFit = (height - (rows - 1) * option.rowSpacing) / rows - Self.labelHeight
            return min(widthFit(option), heightFit)
        }

        var best: (option: Option, size: CGFloat)?
        for option in Self.options {
            let size = fit(option)
            if size >= Self.minimumAvatar, size > (best?.size ?? 0) {
                best = (option, size)
            }
        }
        let chosen = best ?? (Self.options[Self.options.count - 1], widthFit(Self.options[Self.options.count - 1]))
        let avatar = max(0, chosen.size.rounded(.down))

        perRow = chosen.option.perRow
        avatarSize = avatar
        addSize = count > 1 && count % chosen.option.perRow == 1 ? (avatar * 0.6).rounded() : avatar
        rowSpacing = chosen.option.rowSpacing
        columnWidth = (width / CGFloat(chosen.option.perRow)).rounded(.down)
        scrolls = best == nil
    }
}
#endif
