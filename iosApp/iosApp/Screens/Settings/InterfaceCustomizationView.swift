#if !os(tvOS)
import SwiftUI

/// Family-synced card presets plus title art and theme music for iPhone,
/// iPad, and Mac. The navigation itself is fixed.
struct InterfaceCustomizationView: View {
    @State private var preferences = UICustomizationPreferences.shared
    @State private var titleArt = TitleArtPreferences.shared
    @State private var themeMusic = ThemeMusicPreferences.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            if titleArt.isOffered {
                TitleArtSettingsSection(preferences: titleArt)
            }

            if themeMusic.isOffered {
                ThemeMusicSettingsSection(preferences: themeMusic)
            }

            if let message = preferences.capabilityMessage {
                Section {
                    Label(message, systemImage: "server.rack")
                        .foregroundStyle(Color.siloSecondaryText)
                }
            }

            if preferences.hasDeviceOverrides {
                Section {
                    Label(
                        .settingsInterfaceDeviceOverride,
                        systemImage: "iphone.and.arrow.forward"
                    )
                    Button(DeviceFamily.current.useSyncedSettings) {
                        preferences.useFamilySettings()
                    }
                    .disabled(preferences.isSaving || !preferences.allowsEditing)
                } footer: {
                    Text(.settingsInterfaceDeviceOverrideFooter)
                }
            }

            Section {
                Picker(.settingsCardsPosterSize, selection: posterSize) {
                    ForEach(CardPosterSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }

                if preferences.cardPresentationUsesFamilyOverride {
                    Button(.settingsCardsUseProfileDefault) {
                        preferences.resetCardPresentationToInherited()
                    }
                    .disabled(preferences.isSaving)
                }
            } header: {
                Text(.settingsCardsTitle)
            } footer: {
                Text(DeviceFamily.current.posterSizeSyncs)
            }
            .disabled(
                !preferences.allowsEditing
                    || preferences.cardPresentationUsesDeviceOverride
            )

            if let message = preferences.syncErrorMessage,
               message != preferences.capabilityMessage,
               message != HeldSettingChange.message {
                Section {
                    Label(message, systemImage: "icloud.slash")
                        .font(.footnote)
                        .foregroundStyle(Color.siloSecondaryText)
                }
            }
            if preferences.hasHeldChanges {
                HeldSettingChangesSection(
                    retry: { preferences.retryHeldChanges() },
                    discard: { await preferences.discardHeldChanges() }
                )
            }
        }
        #if os(macOS)
        .settingsListChrome()
        #else
        .siloGroupedListStyle()
        #endif
        .navigationTitle(Text(.settingsInterfaceTitle))
        .task {
            async let preferencesRefresh: Void = preferences.refresh()
            async let titleArtRefresh: Void = titleArt.refresh()
            async let themeMusicRefresh: Void = themeMusic.refresh()
            _ = await (preferencesRefresh, titleArtRefresh, themeMusicRefresh)
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

    private var posterSize: Binding<CardPosterSize> {
        Binding(
            get: { preferences.cardPresentation.posterSize },
            set: { preferences.setPosterSize($0) }
        )
    }

}

/// The settings family this device syncs card settings with, and the
/// whole-sentence texts that name it.
private enum DeviceFamily {
    case mobile, tablet, desktop, other

    static var current: DeviceFamily {
        switch AppleDeviceIdentity.current.clientFamily {
        case "mobile": return .mobile
        case "tablet": return .tablet
        case "desktop": return .desktop
        default: return .other
        }
    }

    var useSyncedSettings: LocalizedStringResource {
        switch self {
        case .mobile: return .settingsInterfaceUseSyncedMobile
        case .tablet: return .settingsInterfaceUseSyncedTablet
        case .desktop: return .settingsInterfaceUseSyncedDesktop
        case .other: return .settingsInterfaceUseSyncedFamily
        }
    }

    var posterSizeSyncs: LocalizedStringResource {
        switch self {
        case .mobile: return .settingsInterfacePosterSizeSyncsMobile
        case .tablet: return .settingsInterfacePosterSizeSyncsTablet
        case .desktop: return .settingsInterfacePosterSizeSyncsDesktop
        case .other: return .settingsInterfacePosterSizeSyncsOther
        }
    }
}

/// "Title Pages": whether detail pages name a title with its logo art, and
/// whether that choice is this device's own or the profile's for every device.
/// See `TitleArtPreferences` for the scopes each switch writes.
private struct TitleArtSettingsSection: View {
    let preferences: TitleArtPreferences

