#if !os(tvOS)
import SwiftUI

/// Rename a user on iPhone, iPad, and Mac (spec §4, §5.2, §5.7): an alert
/// with a field holding the current name. Saving an empty name restores the
/// default, which the field shows as its placeholder. Names are trimmed and
/// kept to 40 characters on this device; the server account keeps its own.
struct RenameUserAlert: View {
    var router: AppRouter

    @State private var name = ""
    /// The request on screen. Set together with `name`, so the field opens
    /// with the current name in it.
    @State private var shown: UserRenameRequest?

    private var users: SiloUserCoordinator { router.users }

    static let title = "Rename User"
    static let saveTitle = "Save"

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .alert(
                Self.title,
                isPresented: Binding(
                    get: { shown != nil },
                    set: { presented in
                        guard !presented else { return }
                        shown = nil
                        router.renameRequest = nil
                    }
                ),
                presenting: shown
            ) { request in
                TextField(defaultName(for: request.id) ?? "Name", text: $name)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
                    .autocorrectionDisabled()
                Button(Self.saveTitle) { save(request) }
                    .keyboardShortcut(.defaultAction)
                Button(ConfirmationCopy.cancelTitle, role: .cancel) {
                    shown = nil
                    router.renameRequest = nil
                }
            } message: { request in
                Text(Self.message(defaultName: defaultName(for: request.id), device: users.device))
            }
            // The 40-character limit, as the field is typed in.
            .onChange(of: name) { _, value in
                if value.count > SiloUserNaming.maxDisplayNameLength {
                    name = String(value.prefix(SiloUserNaming.maxDisplayNameLength))
                }
            }
            .onChange(of: router.renameRequest) { _, request in
                if let request {
                    name = request.currentName
                }
                shown = request
            }
    }

    static func message(defaultName: String?, device: SignOutConfirmationCopy.Device) -> String {
        let restore = defaultName.map { "Leave it empty to use \($0)." } ?? "Leave it empty to use the account's name."
        return "The name stays on this \(device.noun) and doesn't change the account on the server. " + restore
    }

    /// The name the user has when it isn't renamed: its oldest sign-in's
    /// username (spec §4).
    private func defaultName(for userID: String) -> String? {
        guard let snapshot = users.snapshot, let user = snapshot.user(withID: userID) else { return nil }
        let serverNames = Dictionary(
            users.auth.serverRegistry.entries.map { ($0.id, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        return SiloUserNaming.defaultName(for: user, in: snapshot, serverNames: serverNames)
    }

    private func save(_ request: UserRenameRequest) {
        let newName = name
        shown = nil
        router.renameRequest = nil
        // Saving the default name untouched keeps it the default, which
        // follows the oldest sign-in, rather than storing it as a rename.
        if users.directory.user(request.id)?.isRenamed == false,
           SiloUserNaming.normalizedDisplayName(newName) == request.currentName {
            return
        }
        Task {
            if await !users.renameUser(request.id, to: newName) {
                router.accountActionError = "Couldn't rename the user. Try again."
            }
        }
    }
}
#endif
