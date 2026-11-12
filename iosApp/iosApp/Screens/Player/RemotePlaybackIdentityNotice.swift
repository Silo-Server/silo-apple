#if os(tvOS)
import SwiftUI

struct RemotePlaybackIdentityNotice: View {
    let identity: RemotePlaybackIdentityManager.ActiveIdentity
    @Environment(\.locale) private var locale

    /// "Playing as <profile>", or the phone's profile when it sent no name.
    private var playingAsLabel: String {
        let name = identity.profileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty { return AppLanguage.string(.remotePlayingAs(name), locale: locale) }
        return AppLanguage.string(.remotePlayingAsPhoneProfile, locale: locale)
    }

    private var sourceLabel: String {
        let device = identity.controllerDeviceName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let source: String
        if let device, !device.isEmpty {
            source = AppLanguage.string(.castStandbyFrom(device), locale: locale)
        } else {
            source = AppLanguage.string(.castStandbyFromYourPhone, locale: locale)
        }
        if identity.usesDifferentServer,
           let server = identity.serverName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !server.isEmpty {
            return "\(source) · \(server)"
        }
        return source
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: SiloTheme.smallPadding) {
                Text(playingAsLabel)
                    .font(.siloSubheadline)
                    .foregroundStyle(Color.siloOnSurface)
                    .lineLimit(1)

                Text(sourceLabel)
                    .font(.siloBody)
                    .foregroundStyle(Color.siloSecondaryText)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: "iphone")
                .font(.title3)
                .foregroundStyle(Color.siloPrimary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, SiloTheme.padding)
        .padding(.vertical, SiloTheme.spacing)
        .frame(maxWidth: 720)
        .siloPlayerGlass(
            in: RoundedRectangle(cornerRadius: SiloTheme.cardCornerRadius),
            tint: Color.siloPrimary.opacity(0.24)
        )
        .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
        .padding(.horizontal, SiloTheme.safePadding)
        .padding(.top, SiloTheme.safePadding)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(playingAsLabel). \(sourceLabel)."))
    }
}
#endif
