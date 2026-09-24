#if os(iOS) || os(tvOS)
import SwiftUI

/// The invitation: a large code, a QR for phones, and share/copy on iOS.
struct WatchPartyInviteView: View {
    let session: WatchPartySession
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @State private var copied: String?
    #endif

    var body: some View {
        ZStack {
            #if os(tvOS)
            WatchPartyBackdrop(url: session.selectedItem?.backdropUrl,
                               thumbhash: session.selectedItem?.backdropThumbhash)
                .ignoresSafeArea()
            tvLayout
            #else
            Color.siloBackground.ignoresSafeArea()
            ScrollView { phoneLayout }
            #endif
        }
        #if os(tvOS)
        .onExitCommand { dismiss() }
        #endif
    }

    #if os(iOS)
    private var heading: some View {
        VStack(spacing: 8) {
            WatchPartyEyebrow(text: "Invite friends")
            Text("Join with this code")
                .font(.system(size: WatchPartyMetrics.heroTitle * 0.8, weight: .bold))
                .foregroundStyle(Color.siloOnSurface)
            Text("Anyone with a profile on this Silo server can enter it from Watch Party.")
                .font(.system(size: WatchPartyMetrics.body))
                .foregroundStyle(Color.siloSecondaryText)
        }
    }
    #endif

    private func codeText(_ code: String) -> some View {
        Text(code)
            .font(.system(size: codeSize, weight: .bold, design: .monospaced))
            .tracking(codeSize * 0.2)
            .foregroundStyle(Color.siloOnSurface)
            .padding(.leading, codeSize * 0.2)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .accessibilityLabel("Party code \(code.map(String.init).joined(separator: ", "))")
    }

    private func qrCard(_ url: URL) -> some View {
        QRCodeView(content: url.absoluteString, size: qrSize)
            .padding(qrSize * 0.06)
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityLabel("Scan to join this party")
    }

    private var scanHint: some View {
        Text("Or scan to open the invitation on a phone.")
            .font(.system(size: WatchPartyMetrics.caption))
            .foregroundStyle(Color.siloSecondaryText)
    }

    private var doneButton: some View {
        Button { dismiss() } label: { Text("Done") }
            .buttonStyle(WatchPartyButtonStyle(kind: .secondary))
    }

    #if os(tvOS)
    /// Text and code on the left, QR on the right; nothing scrolls, and Done
    /// is the only focusable control, so the page always has a focus owner.
    private var tvLayout: some View {
        HStack(alignment: .center, spacing: 96) {
            VStack(alignment: .leading, spacing: WatchPartyMetrics.body * 1.4) {
                VStack(alignment: .leading, spacing: 8) {
                    WatchPartyEyebrow(text: "Invite friends")
                    Text("Join with this code")
                        .font(.system(size: WatchPartyMetrics.heroTitle * 0.8, weight: .bold))
                        .foregroundStyle(Color.siloOnSurface)
                    Text("Anyone with a profile on this Silo server can enter it from Watch Party.")
                        .font(.system(size: WatchPartyMetrics.body))
                        .foregroundStyle(Color.siloSecondaryText)
                }
                if let room = session.room {
                    codeText(room.code)
                }
                if session.inviteURL != nil { scanHint }
                doneButton
            }
            .frame(maxWidth: 900, alignment: .leading)
            if let url = session.inviteURL {
                qrCard(url)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 120)
    }
    #else
    private var phoneLayout: some View {
        VStack(spacing: WatchPartyMetrics.body * 1.4) {
            heading.multilineTextAlignment(.center)
            if let room = session.room {
                codeText(room.code)
                if let url = session.inviteURL {
                    qrCard(url)
                    scanHint
                    VStack(spacing: 10) {
                        ShareLink(item: url, subject: Text("Join my Silo Watch Party"),
                                  message: Text("Watch together on Silo. Party code: \(room.code)")) {
                            Label("Share invitation", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(WatchPartyButtonStyle(kind: .primary))
                        HStack(spacing: 10) {
                            Button {
                                UIPasteboard.general.string = url.absoluteString
                                copied = "link"
                            } label: {
                                Label(copied == "link" ? "Copied" : "Copy link", systemImage: copied == "link" ? "checkmark" : "link")
                            }
                            .buttonStyle(WatchPartyButtonStyle(kind: .secondary))
                            Button {
                                UIPasteboard.general.string = room.code
                                copied = "code"
                            } label: {
                                Label(copied == "code" ? "Copied" : "Copy code", systemImage: copied == "code" ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(WatchPartyButtonStyle(kind: .secondary))
                        }
                    }
                    .padding(.top, 8)
                }
            }
            doneButton.padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
    #endif

    private var codeSize: CGFloat {
        #if os(tvOS)
        72
        #else
        40
        #endif
    }
    private var qrSize: CGFloat {
        #if os(tvOS)
        560
        #else
        200
        #endif
    }
}
#endif
