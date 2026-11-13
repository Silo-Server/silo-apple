#if !os(tvOS)
import SwiftUI

/// "Spoilers" group for the iOS and macOS playback settings. The switches
/// belong to the profile on the server, so they follow the profile to every
/// device and are not touched by the device-override reset. The host shows
/// this only when `EpisodeSpoilerPreferences.showsSettings` is true.
struct EpisodeSpoilerSettingsSection: View {
    let store: EpisodeSpoilerPreferences
    /// The app language, so a switch re-renders the footer.
    @Environment(\.locale) private var locale

    var body: some View {
        Section {
            toggle(
                .images,
                title: .settingsManifestCatalogHideUnwatchedEpisodeImagesLabel,
                description: .settingsManifestCatalogHideUnwatchedEpisodeImagesDescription
            )
            toggle(
                .overviews,
                title: .settingsManifestCatalogHideUnwatchedEpisodeOverviewsLabel,
                description: .settingsManifestCatalogHideUnwatchedEpisodeOverviewsDescription
            )
        } header: {
            Text(.settingsSectionSpoilers)
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            Text(verbatim: footerText)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private func toggle(
        _ setting: EpisodeSpoilerSetting,
        title: LocalizedStringResource,
        description: LocalizedStringResource
    ) -> some View {
        Toggle(isOn: Binding(
            get: { store.settings[setting] },
            set: { store.set(setting, to: $0) }
        )) {
            Text(title)
                .foregroundStyle(Color.siloOnSurface)
            Text(description)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .tint(.siloSwitchOn)
        .disabled(!store.allowsEditing)
    }

    /// The scope note, then whatever keeps the switches from saving, then any
    /// failed save, one line each.
    private var footerText: String {
        var lines = [AppLanguage.string(.settingsSpoilersFooter, locale: locale)]
        if let status = store.statusMessage {
            lines.append(status)
        }
        for setting in EpisodeSpoilerSetting.allCases {
            if let error = store.writeErrors[setting.key] {
                lines.append(error)
            }
        }
        return lines.joined(separator: "\n")
    }
}
#endif
