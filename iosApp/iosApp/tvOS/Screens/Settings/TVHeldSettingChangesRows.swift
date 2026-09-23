#if os(tvOS)
import SwiftUI

/// tvOS settings-pane rows for changes that ran out of automatic retries
/// (owner decision D4): the change stays on this Apple TV until the user
/// sends it again or discards it. Plain buttons in the pane's native focus
/// graph.
struct TVHeldSettingChangesRows: View {
    let retry: () async -> Void
    let discard: () async -> Void

    var body: some View {
        TVSettingsSectionHeader("NOT SAVED")

        Button {
            Task { await retry() }
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 22, weight: .medium))
                Text("Try Again")
                    .font(.system(size: 26))
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(TVSettingsPaneRowStyle())

        Button {
            Task { await discard() }
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 22, weight: .medium))
                Text("Discard Held Change")
                    .font(.system(size: 26))
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(TVSettingsPaneRowStyle(isDestructive: true))

        TVSettingsWarningFooter(HeldSettingChange.message)
    }
}
#endif
