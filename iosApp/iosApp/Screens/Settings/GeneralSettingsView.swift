#if !os(tvOS)
import SwiftUI

/// Device-local startup preferences that do not belong to playback or
/// interface customization.
struct GeneralSettingsView: View {
    @State private var launchPreferences = ProfileLaunchPreferences.shared
    @StateObject private var advisoryAgePreference = AdvisoryAgePreferenceStore.shared
    @State private var appLanguage = AppLanguagePreferences.shared

    var body: some View {
        List {
            profileSection
            if appLanguage.currentChoice != nil {
                languageSection
            }
            if advisoryAgePreference.isSupported {
                advisoryAgeSection
            }
        }
        .settingsListChrome()
        .navigationTitle(Text(.settingsGeneral))
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
        .task {
            async let advisory: Void = advisoryAgePreference.refresh()
            async let language: Void = appLanguage.refresh()
            _ = await (advisory, language)
        }
    }

    private var profileSection: some View {
        Section {
            Picker(.settingsControlProfileSelection, selection: $launchPreferences.behavior) {
                ForEach(ProfileLaunchBehavior.allCases) { behavior in
                    Text(behavior.title)
                        .accessibilityHint(Text(behavior.standardDescription))
                        .tag(behavior)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            .settingsPickerStyle()
            .accessibilityValue(Text(launchPreferences.behavior.title))
            .accessibilityHint(Text(launchPreferences.behavior.standardDescription))
        } header: {
            Text(.settingsGeneralProfilesHeader)
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            Text(launchPreferences.behavior.standardDescription)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private var languageSection: some View {
        Section {
            Picker(
                .settingsAppLanguageTitle,
                selection: Binding(
                    get: { appLanguage.currentChoice?.tag ?? "" },
                    set: { id in Task { await appLanguage.select(id.isEmpty ? nil : id) } }
                )
            ) {
                ForEach(appLanguage.options) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            .settingsPickerStyle()
            .disabled(appLanguage.isBusy)
            .accessibilityValue(Text(appLanguage.selectedLabel))
        } header: {
            Text(.settingsAppLanguageHeader)
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(appLanguage.footer)
                if let message = appLanguage.errorMessage {
                    Text(message)
                }
            }
            .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private var advisoryAgeSection: some View {
        Section {
            Toggle(
                .settingsGeneralShowAdvisoryAge,
                isOn: Binding(
                    get: { advisoryAgePreference.showsAdvisoryAge },
                    set: { value in
                        Task { await advisoryAgePreference.setShowsAdvisoryAge(value) }
                    }
                )
            )
            .foregroundStyle(Color.siloOnSurface)
            .tint(.siloSwitchOn)
            .disabled(advisoryAgePreference.isSaving)
        } header: {
            Text(.settingsGeneralRatingsHeader)
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(.settingsGeneralShowAdvisoryAgeFooter)
                if let writeError = advisoryAgePreference.writeError {
                    Text(verbatim: writeError)
                }
            }
            .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
    }
}
#endif
