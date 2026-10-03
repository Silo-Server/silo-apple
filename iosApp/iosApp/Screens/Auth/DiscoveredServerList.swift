import SwiftUI

/// The servers `ServerDiscovery` found, one button per address. On iPhone,
/// iPad and Mac it uses the Recent list's rows; on Apple TV it is a column of
/// buttons beside "Enter server address". It renders nothing until something
/// is found, so a network without servers looks unchanged.
struct DiscoveredServerList: View {
    let servers: [DiscoveredServer]
    let isConnecting: Bool
    /// The row being connected to, which shows progress.
    let connectingID: DiscoveredServer.ID?
    let select: (DiscoveredServer) -> Void

    var body: some View {
        if !servers.isEmpty {
            #if os(tvOS)
            // Disabling would drop the focused row out of the focus graph
            // mid-connect; `connect(to:)` ignores repeat presses instead.
            list
                .transition(.opacity)
            #else
            list
                .disabled(isConnecting)
                .transition(.opacity)
            #endif
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
                        if connectingID == server.id {
                            ConnectingSpinner()
                                .padding(.leading, 6)
                        }
                    }
                }
                .buttonStyle(.marquee(.glass, fullWidth: false))
                .accessibilityLabel("\(server.name), \(server.detail)")
                .accessibilityValue(connectingID == server.id ? "Connecting" : "")
            }
        }
    }
    /// Inked like the row's text, which turns dark on the focused button.
    private struct ConnectingSpinner: View {
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            ProgressView()
                .tint(isFocused ? .black : Color.siloOnSurface)
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
            ServerPickerList(Array(servers.prefix(4))) { server in
                ServerPickerRow(
                    name: server.name,
                    markName: server.name,
                    detail: server.detail,
                    isConnecting: connectingID == server.id
                ) {
                    select(server)
                }
            }
        }
    }
    #endif
}

#if !os(tvOS)
/// The rounded card of server rows used by Recent and the found servers.
struct ServerPickerList<Item: Identifiable, Row: View>: View {
    private let items: [Item]
    private let row: (Item) -> Row

    init(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) {
        self.items = items
        self.row = row
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                }
                row(item)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        )
    }
}

/// One server in a `ServerPickerList`: its mark, name and address.
struct ServerPickerRow: View {
    let name: String
    /// What the mark's initial comes from; nil shows the generic mark.
    let markName: String?
    var markURL: URL?
    let detail: String
    var isConnecting = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                MarqueeServerMark(name: markName, imageURL: markURL, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.siloOnSurface)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.marqueePressable)
        .accessibilityLabel("\(name), \(detail)")
        .accessibilityValue(isConnecting ? "Connecting" : "")
    }
}
#endif
