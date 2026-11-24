#if os(iOS)
import SwiftUI

struct SettingsOverviewToggleRow: View {
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 14) {
                SettingsIconTile(systemImage: systemImage)

                Text(title)
                    .foregroundStyle(Color.siloOnSurface)
            }
        }
        .tint(.siloSwitchOn)
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(subtitle))
    }
}
#endif
