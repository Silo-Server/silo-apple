#if os(tvOS)
import SwiftUI

/// Editorial section header below the detail hero.
struct TVSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 36, weight: .semibold))
            .foregroundColor(.siloOnSurface)
    }
}
#endif
