import SwiftUI

/// Plain black canvas shared by the native Settings experiences, so grouped
/// rows and focus platters carry all of the contrast.
struct SettingsBackdrop: View {
    var body: some View {
        Color.siloBackground
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
