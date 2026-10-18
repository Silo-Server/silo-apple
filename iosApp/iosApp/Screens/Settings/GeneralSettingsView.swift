#if !os(tvOS)
import SwiftUI

/// Device-local startup preferences that do not belong to playback or
/// interface customization.
struct GeneralSettingsView: View {
    @State private var launchPreferences = ProfileLaunchPreferences.shared
    @StateObject private var advisoryAgePreference = AdvisoryAgePreferenceStore.shared
    @Environment(AppRouter.self) private var router

    var body: some View {
        List {
            profileSection
            // Ask For only matters with two or more Silo users (spec §5.7).
            if router.users.directory.users.count >= 2 {
                askForSection
            }
            if advisoryAgePreference.isSupported {
                advisoryAgeSection
            }
        }
        .settingsListChrome()
        .navigationTitle("General")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
        .task { await advisoryAgePreference.refresh() }
        .task { await router.users.reloadDirectory() }
    }

    /// What Silo asks for when it asks who's watching (spec §6.3). Automatic
    /// never asks, so there the setting is dimmed and says when it applies.
    private var askForSection: some View {
        let isActive = launchPreferences.behavior != .automatic
        return Section {
            Picker("Ask For", selection: $launchPreferences.askFor) {
                ForEach(ProfileLaunchAskFor.allCases) { option in
                    Text(option.title)
                        .accessibilityHint(option.standardDescription)
                        .tag(option)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            .settingsPickerStyle()
            .disabled(!isActive)
            .accessibilityValue(launchPreferences.askFor.title)
            .accessibilityHint(isActive ? launchPreferences.askFor.standardDescription
                                        : ProfileLaunchAskFor.inactiveUnderAutomaticFooter)
        } footer: {
            Text(isActive ? launchPreferences.askFor.standardDescription : ProfileLaunchAskFor.inactiveUnderAutomaticFooter)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
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
