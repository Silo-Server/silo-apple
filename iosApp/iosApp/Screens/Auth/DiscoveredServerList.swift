import SwiftUI

/// The servers `ServerDiscovery` found, one button per address. On iPhone,
/// iPad and Mac it matches the Recent list on the server screen; on Apple TV
/// it is a column of buttons beside "Enter server address". It renders
/// nothing until something is found, so a network without servers looks
/// unchanged.
struct DiscoveredServerList: View {
    let servers: [DiscoveredServer]
    let isConnecting: Bool
    let select: (DiscoveredServer) -> Void

    var body: some View {
        if !servers.isEmpty {
            list
                .disabled(isConnecting)
                .transition(.opacity)
        }
    }

    #if os(tvOS)
    private var list: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Two rows fit beside the setup steps without pushing the
            // address button off the screen.
            ForEach(servers.prefix(2)) { server in
                Button {
                    select(server)
                } label: {
                    HStack(spacing: 18) {
                        MarqueeServerMark(name: server.name, size: 52)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(server.name)
                                .font(.system(size: 28, weight: .semibold))
                                .lineLimit(1)
                            Text(server.detail)
                                .font(.system(size: 22))
                                .opacity(0.62)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .buttonStyle(.marquee(.glass, fullWidth: false))
                .accessibilityLabel("\(server.name), \(server.detail)")
            }
        }
    }
    #else
    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Found nearby")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.siloOnSurface.opacity(0.62))
                .padding(.leading, 2)
                .padding(.bottom, 10)
            VStack(spacing: 0) {
                ForEach(Array(servers.prefix(4).enumerated()), id: \.element.id) { index, server in
                    if index > 0 {
                        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                    }
                    Button {
                        select(server)
                    } label: {
                        HStack(spacing: 12) {
                            MarqueeServerMark(name: server.name, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color.siloOnSurface)
                                    .lineLimit(1)
                                Text(server.detail)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.marqueePressable)
                    .accessibilityLabel("\(server.name), \(server.detail)")
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            )
        }
    }
    #endif
}
