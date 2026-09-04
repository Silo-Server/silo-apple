#if os(iOS)
import SwiftUI

struct SettingsOverviewDivider: View {
    var body: some View {
        Divider()
            .overlay(Color.siloDivider)
            .padding(.leading, 66)
    }
}
#endif
