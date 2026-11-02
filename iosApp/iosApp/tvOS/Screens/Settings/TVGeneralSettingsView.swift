#if os(tvOS)
import SwiftUI

/// Family-synced tvOS interface preferences. Every control is a native focus
/// target and never intercepts directional movement, preserving the stable
/// focus graph described in `docs/tvos-focus.md`.
struct TVGeneralSettingsPane: View {
    @State private var preferences = UICustomizationPreferences.shared
    @State private var titleArt = TitleArtPreferences.shared
    @State private var themeMusic = ThemeMusicPreferences.shared
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
            TVSettingsSectionHeader("APPLE TV USER")

            TVSettingsPickerRow(
                title: "Paired Silo Profile",
                value: pairedProfileName,
                action: changePairedProfile
            )
            .focused(detailFocus, equals: .generalAppleTVUser)

            TVSettingsFooter(pairingDescription)

            TVSettingsSectionHeader("PROFILE AT LAUNCH")

            TVSettingsPickerRow(
                title: "Profile Selection",
                value: launchPreferences.behavior.title
            ) { activePicker = .profileLaunch }
            .focused(detailFocus, equals: .generalProfileLaunch)
            .accessibilityHint(launchPreferences.behavior.tvDescription)

            TVSettingsFooter(launchPreferences.behavior.tvDescription)

            if titleArt.isOffered {
                titleArtGroup
            }

            if themeMusic.isOffered {
                themeMusicGroup
            }

            if let message = preferences.capabilityMessage {
                TVSettingsSectionHeader("SERVER SUPPORT")
                TVSettingsFooter(message)
            }

            if preferences.hasDeviceOverrides {
                TVSettingsSectionHeader("SYNC SOURCE")
                if preferences.cardPresentationUsesDeviceOverride {
                    familySettingsButton
                        .focused(detailFocus, equals: .generalPosterSize)
                } else {
                    familySettingsButton
                }
                TVSettingsFooter("This Apple TV has older device-specific settings. Clear them to use the TV-family choices shared by this profile.")
            }

            TVSettingsSectionHeader("CARDS & POSTERS")

