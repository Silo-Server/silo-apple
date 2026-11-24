#if os(tvOS)
import SwiftUI

/// Family-synced tvOS interface preferences. Every control is a native focus
/// target and never intercepts directional movement, preserving the stable
/// focus graph described in `docs/tvos-focus.md`.
struct TVGeneralSettingsPane: View {
    @State private var preferences = UICustomizationPreferences.shared
    @State private var titleArt = TitleArtPreferences.shared
    @State private var themeMusic = ThemeMusicPreferences.shared
    @State private var appLanguage = AppLanguagePreferences.shared
    @State private var launchPreferences = ProfileLaunchPreferences.shared
    @State private var navPrefs = AppNavPreferences.shared
    @State private var activePicker: PickerKind?
    @State private var showsHomeSectionsEditor = false
    @State private var registry = ServerRegistry.shared
    @StateObject private var advisoryAgePreference = AdvisoryAgePreferenceStore.shared
    let activeProfile: UserProfile?
    let detailFocus: FocusState<TVSettingsDetailFocus?>.Binding
    let changePairedProfile: () -> Void
    private let appleTVUserContext = AppleTVUserContext.current
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TVSettingsSectionHeader(.settingsGeneralAppleTvUserHeaderTv)

            TVSettingsPickerRow(
                title: .settingsGeneralPairedProfile,
                value: pairedProfileName,
                action: changePairedProfile
            )
            .focused(detailFocus, equals: .generalAppleTVUser)

            TVSettingsFooter(pairingDescription)

            TVSettingsSectionHeader(.settingsGeneralProfileAtLaunchHeaderTv)

            TVSettingsPickerRow(
                title: .settingsControlProfileSelection,
                value: launchPreferences.behavior.title
            ) { activePicker = .profileLaunch }
            .focused(detailFocus, equals: .generalProfileLaunch)
            .accessibilityHint(Text(launchPreferences.behavior.tvDescription))

            TVSettingsFooter(launchPreferences.behavior.tvDescription)

            if appLanguage.currentChoice != nil {
                languageGroup
            }

            TVSettingsSectionHeader(.homeProfileEditorHeaderTv)

