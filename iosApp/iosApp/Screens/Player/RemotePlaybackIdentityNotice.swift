#if os(tvOS)
import SwiftUI

struct RemotePlaybackIdentityNotice: View {
    let identity: RemotePlaybackIdentityManager.ActiveIdentity

    private var profileLabel: String {
        let name = identity.profileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty { return name }
        return "your phone's profile"
    }

    private var sourceLabel: String {
        let device = identity.controllerDeviceName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let source: String
        if let device, !device.isEmpty {
            source = device
        } else {
            source = "your phone"
        }
        if identity.usesDifferentServer,
           let server = identity.serverName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !server.isEmpty {
            return "From \(source) · \(server)"
        }
        return "From \(source)"
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: ContinuumTheme.smallPadding) {
                Text("Playing as \(profileLabel)")
                    .font(.continuumSubheadline)
                    .foregroundStyle(Color.continuumOnSurface)
                    .lineLimit(1)

                Text(sourceLabel)
                    .font(.continuumBody)
                    .foregroundStyle(Color.continuumSecondaryText)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: "iphone")
                .font(.title3)
                .foregroundStyle(Color.continuumPrimary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, ContinuumTheme.padding)
        .padding(.vertical, ContinuumTheme.spacing)
        .frame(maxWidth: 720)
        .siloPlayerGlass(
            in: RoundedRectangle(cornerRadius: ContinuumTheme.cardCornerRadius),
            tint: Color.continuumPrimary.opacity(0.24)
        )
        .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
        .padding(.horizontal, ContinuumTheme.safePadding)
        .padding(.top, ContinuumTheme.safePadding)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playing as \(profileLabel). \(sourceLabel).")
    }
}
#endif