            if advisoryAgePreference.isSupported {
                TVSettingsToggleRow(
                    title: "Show Advisory Age",
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

                TVSettingsFooter("Show a suggested minimum viewer age, such as Common Sense Media’s, on movie and show details. This does not change what the profile may watch.")
                if let writeError = advisoryAgePreference.writeError {
                    TVSettingsFooter(writeError)
                }
            }

            posterSizeRow

            if preferences.cardPresentationUsesFamilyOverride {
                Button("Use Profile Default") {
                    preferences.resetCardPresentationToInherited()
                }
                .buttonStyle(TVSettingsPaneRowStyle())
                .disabled(preferences.isSaving || !preferences.allowsEditing)
            }

            TVSettingsFooter("Poster size syncs with other TV-family devices on this profile.")

            if let message = preferences.syncErrorMessage,
               message != preferences.capabilityMessage,
               message != HeldSettingChange.message {
                TVSettingsFooter(message)
            }
            if preferences.hasHeldChanges {
                TVHeldSettingChangesRows(
                    retry: { preferences.retryHeldChanges() },
                    discard: { await preferences.discardHeldChanges() }
                )
            }

            TVSettingsSectionHeader("TOP MENU")

            TVSettingsToggleRow(
                title: "Show Audiobooks",
                isOn: navPrefs.showAudiobooks
            ) {
                navPrefs.setShowAudiobooks(!navPrefs.showAudiobooks)
            }
            .focused(detailFocus, equals: .generalTopMenu)

            TVSettingsFooter("Adds an Audiobooks tab when an audiobook library is available.")
        }
        .fullScreenCover(item: $activePicker) { picker in
            pickerSheet(for: picker)
        }
        .task {
            async let preferencesRefresh: Void = preferences.refresh()
            async let titleArtRefresh: Void = titleArt.refresh()
            async let advisoryRefresh: Void = advisoryAgePreference.refresh()
            async let themeMusicRefresh: Void = themeMusic.refresh()
            _ = await (preferencesRefresh, titleArtRefresh, advisoryRefresh, themeMusicRefresh)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                async let preferencesRefresh: Void = preferences.refresh()
                async let titleArtRefresh: Void = titleArt.refresh()
                async let themeMusicRefresh: Void = themeMusic.refresh()
                _ = await (preferencesRefresh, titleArtRefresh, themeMusicRefresh)
            }
        }
    }

    /// Title art (`ui.title_art`) and its "Apply to All Devices" companion.
    /// See `TitleArtPreferences` for the scopes each row writes.
    @ViewBuilder
    private var titleArtGroup: some View {
        TVSettingsSectionHeader("TITLE PAGES")

        TVSettingsToggleRow(
            title: "Show Title Art",
            isOn: titleArt.showsTitleArt
        ) {
            titleArt.setShowTitleArt(!titleArt.showsTitleArt)
        }
        .accessibilityHint("Use logo artwork as the title when available.")
        .disabled(!titleArt.allowsEditing)

        TVSettingsToggleRow(
            title: "Apply to All Devices",
            isOn: titleArt.appliesToAllDevices
        ) {
            titleArt.setAppliesToAllDevices(!titleArt.appliesToAllDevices)
        }
        .accessibilityHint("Use this choice everywhere on this profile.")
        .disabled(!titleArt.allowsEditing)

        if titleArt.appliesToAllDevices {
            TVSettingsFooter("Title art is \(titleArt.showsTitleArt ? "on" : "off") on every device signed into this profile. Changing it here changes it everywhere. Turn off Apply to All Devices to choose for this Apple TV only.")
        } else {
            TVSettingsFooter("Use logo artwork as the title when available. Only affects this Apple TV. Your other devices keep their own setting.")
        }
        if let message = titleArt.errorMessage ?? titleArt.readErrorMessage {
            TVSettingsFooter(message)
        }
    }

    /// Theme music on title pages, written as this Apple TV's choice. See
    /// `ThemeMusicPreferences`.
    @ViewBuilder
    private var themeMusicGroup: some View {
        TVSettingsSectionHeader("THEME MUSIC")

        TVSettingsToggleRow(
            title: "Play Theme Music",
            isOn: themeMusic.playsThemeMusic
        ) {
            themeMusic.setEnabled(!themeMusic.playsThemeMusic)
        }
        .accessibilityHint("Play a title's theme song from your library while its page is open.")
        .disabled(!themeMusic.allowsEditing)

        TVSettingsToggleRow(
            title: "Loop Theme Music",
            isOn: themeMusic.loops
        ) {
            themeMusic.setLoop(!themeMusic.loops)
        }
        .accessibilityHint("Repeat the theme while the page stays open.")
        .disabled(!themeMusic.allowsEditing || !themeMusic.playsThemeMusic)

        TVSettingsFooter("Play a title's theme song from your library while its page is open. Only affects this Apple TV.")
        if let message = themeMusic.errorMessage {
            TVSettingsFooter(message)
        }
    }

    private var pairedProfileName: String {
        guard let serverID = registry.activeServerId,
              let remembered = launchPreferences.rememberedProfile(for: serverID) else {
            return "Not paired"
        }
        guard let activeProfile,
              activeProfile.id == remembered.profileID else {
            return "Saved profile"
        }
        return activeProfile.name
    }

    private var pairingDescription: String {
        let base = appleTVUserContext.pairingDescription
        guard launchPreferences.behavior == .askEveryLaunch else { return base }
        return "\(base) Ask Every Time is on, so Silo will still show Who's Watching at launch."
    }

    @ViewBuilder
    private var posterSizeRow: some View {
        let row = TVSettingsPickerRow(
            title: "Poster Size",
            value: preferences.cardPresentation.posterSize.title
        ) { activePicker = .posterSize }

        if preferences.cardPresentationUsesDeviceOverride || !preferences.allowsEditing {
            row.disabled(true)
        } else {
            row.focused(detailFocus, equals: .generalPosterSize)
        }
    }

    private var familySettingsButton: some View {
        Button("Use Synced TV Settings") {
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
                title: "Profile Selection",
                options: TVSettingsOptions.profileLaunch,
                selection: $launchPreferences.behaviorID
            )
        case .posterSize:
            TVSettingsPickerSheet(
                title: "Poster Size",
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
                disabledMessage: preferences.capabilityMessage
            )
        }
    }

    private enum PickerKind: String, Identifiable {
        case profileLaunch
        case posterSize
        var id: String { rawValue }
    }
}
#endif
