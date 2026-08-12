#if !os(tvOS)
import SwiftUI

/// Device-local startup preferences that do not belong to playback or
/// interface customization.
struct GeneralSettingsView: View {
    @State private var launchPreferences = ProfileLaunchPreferences.shared

    var body: some View {
        List {
            SettingsPageHeader(
                title: "General",
                subtitle: "Choose how Silo starts on this device.",
                systemImage: "gearshape.fill",
                tint: .purple
            )
            .settingsPageHeaderRow()

            profileSection
        }
        .settingsListChrome()
        .navigationTitle("")
        .continuumNavigationTitleDisplayMode(.inline)
        .continuumToolbarColorSchemeDark()
    }

    private var profileSection: some View {
        Section {
            Picker("Profile at Launch", selection: $launchPreferences.behavior) {
                ForEach(ProfileLaunchBehavior.allCases) { behavior in
                    Text(behavior.title).tag(behavior)
                }
            }
            .foregroundStyle(Color.continuumOnSurface)
            #if os(macOS)
            .pickerStyle(.menu)
            #else
            .pickerStyle(.navigationLink)
            #endif
            .accessibilityHint(launchPreferences.behavior.standardDescription)
        } header: {
            Text("Profiles")
                .foregroundStyle(Color.continuumSecondaryText)
        } footer: {
            Text(launchPreferences.behavior.standardDescription)
                .foregroundStyle(Color.continuumSecondaryText)
        }
        .listRowBackground(Color.continuumSurfaceElevated)
    }
}
#endif
