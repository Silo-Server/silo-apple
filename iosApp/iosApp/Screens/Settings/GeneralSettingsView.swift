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
        .navigationTitle("General")
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
            Picker("Profile Selection", selection: $launchPreferences.behavior) {
                ForEach(ProfileLaunchBehavior.allCases) { behavior in
                    Text(behavior.title)
                        .accessibilityHint(behavior.standardDescription)
                        .tag(behavior)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            .settingsPickerStyle()
            .accessibilityValue(launchPreferences.behavior.title)
            .accessibilityHint(launchPreferences.behavior.standardDescription)
        } header: {
            Text("Profiles")
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
                "App Language",
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
            .disabled(appLanguage.isSaving)
            .accessibilityValue(appLanguage.selectedLabel)
        } header: {
            Text("Language")
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
                "Show Advisory Age",
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
            Text("Ratings")
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Show a suggested minimum viewer age, such as Common Sense Media’s, on movie and show details. This does not change what the profile may watch.")
                if let writeError = advisoryAgePreference.writeError {
                    Text(writeError)
                }
            }
            .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
    }
}
#endif
