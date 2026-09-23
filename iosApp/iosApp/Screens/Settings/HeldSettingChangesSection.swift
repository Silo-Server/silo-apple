#if !os(tvOS)
import SwiftUI

/// The actions for settings changes that ran out of automatic retries
/// (owner decision D4): the change stays on this device until the user sends
/// it again or discards it.
struct HeldSettingChangesSection: View {
    let retry: () async -> Void
    let discard: () async -> Void

    var body: some View {
        Section {
            Button("Try Again") {
                Task { await retry() }
            }
            Button("Discard Held Change", role: .destructive) {
                Task { await discard() }
            }
        } header: {
            Text("Not Saved")
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            Text(HeldSettingChange.message)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloSurfaceElevated)
    }
}
#endif
