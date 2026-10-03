import SwiftUI

/// The servers `ServerDiscovery` found, as one button per address. Shared by
/// the iOS/macOS setup form and the tvOS manual-entry card; renders nothing
/// until something is found, so a network without servers looks unchanged.
struct DiscoveredServerList: View {
    let servers: [DiscoveredServer]
    let isConnecting: Bool
    let select: (DiscoveredServer) -> Void

    #if os(tvOS)
    // The tvOS manual-entry card has a fixed height.
    private let maxVisible = 2
    private let titleSize: CGFloat = 24
    private let detailSize: CGFloat = 18
    private let iconSize: CGFloat = 26
    #else
    private let maxVisible = 5
    private let titleSize: CGFloat = 16
    private let detailSize: CGFloat = 13
    private let iconSize: CGFloat = 17
    #endif

    var body: some View {
        if !servers.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                label
                ForEach(servers.prefix(maxVisible)) { server in
                    Button {
                        select(server)
                    } label: {
                        row(server)
                    }
                    .buttonStyle(AuroraGhostButtonStyle())
                    .disabled(isConnecting)
                    .accessibilityLabel("\(server.name), \(server.detail)")
                }
            }
            .transition(.opacity)
        }
    }

    private var label: some View {
        Text("FOUND ON YOUR NETWORKS")
            .font(.system(size: detailSize - 2, weight: .semibold, design: .monospaced))
            .tracking(1.6)
            .foregroundStyle(Color.auroraInkTertiary)
    }

    private func row(_ server: DiscoveredServer) -> some View {
        HStack(spacing: 14) {
            Image(systemName: server.route == .localNetwork ? "wifi" : "network.badge.shield.half.filled")
                .font(.system(size: iconSize, weight: .medium))
                .frame(width: iconSize + 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.system(size: titleSize, weight: .semibold))
                    .lineLimit(1)
                Text(server.detail)
                    .font(.system(size: detailSize))
                    .opacity(0.75)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
