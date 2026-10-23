import SwiftUI

/// "Connected on your local network" under the current account while its
/// server's requests use the local route; the icon sits inline so the text
/// starts where the line above it does.
struct LocalRouteStatusLine: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "house.fill")
                .imageScale(.small)
            Text(LocalRouteController.statusText)
        }
        .accessibilityElement(children: .combine)
    }
}
