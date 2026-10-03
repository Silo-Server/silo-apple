#if !os(tvOS)
import SwiftUI

/// Device-local startup preferences that do not belong to playback or
/// interface customization.
struct GeneralSettingsView: View {
    @State private var launchPreferences = ProfileLaunchPreferences.shared
    @StateObject private var advisoryAgePreference = AdvisoryAgePreferenceStore.shared

    var body: some View {
        List {
            profileSection
            if advisoryAgePreference.isSupported {
                advisoryAgeSection
            }
        }
        .settingsListChrome()
        .navigationTitle("General")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
        .task { await advisoryAgePreference.hydrateIfNeeded() }
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
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif
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
            .disabled(advisoryAgePreference.isSaving)
        } header: {
            Text("Ratings")
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            Text("Show a suggested minimum viewer age, such as Common Sense Media’s, on movie and show details. This does not change what the profile may watch.")
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
    }
}
#endif