            Button { showsHomeSectionsEditor = true } label: {
                HStack(spacing: 16) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 22, weight: .medium))
                    Text(.homeProfileEditorTitle)
                        .font(.system(size: 26))
                    Spacer(minLength: 16)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18, weight: .semibold))
                        .opacity(0.55)
                }
            }
            .buttonStyle(TVSettingsPaneRowStyle())
            .focused(detailFocus, equals: .generalHomeSections)

            TVSettingsFooter(.homeProfileEditorSettingsFooter)

            if titleArt.isOffered {
                titleArtGroup
            }

            if themeMusic.isOffered {
                themeMusicGroup
            }

            if let message = preferences.capabilityMessage {
                TVSettingsSectionHeader(.settingsGeneralServerSupportHeaderTv)
                TVSettingsFooter(.verbatim(message))
            }

            if preferences.hasDeviceOverrides {
                TVSettingsSectionHeader(.settingsGeneralSyncSourceHeaderTv)
                if preferences.cardPresentationUsesDeviceOverride {
                    familySettingsButton
                        .focused(detailFocus, equals: .generalPosterSize)
                } else {
                    familySettingsButton
                }
                TVSettingsFooter(.settingsGeneralDeviceOverrideFooterTv)
            }

            TVSettingsSectionHeader(.settingsGeneralCardsHeaderTv)

            if advisoryAgePreference.isSupported {
                TVSettingsToggleRow(
                    title: .settingsGeneralShowAdvisoryAge,
                    isOn: advisoryAgePreference.showsAdvisoryAge
                ) {
                    Task {
                        await advisoryAgePreference.setShowsAdvisoryAge(
                            !advisoryAgePreference.showsAdvisoryAge
                        )
                    }
                }
                .focused(detailFocus, equals: .generalAdvisoryAge)
                .disabled(advisoryAgePreference.isSaving)

                TVSettingsFooter(.settingsGeneralShowAdvisoryAgeFooter)
                if let writeError = advisoryAgePreference.writeError {
                    TVSettingsFooter(.verbatim(writeError))
                }
            }

            posterSizeRow

            if preferences.cardPresentationUsesFamilyOverride {
                Button(.settingsCardsUseProfileDefault) {
                    preferences.resetCardPresentationToInherited()
                }
                .buttonStyle(TVSettingsPaneRowStyle())
                .disabled(preferences.isSaving || !preferences.allowsEditing)
            }

            TVSettingsFooter(.settingsGeneralPosterSizeSyncsTv)

            if let message = preferences.syncErrorMessage,
               message != preferences.capabilityMessage,
               message != HeldSettingChange.message {
                TVSettingsFooter(.verbatim(message))
            }
            if preferences.hasHeldChanges {
                TVHeldSettingChangesRows(
                    retry: { preferences.retryHeldChanges() },
                    discard: { await preferences.discardHeldChanges() }
                )
            }

            TVSettingsSectionHeader(.settingsGeneralTopMenuHeaderTv)

            TVSettingsToggleRow(
                title: .settingsExperimentalShowAudiobooks,
                isOn: navPrefs.showAudiobooks
            ) {
                navPrefs.setShowAudiobooks(!navPrefs.showAudiobooks)
            }
            .focused(detailFocus, equals: .generalTopMenu)

            TVSettingsFooter(.settingsGeneralTopMenuFooterTv)
        }
        .fullScreenCover(item: $activePicker) { picker in
            pickerSheet(for: picker)
        }
        .fullScreenCover(isPresented: $showsHomeSectionsEditor) {
            TVHomeSectionsCustomizationSheet()
        }
        .task {
            async let preferencesRefresh: Void = preferences.refresh()
            async let titleArtRefresh: Void = titleArt.refresh()
            async let advisoryRefresh: Void = advisoryAgePreference.refresh()
            async let themeMusicRefresh: Void = themeMusic.refresh()
            async let languageRefresh: Void = appLanguage.refresh()
            _ = await (preferencesRefresh, titleArtRefresh, advisoryRefresh, themeMusicRefresh, languageRefresh)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                async let preferencesRefresh: Void = preferences.refresh()
                async let titleArtRefresh: Void = titleArt.refresh()
                async let themeMusicRefresh: Void = themeMusic.refresh()
                async let languageRefresh: Void = appLanguage.refresh()
                _ = await (preferencesRefresh, titleArtRefresh, themeMusicRefresh, languageRefresh)
            }
        }
    }

    /// Title art (`ui.title_art`) and its "Apply to All Devices" companion.
    /// See `TitleArtPreferences` for the scopes each row writes.
    @ViewBuilder
    private var titleArtGroup: some View {
        TVSettingsSectionHeader(.settingsGeneralTitlePagesHeaderTv)

        TVSettingsToggleRow(
            title: .settingsControlTitleArt,
            isOn: titleArt.showsTitleArt
        ) {
            titleArt.setShowTitleArt(!titleArt.showsTitleArt)
        }
        .accessibilityHint(Text(.settingsTitleArtFooter))
        .disabled(!titleArt.allowsEditing)

        TVSettingsToggleRow(
            title: .settingsInterfaceApplyToAllDevices,
            isOn: titleArt.appliesToAllDevices
        ) {
            titleArt.setAppliesToAllDevices(!titleArt.appliesToAllDevices)
        }
        .accessibilityHint(Text(.settingsInterfaceApplyToAllDevicesSubtitle))
        .disabled(!titleArt.allowsEditing)

        if titleArt.appliesToAllDevices {
            TVSettingsFooter(
                titleArt.showsTitleArt
                    ? .settingsGeneralTitleArtAllOnTv
                    : .settingsGeneralTitleArtAllOffTv
            )
        } else {
            TVSettingsFooter(.settingsGeneralTitleArtThisAppleTv)
        }
        if let message = titleArt.errorMessage ?? titleArt.readErrorMessage {
            TVSettingsFooter(.verbatim(message))
        }
    }

    /// The profile's app language. See `AppLanguagePreferences`.
    @ViewBuilder
    private var languageGroup: some View {
        TVSettingsSectionHeader(.settingsAppLanguageHeaderTv)

        TVSettingsPickerRow(
            title: .settingsAppLanguageTitle,
            value: appLanguage.selectedLabel
        ) { activePicker = .appLanguage }

        TVSettingsFooter(appLanguage.footer)
        if let message = appLanguage.errorMessage {
            TVSettingsFooter(message)
        }
    }

    /// Theme music on title pages, written as this Apple TV's choice. See
    /// `ThemeMusicPreferences`.
    @ViewBuilder
    private var themeMusicGroup: some View {
        TVSettingsSectionHeader(.settingsGeneralThemeMusicHeaderTv)

        TVSettingsToggleRow(
            title: .settingsControlThemeMusic,
            isOn: themeMusic.playsThemeMusic
        ) {
            themeMusic.setEnabled(!themeMusic.playsThemeMusic)
        }
        .accessibilityHint(Text(.settingsInterfacePlayThemeMusicSubtitle))
        .disabled(!themeMusic.allowsEditing)

        TVSettingsToggleRow(
            title: .settingsControlThemeMusicLoop,
            isOn: themeMusic.loops
        ) {
            themeMusic.setLoop(!themeMusic.loops)
        }
        .accessibilityHint(Text(.settingsInterfaceLoopThemeMusicSubtitle))
        .disabled(!themeMusic.allowsEditing || !themeMusic.playsThemeMusic)

        TVSettingsFooter(.settingsGeneralThemeMusicFooterTv)
        if let message = themeMusic.errorMessage {
            TVSettingsFooter(.verbatim(message))
        }
    }

    private var pairedProfileName: LocalizedStringResource {
        guard registry.activeServerId != nil,
              let remembered = launchPreferences.rememberedProfile(
                  forAccount: AccountScope.current?.localAccountId
              ) else {
            return .settingsGeneralNotPaired
        }
        guard let activeProfile,
              activeProfile.id == remembered.profileID else {
            return .settingsGeneralSavedProfile
        }
        return .verbatim(activeProfile.name)
    }

    /// How profile pairing works for this Apple TV user, with the Ask Every
    /// Time note, as one whole sentence each.
    private var pairingDescription: LocalizedStringResource {
        let asksEveryLaunch = launchPreferences.behavior == .askEveryLaunch
        if appleTVUserContext.shouldStorePreferencesForCurrentUser {
            return asksEveryLaunch ? .settingsGeneralPairingSeparateAskEveryTime : .settingsGeneralPairingSeparate
        }
        return asksEveryLaunch ? .settingsGeneralPairingSharedAskEveryTime : .settingsGeneralPairingShared
    }

    @ViewBuilder
    private var posterSizeRow: some View {
        let row = TVSettingsPickerRow(
            title: .settingsCardsPosterSize,
            value: preferences.cardPresentation.posterSize.title
        ) { activePicker = .posterSize }

        if preferences.cardPresentationUsesDeviceOverride || !preferences.allowsEditing {
            row.disabled(true)
        } else {
            row.focused(detailFocus, equals: .generalPosterSize)
        }
    }

    private var familySettingsButton: some View {
        Button(.settingsGeneralUseSyncedTvSettings) {
            preferences.useFamilySettings()
        }
        .buttonStyle(TVSettingsPaneRowStyle())
        .disabled(preferences.isSaving || !preferences.allowsEditing)
    }

    @ViewBuilder
    private func pickerSheet(for picker: PickerKind) -> some View {
        switch picker {
        case .profileLaunch:
            TVSettingsPickerSheet(
                title: .settingsControlProfileSelection,
                options: TVSettingsOptions.profileLaunch,
                selection: $launchPreferences.behaviorID
            )
        case .appLanguage:
            TVSettingsPickerSheet(
                title: .settingsAppLanguageTitle,
                options: appLanguage.options.map { TVSettingsOption(id: $0.id, label: $0.label) },
                selection: Binding(
                    get: { appLanguage.currentChoice?.tag ?? "" },
                    set: { id in Task { await appLanguage.select(id.isEmpty ? nil : id) } }
                ),
                allowsSelection: !appLanguage.isBusy,
                disabledMessage: appLanguage.isBusy ? .settingsAppLanguageSaving : nil
            )
        case .posterSize:
            TVSettingsPickerSheet(
                title: .settingsCardsPosterSize,
                options: CardPosterSize.allCases.map {
                    TVSettingsOption(id: $0.rawValue, label: $0.title)
                },
                selection: Binding(
                    get: { preferences.cardPresentation.posterSize.rawValue },
                    set: { value in
                        guard let size = CardPosterSize(rawValue: value) else { return }
                        preferences.setPosterSize(size)
                    }
                ),
                allowsSelection: preferences.allowsEditing,
                disabledMessage: preferences.capabilityMessage.map { .verbatim($0) }
            )
        }
    }

    private enum PickerKind: String, Identifiable {
        case profileLaunch
        case appLanguage
        case posterSize
        var id: String { rawValue }
    }
}

