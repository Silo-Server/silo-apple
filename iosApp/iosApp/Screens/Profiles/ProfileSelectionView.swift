import SwiftUI

/// "Who's watching?" profile picker over the shared backdrop.
struct ProfileSelectionView: View {
    var router: AppRouter
    @State private var viewModel = ProfileSelectionViewModel()
    @State private var pinEntryContext: PINEntryContext?
    @State private var wrongPINCount = 0
    @State private var pinError: String?
    @State private var isVerifyingPIN = false
    @State private var showCreateProfile: Bool = false
    @State private var showSignOutConfirm: Bool = false
    /// The profile under a finger, then the one being opened; either tints
    /// the backdrop with that profile's color.
    @State private var pressedProfileID: String?
    @State private var selectingProfileID: String?
    #if !os(tvOS)
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    #endif
    #if os(tvOS)
    @FocusState private var isSignOutFocused: Bool
    @FocusState private var focusedProfileID: String?
    /// The profile whose PIN prompt was open, so closing it puts focus back
    /// on that profile rather than the first one.
    @State private var returnFocusProfileID: String?
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

    var body: some View {
        ZStack {
            background

            pickerContent
                #if os(tvOS)
                .disabled(
                    viewModel.isClearingTemporaryManagementContext
                        || isPINEntryPresented
                        || showSignOutConfirm
                )
                .accessibilityHidden(isPINEntryPresented || showSignOutConfirm)
                #else
                .disabled(viewModel.isClearingTemporaryManagementContext || isPINEntryPresented)
                .accessibilityHidden(isPINEntryPresented)
                #endif
                .opacity(isPINEntryPresented ? 0 : 1)
        }
        .animation(.easeInOut(duration: 0.25), value: isPINEntryPresented)
        .task {
            MarqueeScene.shared.showActiveServer()
            MarqueeScene.shared.focus = .profiles
            async let account: Void = viewModel.loadAccount(accounts: router.accounts)
            await viewModel.loadProfiles()
            await skipPickerIfSingleProfile()
            await account
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
        .alert(
            rememberOfferTitle,
            isPresented: Binding(
                get: { viewModel.rememberOffer != nil },
                // Only the buttons answer: Menu runs the cancel button's action.
                set: { _ in }
            )
        ) {
            Button("Remember") {
                viewModel.answerRememberOffer(remember: true, router: router)
            }
            Button("Ask Every Time", role: .cancel) {
                viewModel.answerRememberOffer(remember: false, router: router)
            }
        } message: {
            Text("Silo can skip Who's Watching and open this profile when it starts on this Apple TV. You can change this later in Settings > General > Profile Selection.")
        }
        #endif
    }

    #if os(tvOS)
    private var rememberOfferTitle: String {
        "Open \(viewModel.rememberOffer?.name ?? "this profile") automatically?"
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

    /// A household with one profile and no PIN doesn't need a picker after
    /// signing in: go straight to Home. A failed load keeps the request, so a
    /// successful Retry still skips.
    private func skipPickerIfSingleProfile() async {
        guard router.skipsSingleProfilePicker, viewModel.error == nil else { return }
        router.skipsSingleProfilePicker = false
        guard viewModel.profiles.count == 1, let only = viewModel.profiles.first, !only.hasPin else { return }
        await viewModel.selectProfile(only, router: router)
    }

    // MARK: - Content

    @ViewBuilder
    private var pickerContent: some View {
        if viewModel.isLoading && viewModel.profiles.isEmpty {
            LoadingView(message: "Loading profiles...")
        } else if let error = viewModel.error, viewModel.profiles.isEmpty {
            ErrorView(state: error, onRetry: {
                Task {
                    await viewModel.loadProfiles()
                    await skipPickerIfSingleProfile()
                }
            })
        } else {
            content
        }
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
            Spacer(minLength: 0)
            // Full width so Down from any avatar column finds the section,
            // not only from the avatars directly above the buttons.
            ProfileSelectionTVFooter(
                router: router,
                showsSignOutConfirmation: $showSignOutConfirm,
                signOutFocus: $isSignOutFocused
            )
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
            } trailing: {
                ProfileSelectionServerMenu(router: router)
            }
            .padding(.horizontal, 24)
            .padding(.top, 6)
        }
        #endif
    }

