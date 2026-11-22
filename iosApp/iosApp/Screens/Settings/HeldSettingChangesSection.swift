#if !os(tvOS)
import SwiftUI

/// The actions for settings changes that ran out of automatic retries: the
/// change stays on this device until the user sends it again or discards it.
struct HeldSettingChangesSection: View {
    let retry: () async -> Void
    let discard: () async -> Void
    var message: String = HeldSettingChange.message

    var body: some View {
        Section {
            Button(.settingsHeldChangeTryAgain) {
                Task { await retry() }
            }
            Button(.settingsHeldChangeDiscard, role: .destructive) {
                Task { await discard() }
            }
        } header: {
            Text(.settingsHeldChangeHeader)
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            Text(verbatim: message)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
    }
}
#endif