/// Apple TV editor for the acting profile's Home layout, saved on the server
/// (see `HomeSectionsEditorModel`) so it applies to this profile on every
/// device. Visibility is always available through the eye control; Edit
/// reveals remote-friendly Move Up / Move Down buttons because tvOS has no
/// touch drag. Every change saves at once.
private struct TVHomeSectionsCustomizationSheet: View {
    private enum FocusTarget: Hashable {
        case edit
        case done
        case retry
        case moveUp(String)
        case moveDown(String)
        case visibility(String)
    }

    @State private var model = HomeSectionsEditorModel()
    @State private var isEditing = false
    @State private var isClosing = false
    @FocusState private var focusedControl: FocusTarget?
    @Namespace private var editorFocusScope
    @Environment(\.dismiss) private var dismiss
    @Environment(\.resetFocus) private var resetFocus
    @Environment(\.locale) private var locale

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    sectionHeader(.homeProfileEditorHeaderTv)

                    editorControlsCard

                    if let error = model.saveError {
                        TVSettingsFooter(.verbatim(error))
                    }

                    switch model.phase {
                    case .loading:
                        HStack {
                            Spacer()
                            ProgressView()
                                .tint(.siloOnSurface)
                            Spacer()
                        }
                        .frame(height: 160)
                    case .failed(let message):
                        TVSettingsFooter(.homeProfileEditorLoadFailedTv(message))
                        Button(.homeProfileEditorTryAgain) {
                            Task { await model.load() }
                        }
                        .buttonStyle(TVHomeSectionsControlButtonStyle())
                        .focused($focusedControl, equals: .retry)
                    case .loaded where model.rows.isEmpty:
                        TVSettingsFooter(.homeProfileEditorEmptyBody)
                    case .loaded:
                        VStack(spacing: 10) {
                            ForEach(model.rows) { row in
                                sectionRow(row)
                            }
                        }
                        .focusSection()

                        TVSettingsFooter(
                            isEditing ? .homeProfileEditorEditingFooterTv : .homeProfileEditorFooterTv
                        )
                    }
                }
                .frame(maxWidth: 1120, alignment: .leading)
                .padding(.horizontal, 72)
                .padding(.vertical, 36)
            }
            .navigationTitle(Text(.homeProfileEditorTitle))
            .background(Color.siloBackground.ignoresSafeArea())
            .task {
                await model.load()
            }
        }
        .focusScope(editorFocusScope)
        .focusSection()
        .defaultFocus($focusedControl, .done, priority: .userInitiated)
        .onAppear(perform: claimFocus)
        .onChange(of: focusedControl) { previous, target in
            // Restore focus only when the focused control itself went away
            // (a reload dropped its row, Try Again finished, an arrow
            // disabled). Ordinary focus movement is left to the focus engine.
            guard target == nil, !isClosing, let previous, !isAvailable(previous) else { return }
            focusedControl = replacement(for: previous)
        }
        .onExitCommand(perform: close)
        .onDisappear { isClosing = true }
    }

    /// Whether `target` is still on screen and enabled.
    private func isAvailable(_ target: FocusTarget) -> Bool {
        switch target {
        case .done:
            return true
        case .edit:
            return model.phase == .loaded && model.rows.count > 1
        case .retry:
            if case .failed = model.phase { return true }
            return false
        case .moveUp(let id):
            return isEditing && model.canMove(id: id, by: -1)
        case .moveDown(let id):
            return isEditing && model.canMove(id: id, by: 1)
        case .visibility(let id):
            return model.phase == .loaded && model.rows.contains { $0.id == id }
        }
    }

    /// The nearest control that is still available: the same row's eye for
    /// a row control, otherwise Done.
    private func replacement(for target: FocusTarget) -> FocusTarget {
        switch target {
        case .moveUp(let id), .moveDown(let id), .visibility(let id):
            let eye = FocusTarget.visibility(id)
            return isAvailable(eye) ? eye : .done
        case .done, .edit, .retry:
            return .done
        }
    }

    private var editorControlsCard: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(.homeProfileEditorTitle)
                    .font(.system(size: 26, weight: .medium))

                Text(isEditing ? .homeProfileEditorEditingSubtitleTv : .homeProfileEditorSubtitleTv)
                    .font(.system(size: 18))
                    .foregroundStyle(Color.siloSecondaryText)
            }

            Spacer(minLength: 24)

            Button(isEditing ? .homeProfileEditorDoneEditing : .homeProfileEditorEdit) {
                withAnimation(.easeOut(duration: SiloTheme.fastDuration)) {
                    isEditing.toggle()
                }
            }
            .buttonStyle(TVHomeSectionsControlButtonStyle())
            .focused($focusedControl, equals: .edit)
            .disabled(model.phase != .loaded || model.rows.count < 2)

            Button(.homeProfileEditorDone, action: close)
                .buttonStyle(TVHomeSectionsControlButtonStyle())
                .focused($focusedControl, equals: .done)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.siloChromeRestingFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.siloChromeRestingBorder, lineWidth: 1)
        }
        .focusSection()
    }

    private func sectionRow(_ row: APIv2ProfileSectionSetting) -> some View {
        let isVisible = !row.hidden
        let title = row.displayTitle(in: locale)

        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .font(.system(size: 26, weight: .medium))
                    .lineLimit(1)

                Text(isVisible ? .homeProfileEditorRowShown : .homeProfileEditorRowHidden)
                    .font(.system(size: 18))
                    .foregroundStyle(Color.siloSecondaryText)
            }
            .opacity(isVisible ? 1 : 0.42)

            Spacer(minLength: 16)

            if isEditing {
                Button {
                    move(row, by: -1)
                } label: {
                    Image(systemName: "arrow.up")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(TVHomeSectionsControlButtonStyle(compact: true))
                .focused($focusedControl, equals: .moveUp(row.id))
                .disabled(!model.canMove(id: row.id, by: -1))
                .accessibilityLabel(Text(.homeProfileEditorMoveRowUp(title)))

                Button {
                    move(row, by: 1)
                } label: {
                    Image(systemName: "arrow.down")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(TVHomeSectionsControlButtonStyle(compact: true))
                .focused($focusedControl, equals: .moveDown(row.id))
                .disabled(!model.canMove(id: row.id, by: 1))
                .accessibilityLabel(Text(.homeProfileEditorMoveRowDown(title)))
            }

            Button {
                withAnimation(.easeOut(duration: SiloTheme.fastDuration)) {
                    _ = model.setHidden(isVisible, id: row.id)
                }
            } label: {
                Image(systemName: isVisible ? "eye" : "eye.slash")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(TVHomeSectionsControlButtonStyle(compact: true))
            .focused($focusedControl, equals: .visibility(row.id))
            .accessibilityLabel(Text(isVisible ? .homeProfileEditorHideRow(title) : .homeProfileEditorShowRow(title)))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.siloChromeRestingFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.siloChromeRestingBorder, lineWidth: 1)
        }
    }

    /// Moves a row and keeps focus on an enabled control of the same row: at
    /// the top or bottom edge the pressed arrow disables itself, so focus
    /// moves to the opposite arrow instead of falling out of the sheet.
    private func move(_ row: APIv2ProfileSectionSetting, by offset: Int) {
        guard let index = model.rows.firstIndex(where: { $0.id == row.id }) else { return }
        let target = index + offset
        guard model.rows.indices.contains(target) else { return }
        let retarget: FocusTarget?
        if target == 0 {
            retarget = .moveDown(row.id)
        } else if target == model.rows.count - 1 {
            retarget = .moveUp(row.id)
        } else {
            retarget = nil
        }
        withAnimation(.easeOut(duration: SiloTheme.fastDuration)) {
            _ = model.move(id: row.id, by: offset)
            if let retarget {
                focusedControl = retarget
            }
        }
        if let retarget {
            Task { @MainActor in
                await Task.yield()
                guard isEditing, !isClosing else { return }
                focusedControl = retarget
            }
        }
    }

    /// Seed focus on the always-enabled Done control as the sheet appears,
    /// so the settings rows behind the full-screen presentation never become
    /// the active graph.
    private func claimFocus() {
        guard !isClosing else { return }
        focusedControl = .done
        Task { @MainActor in
            await Task.yield()
            guard !isClosing else { return }
            resetFocus(in: editorFocusScope)
            focusedControl = .done
        }
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        dismiss()
    }
}

