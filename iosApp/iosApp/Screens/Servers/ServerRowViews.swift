import SwiftUI

// The server list's row views. On Apple TV, Choose a Server and "Sign in
// to…" use the chooser rows in `TVUserFlowComponents` instead.

#if os(tvOS)
/// A saved server in Manage Servers: name, address, who signs in to it, and
/// the local-network line for the active server.
struct TVServerSummaryLabel: View {
    let entry: ServerEntry
    let isActive: Bool
    /// The Silo users signed in to it on this Apple TV.
    var userNames: [String] = []

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "server.rack")
                .font(.system(size: 24, weight: .medium))
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayName)
                    .font(.system(size: 26, weight: .medium))
                    .lineLimit(1)
                Text(entry.url)
                    .font(.system(size: 19))
                    .opacity(0.62)
                    .lineLimit(1)
                if !userNames.isEmpty {
                    Label(userNames.joined(separator: ", "), systemImage: "person.2")
                        .font(.system(size: 19))
                        .opacity(0.62)
                        .lineLimit(1)
                }
                if isActive, LocalRouteController.shared.isOnLocalNetwork {
                    LocalRouteStatusLine()
                        .font(.system(size: 19))
                        .opacity(0.62)
                }
            }

            Spacer(minLength: 16)

            if isActive {
                Text("Active")
                    .font(.system(size: 19, weight: .semibold))
                    .opacity(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(([isActive ? "Active" : "Saved"]
            + (userNames.isEmpty ? [] : ["Users: \(userNames.joined(separator: ", "))"]))
            .joined(separator: ", "))
    }
}
#endif

#if !os(tvOS)
/// A saved server's row on iPhone, iPad, and Mac: name, address, and the
/// local-network line for the active server.
struct ServerRowLabel: View {
    let entry: ServerEntry
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "server.rack")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.siloOnSurface)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.siloSubheadline)
                    .foregroundColor(.siloOnSurface)
                    .lineLimit(1)
                Text(entry.url)
                    .font(.siloCaption)
                    .foregroundColor(.siloSecondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                if isActive, LocalRouteController.shared.isOnLocalNetwork {
                    LocalRouteStatusLine()
                        .font(.siloCaption)
                        .foregroundColor(.siloSecondaryText)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer()
        }
        .contentShape(Rectangle())
    }
}
#endif

/// "Connected on your local network" under the active server while its
/// requests use the local route; the icon sits inline so the text starts
/// where the address above it does.
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
