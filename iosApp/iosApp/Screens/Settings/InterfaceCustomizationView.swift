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
                        "This device has older device-specific interface settings that override family sync.",
                        systemImage: "iphone.and.arrow.forward"
                    )
                    Button("Use Synced \(familySettingsName) Settings") {
                        preferences.useFamilySettings()
                    }
                    .disabled(preferences.isSaving || !preferences.allowsEditing)
                } footer: {
                    Text("Clearing the device override makes the controls below apply to all like-family devices on this profile.")
                }
            }

            Section {
                Picker("Poster Size", selection: posterSize) {
                    ForEach(CardPosterSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }

                if preferences.cardPresentationUsesFamilyOverride {
                    Button("Use Profile Default") {
                        preferences.resetCardPresentationToInherited()
                    }
                    .disabled(preferences.isSaving)
                }
            } header: {
                Text("Cards & Posters")
            } footer: {
                Text("Poster size syncs with other \(familyLabel) devices on this profile.")
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
        .navigationTitle("Interface")
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

    private var familyLabel: String {
        switch AppleDeviceIdentity.current.clientFamily {
        case "mobile": return "iPhone-like"
        case "tablet": return "tablet-like"
        case "desktop": return "desktop-like"
        default: return "similar"
        }
    }

    private var familySettingsName: String {
        switch AppleDeviceIdentity.current.clientFamily {
        case "mobile": return "Mobile"
        case "tablet": return "Tablet"
        case "desktop": return "Desktop"
        default: return "Family"
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
                title: "Show Title Art",
                subtitle: "Use logo artwork as the title when available.",
                systemImage: "photo.artframe",
                isOn: Binding(
                    get: { preferences.showsTitleArt },
                    set: { preferences.setShowTitleArt($0) }
                )
            )
            TitlePagesToggleRow(
                title: "Apply to All Devices",
                subtitle: "Use this choice everywhere on this profile.",
                systemImage: "laptopcomputer.and.iphone",
                isOn: Binding(
                    get: { preferences.appliesToAllDevices },
                    set: { preferences.setAppliesToAllDevices($0) }
                )
            )
            if preferences.appliesToAllDevices {
                Label(
                    "Title art is \(preferences.showsTitleArt ? "on" : "off") on every device signed into this profile. Changing it here changes it everywhere.",
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
            Text("Title Pages")
        } footer: {
            if preferences.appliesToAllDevices {
                Text("Turn off Apply to All Devices to choose for this \(TitlePagesDevice.noun) only.")
            } else {
                Text("Only affects this \(TitlePagesDevice.noun). Your other devices keep their own setting.")
            }
        }
        .disabled(!preferences.allowsEditing)
    }
}

/// What the "this device" footers call the device.
private enum TitlePagesDevice {
    static var noun: String {
        switch AppleDeviceIdentity.current.clientFamily {
        case "tablet": return "iPad"
        case "desktop": return "Mac"
        case "tv": return "Apple TV"
        default: return "iPhone"
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
                title: "Play Theme Music",
                subtitle: "Play a title's theme song from your library while its page is open.",
                systemImage: "music.note",
                isOn: Binding(
                    get: { preferences.playsThemeMusic },
                    set: { preferences.setEnabled($0) }
                )
            )
            TitlePagesToggleRow(
                title: "Loop Theme Music",
                subtitle: "Repeat the theme while the page stays open.",
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
            Text("Theme Music")
        } footer: {
            Text("Only affects this \(TitlePagesDevice.noun).")
        }
        .disabled(!preferences.allowsEditing)
    }
}

/// The Settings overview toggle on iPhone and iPad; a plain labeled toggle on
/// the Mac, which has no overview row style.
private struct TitlePagesToggleRow: View {
    let title: String
    let subtitle: String
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