/// Compact in-card control chrome for the Home Sections editor. The resting
/// state keeps a dark platter and bright glyph, avoiding tvOS's default white
/// bordered-button treatment that hid the eye until focus arrived.
private struct TVHomeSectionsControlButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        TVHomeSectionsControlButtonBody(
            configuration: configuration,
            compact: compact
        )
    }
}

private struct TVHomeSectionsControlButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let compact: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: compact ? 24 : 20, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 0 : 22)
            .frame(minWidth: 64, minHeight: 64)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isFocused ? Color.siloOnSurface : Color.siloSurfaceElevated.opacity(0.9))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isFocused ? Color.clear : Color.siloChromeRestingBorder,
                        lineWidth: 1
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.04 : 1))
            .shadow(
                color: isFocused ? Color.black.opacity(0.5) : .clear,
                radius: 16,
                y: 6
            )
            .focusEffectDisabled()
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
    }

    private var foreground: Color {
        guard isEnabled else { return Color.siloSecondaryText.opacity(0.5) }
        return isFocused ? .siloBackground : .siloOnSurface
    }
}

/// Mono caps header of the Home Sections editor.
private func sectionHeader(_ title: LocalizedStringResource) -> some View {
    Text(title)
        .font(.system(size: 15, weight: .semibold, design: .monospaced))
        .tracking(2)
        .foregroundStyle(Color.siloSecondaryText)
}
#endif