    private var header: some View {
        #if os(tvOS)
        Text("Who's watching?")
            .font(.system(size: titleSize, weight: .heavy))
            .kerning(-titleSize * 0.025)
            .foregroundStyle(Color.siloOnSurface)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
        #else
        MarqueeHeadline(title: "Who's watching?", alignment: .center)
        #endif
    }

    /// Which account these profiles belong to (spec §5.1). The line
    /// keeps its height while the account loads so the picker doesn't shift
    /// when it appears.
    private var accountLine: some View {
        let line = viewModel.accountLine(accounts: router.accounts)
        return Text(line ?? " ")
            .font(.system(size: MarqueeMetrics.leadFont))
            .foregroundStyle(Color.siloOnSurface.opacity(0.62))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .opacity(line == nil ? 0 : 1)
            .animation(.easeOut(duration: 0.25), value: line)
    }

    #if !os(tvOS)
    /// Switching account and signing out are utilities, kept small and below
    /// the people. Switch Account shows Choose an Account; Sign out asks
    /// first, since it affects everyone on the device (plan G10).
    private var footerActions: some View {
        HStack(spacing: footerSpacing) {
            Button {
                Task { await router.accounts.beginSwitchAccount(router: router) }
            } label: {
                Label("Switch Account", systemImage: "person.2")
            }
            .buttonStyle(.marquee(.plain, fullWidth: false, compact: true))

            Button {
                Task { await router.accounts.requestRemoval(.currentAccount, router: router) }
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.marquee(.plain, fullWidth: false, compact: true))
        }
    }
    #endif

    #if os(tvOS)
    private var tileRow: some View {
        let rememberedProfileID = viewModel.rememberedProfileID
        // Focus starts on the leftmost profile; closing a PIN prompt returns
        // it to the profile that opened the prompt.
        let preferredProfileID = returnFocusProfileID ?? viewModel.profiles.first?.id
        let grid = LazyVGrid(
            columns: gridColumns,
            spacing: rowSpacing
        ) {
            ForEach(viewModel.profiles) { profile in
                TVProfileTile(
                    profile: profile,
                    isRemembered: profile.id == rememberedProfileID,
                    focus: $focusedProfileID
                ) {
                    handleProfileTap(profile)
                }
            }
            AddProfileTile { handleAddProfileTap() }
        }

        // A focus section, so Up from either footer button finds the
        // centered grid. The default only applies while nothing holds
        // focus, and arriving from a screen whose focused control is gone
        // leaves nothing focused, so it is seeded too.
        return grid
            .focusSection()
            .defaultFocus($focusedProfileID, preferredProfileID, priority: .userInitiated)
            // The picker draws before its profiles load: seed again once the
            // leftmost profile is there.
            .marqueeTVSeedFocus($focusedProfileID, preferredProfileID ?? "", id: preferredProfileID)
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
        let rememberedProfileID = viewModel.rememberedProfileID
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
                                AddProfileTile(size: layout?.addSize ?? 0) { handleAddProfileTap() }
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

    private func handleProfileTap(_ profile: UserProfile) {
        #if os(tvOS)
        returnFocusProfileID = profile.id
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
                message: "Couldn't find the primary profile needed to create another profile."
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
        if showSignOutConfirm {
            ProfileSelectionTVSignOutConfirmation(router: router, cancel: dismissSignOutConfirmation)
            .transition(.opacity)
            .zIndex(10)
        } else if let context = pinEntryContext {
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

    #if os(tvOS)
    private func dismissSignOutConfirmation() {
        showSignOutConfirm = false
        Task {
            await Task.yield()
            isSignOutFocused = true
        }
    }
    #endif

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

    private func closePINEntry() {
        pinEntryContext = nil
        pinError = nil
        #if os(tvOS)
        // The picker is enabled again in this update; once it is, send focus
        // to the profile that opened the prompt.
        let profileID = returnFocusProfileID
        Task {
            await Task.yield()
            focusedProfileID = profileID
        }
        #endif
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
                    pinError = "Wrong PIN. Try again."
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
