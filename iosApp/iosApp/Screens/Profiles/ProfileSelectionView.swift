import SwiftUI

/// "Who's watching?" profile picker. Cinematic household layout: the tint
/// of each tile carries the profile's identity, focus lifts the tile with
/// a colored halo, and a soft radial gradient grounds the row so the black
/// background doesn't feel like dead space.
struct ProfileSelectionView: View {
    var router: AppRouter
    var journeyLabels: [String] = ["Server", "Account", "Profile"]
    @State private var viewModel = ProfileSelectionViewModel()
    @State private var launchPreferences = ProfileLaunchPreferences.shared
    @State private var pinEntryContext: PINEntryContext?
    @State private var showCreateProfile: Bool = false
    @State private var showSignOutConfirm: Bool = false
    @Namespace private var profileFocusNamespace
    #if os(tvOS)
    @FocusState private var isSignOutFocused: Bool
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
                .disabled(viewModel.isClearingTemporaryManagementContext)
                #endif
        }
        .task {
            await viewModel.loadProfiles()
        }
        #if os(tvOS)
        .overlay {
            profileOverlay
        }
        #endif
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
            .presentationDragIndicator(.visible)
        }
        #endif
        #if !os(tvOS)
        .sheet(item: $pinEntryContext) { context in
            pinEntryContent(for: context)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        #endif
    }

    // MARK: - Background

    /// Pure black canvas with a soft radial spotlight behind the row. The
    /// radial is 8% white at the center fading to transparent, so the
    /// tiles have somewhere to "sit" without the background reading as a
    /// gradient card.
    private var background: some View {
        #if os(tvOS)
        AuroraBackdrop(variant: .profile, scrim: .soft)
        #else
        AuroraBackdrop(variant: .profile, scrim: .soft)
        #endif
    }

    // MARK: - Content

    @ViewBuilder
    private var pickerContent: some View {
        if viewModel.isLoading && viewModel.profiles.isEmpty {
            LoadingView(message: "Loading profiles...")
        } else if let error = viewModel.error, viewModel.profiles.isEmpty {
            ErrorView(state: error, onRetry: { Task { await viewModel.loadProfiles() } })
        } else {
            content
        }
    }

    private var content: some View {
        #if os(tvOS)
        VStack(spacing: 0) {
            header

            Spacer(minLength: 0)

            tileRow
                .padding(.horizontal, 80)

            Spacer(minLength: 0)
        }
        #else
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Spacer()
                changeServerChip
                signOutChip
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 12)

            ScrollView {
                VStack(spacing: 36) {
                    header
                    tileRow
                        .padding(.horizontal, horizontalPadding)
                }
                .padding(.top, headerTopPadding)
                .padding(.bottom, 40)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        #endif
    }

    private var header: some View {
        #if os(tvOS)
        // The title is centered across the full screen width; the chips are
        // overlaid in the top-right corner so they don't shift the title off
        // center.
        titleBlock
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
            .overlay(alignment: .topTrailing) {
                HStack(alignment: .top, spacing: 12) {
                    changeServerChip
                    signOutChip
                }
            }
            .padding(.top, headerTopPadding)
            .padding(.horizontal, 60)
            // Without this, pressing Up from a centered profile tile can't
            // reach the Sign Out chip — the focus engine looks for a
            // focusable element roughly above the current one, and the chip
            // is pinned to the top-right corner. `focusSection` tells the
            // engine to treat the whole header row as a valid upward target.
            .focusSection()
        #else
        titleBlock
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
        #endif
    }

    private var titleBlock: some View {
        VStack(spacing: 6) {
            AuroraJourneyProgress(currentStep: 3, labels: journeyLabels)
                .frame(maxWidth: journeyWidth)
                .padding(.bottom, journeyBottomPadding)

            #if os(tvOS)
            Text("Who's watching?")
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(Color.auroraInk)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text("Select your profile")
                .font(.system(size: subtitleSize, weight: .regular))
                .foregroundStyle(Color.auroraInkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            #else
            Text("Who's watching?")
                .font(.system(size: titleSize, weight: .semibold))
                .tracking(-0.5)
                .foregroundStyle(Color.auroraInk)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text("Select your profile")
                .font(.system(size: subtitleSize, weight: .regular))
                .foregroundStyle(Color.auroraInkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            #endif
        }
    }

    /// Small ghost chip in the top-right. Signing out is utility, not a
    /// primary action — tucking it here frees the center of the screen
    /// for the identity moment.
    private var signOutChip: some View {
        Button {
            #if os(tvOS)
            showSignOutConfirm = true
            #else
            router.signOutAndReset()
            #endif
        } label: {
            HStack(spacing: 6) {
                Text("Sign Out")
                    .font(.system(size: chipSize, weight: .medium))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: chipSize - 1, weight: .medium))
            }
        }
        .buttonStyle(GhostChipButtonStyle())
        #if os(tvOS)
        .focused($isSignOutFocused)
        #endif
    }

    /// Companion to `signOutChip`. Routes to the server picker so the
    /// user can switch between saved servers (or add a new one) without
    /// first signing out.
    private var changeServerChip: some View {
        Button {
            router.navigate(to: .serverList)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.system(size: chipSize - 1, weight: .medium))
                Text("Change Server")
                    .font(.system(size: chipSize, weight: .medium))
            }
        }
        .buttonStyle(GhostChipButtonStyle())
    }

    private var tileRow: some View {
        let rememberedProfileID = launchPreferences.rememberedProfile(
            for: ServerRegistry.shared.activeServerId
        )?.profileID
        let preferredProfileID = rememberedProfileID ?? viewModel.profiles.first?.id
        let grid = LazyVGrid(
            columns: [GridItem(.adaptive(minimum: tileMinWidth, maximum: tileMaxWidth), spacing: tileSpacing)],
            spacing: rowSpacing
        ) {
            ForEach(viewModel.profiles) { profile in
                #if os(tvOS)
                TVProfileTile(
                    profile: profile,
                    isRemembered: profile.id == rememberedProfileID,
                    prefersDefaultFocus: profile.id == preferredProfileID,
                    defaultFocusNamespace: profileFocusNamespace
                ) {
                    handleProfileTap(profile)
                }
                #else
                ProfileTile(
                    profile: profile,
                    isRemembered: profile.id == rememberedProfileID
                ) {
                    handleProfileTap(profile)
                }
                #endif
            }
            AddProfileTile { handleAddProfileTap() }
        }

        #if os(tvOS)
        // Mirror of the header's `focusSection()`. Without this, pressing
        // Down from the Sign Out chip (top-right) has no section to
        // descend into — the focus engine's spatial search can't find
        // the centered tile grid from a corner anchor and focus gets
        // stuck on Sign Out. Making the grid a focus section gives the
        // engine a guaranteed target below the header.
        return grid
            .focusScope(profileFocusNamespace)
            .focusSection()
        #else
        return grid
        #endif
    }

    private func handleProfileTap(_ profile: UserProfile) {
        if profile.hasPin {
            pinEntryContext = PINEntryContext(profile: profile, purpose: .profileSelection)
        } else {
            Task { await viewModel.selectProfile(profile, router: router) }
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
                await MainActor.run { showCreateProfile = true }
            } catch {
                await MainActor.run {
                    viewModel.error = ErrorState(error)
                }
            }
        }
    }

    private func handleCreateProfileDismissed() {
        Task { await viewModel.clearTemporaryManagementContextIfNeeded() }
    }

    #if os(tvOS)
    @ViewBuilder
    private var profileOverlay: some View {
        if showSignOutConfirm {
            TVSettingsConfirmationOverlay.signOut(
                cancel: dismissSignOutConfirmation,
                confirm: router.signOutAndReset,
                removeServer: router.signOutRemoveServerAndReset
            )
            .transition(.opacity)
            .zIndex(10)
        } else if let context = pinEntryContext {
            pinEntryContent(for: context)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(10)
        }
    }

    private func dismissSignOutConfirmation() {
        showSignOutConfirm = false
        Task { @MainActor in
            await Task.yield()
            isSignOutFocused = true
        }
    }
    #endif

    private func pinEntryContent(for context: PINEntryContext) -> some View {
        PINEntryView(
            profile: context.profile,
            onCancel: { pinEntryContext = nil }
        ) { pin in
            handlePINEntry(context: context, pin: pin)
        }
    }

    private func handlePINEntry(context: PINEntryContext, pin: String) {
        pinEntryContext = nil

        Task {
            do {
                switch context.purpose {
                case .profileSelection:
                    try await viewModel.selectProfileWithPIN(context.profile, pin: pin, router: router)
                case .profileManagement:
                    try await viewModel.prepareForProfileManagement(pin: pin)
                    await MainActor.run { showCreateProfile = true }
                }
            } catch {
                await MainActor.run {
                    viewModel.error = ErrorState(error)
                }
            }
        }
    }

    // MARK: - Platform sizing

    #if os(tvOS)
    private let titleSize: CGFloat = 64
    private let subtitleSize: CGFloat = 22
    private let chipSize: CGFloat = 18
    private let headerTopPadding: CGFloat = 100
    private let journeyWidth: CGFloat = 430
    private let journeyBottomPadding: CGFloat = 18
    private let tileMinWidth: CGFloat = 300
    private let tileMaxWidth: CGFloat = 340
    private let tileSpacing: CGFloat = 56
    private let rowSpacing: CGFloat = 72
    #else
    private let titleSize: CGFloat = 32
    private let subtitleSize: CGFloat = 15
    private let chipSize: CGFloat = 13
    private let headerTopPadding: CGFloat = 24
    private let journeyWidth: CGFloat = 330
    private let journeyBottomPadding: CGFloat = 14
    private let tileMinWidth: CGFloat = 140
    private let tileMaxWidth: CGFloat = 180
    private let tileSpacing: CGFloat = 16
    private let rowSpacing: CGFloat = 28
    private let horizontalPadding: CGFloat = 20
    #endif
}

// `GhostChipButtonStyle` now lives in `Theme/SiloButtonStyles.swift`
// (shared with `CreateProfileView`).