    var body: some View {
        Section {
            TitlePagesToggleRow(
                title: .settingsControlTitleArt,
                subtitle: .settingsTitleArtFooter,
                systemImage: "photo.artframe",
                isOn: Binding(
                    get: { preferences.showsTitleArt },
                    set: { preferences.setShowTitleArt($0) }
                )
            )
            TitlePagesToggleRow(
                title: .settingsInterfaceApplyToAllDevices,
                subtitle: .settingsInterfaceApplyToAllDevicesSubtitle,
                systemImage: "laptopcomputer.and.iphone",
                isOn: Binding(
                    get: { preferences.appliesToAllDevices },
                    set: { preferences.setAppliesToAllDevices($0) }
                )
            )
            if preferences.appliesToAllDevices {
                Label(
                    preferences.showsTitleArt
                        ? LocalizedStringResource.settingsInterfaceTitleArtAllOn
                        : .settingsInterfaceTitleArtAllOff,
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(Color.siloSecondaryText)
            }
            if let message = preferences.errorMessage ?? preferences.readErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Color.siloSecondaryText)
            }
        } header: {
            Text(.settingsTitleArtTitle)
        } footer: {
            if preferences.appliesToAllDevices {
                Text(TitlePagesDevice.current.applyToAllFooter)
            } else {
                Text(TitlePagesDevice.current.onlyThisDeviceFooter)
            }
        }
        .disabled(!preferences.allowsEditing)
    }
}

/// The device the "this device" footers name. Each footer is one whole
/// sentence per device, so translators can fit the device's name to it.
private enum TitlePagesDevice {
    case iPhone, iPad, mac, appleTV

    static var current: TitlePagesDevice {
        switch AppleDeviceIdentity.current.clientFamily {
        case "tablet": return .iPad
        case "desktop": return .mac
        case "tv": return .appleTV
        default: return .iPhone
        }
    }

    var applyToAllFooter: LocalizedStringResource {
        switch self {
        case .iPhone: return .settingsInterfaceApplyToAllFooterIphone
        case .iPad: return .settingsInterfaceApplyToAllFooterIpad
        case .mac: return .settingsInterfaceApplyToAllFooterMac
        case .appleTV: return .settingsInterfaceApplyToAllFooterAppleTv
        }
    }

    var onlyThisDeviceFooter: LocalizedStringResource {
        switch self {
        case .iPhone: return .settingsInterfaceOnlyThisDeviceFooterIphone
        case .iPad: return .settingsInterfaceOnlyThisDeviceFooterIpad
        case .mac: return .settingsInterfaceOnlyThisDeviceFooterMac
        case .appleTV: return .settingsInterfaceOnlyThisDeviceFooterAppleTv
        }
    }

    var themeMusicFooter: LocalizedStringResource {
        switch self {
        case .iPhone: return .settingsInterfaceThemeMusicFooterIphone
        case .iPad: return .settingsInterfaceThemeMusicFooterIpad
        case .mac: return .settingsInterfaceThemeMusicFooterMac
        case .appleTV: return .settingsInterfaceThemeMusicFooterAppleTv
        }
    }
}

/// "Theme Music": local theme songs on title pages, written as this device's
/// choice. See `ThemeMusicPreferences`.
private struct ThemeMusicSettingsSection: View {
    let preferences: ThemeMusicPreferences

    var body: some View {
        Section {
            TitlePagesToggleRow(
                title: .settingsControlThemeMusic,
                subtitle: .settingsInterfacePlayThemeMusicSubtitle,
                systemImage: "music.note",
                isOn: Binding(
                    get: { preferences.playsThemeMusic },
                    set: { preferences.setEnabled($0) }
                )
            )
            TitlePagesToggleRow(
                title: .settingsControlThemeMusicLoop,
                subtitle: .settingsInterfaceLoopThemeMusicSubtitle,
                systemImage: "repeat",
                isOn: Binding(
                    get: { preferences.loops },
                    set: { preferences.setLoop($0) }
                )
            )
            .disabled(!preferences.playsThemeMusic)
            if let message = preferences.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Color.siloSecondaryText)
            }
        } header: {
            Text(.settingsSectionThemeMusic)
        } footer: {
            Text(TitlePagesDevice.current.themeMusicFooter)
        }
        .disabled(!preferences.allowsEditing)
    }
}

/// The Settings overview toggle on iPhone and iPad; a plain labeled toggle on
/// the Mac, which has no overview row style.
private struct TitlePagesToggleRow: View {
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        #if os(iOS)
        SettingsOverviewToggleRow(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            isOn: $isOn
        )
        #else
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Color.siloSecondaryText)
            }
        }
        #endif
    }
}
#endif
