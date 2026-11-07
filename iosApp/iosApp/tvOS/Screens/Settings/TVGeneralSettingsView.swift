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
#endif
