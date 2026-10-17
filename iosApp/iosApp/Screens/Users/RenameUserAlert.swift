#if !os(tvOS)
import SwiftUI

/// Rename a user on iPhone, iPad, and Mac (spec §5.2, §5.7): an alert with
/// the current name filled in. An empty name restores the default. WP5
/// finishes it.
struct RenameUserAlert: View {
    var router: AppRouter

    @State private var name = ""

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .alert(
                "Rename User",
                isPresented: Binding(
                    get: { router.renameRequest != nil },
                    set: { if !$0 { router.renameRequest = nil } }
                ),
                presenting: router.renameRequest
            ) { request in
                TextField("Name", text: $name)
                Button("Save") {
                    let userID = request.id
                    let newName = name
                    router.renameRequest = nil
                    Task { await router.users.renameUser(userID, to: newName) }
                }
                Button(ConfirmationCopy.cancelTitle, role: .cancel) {
                    router.renameRequest = nil
                }
            } message: { _ in
                Text("Leave it empty to use the account's name. Names stay on this device and don't change the account on the server.")
            }
            .onChange(of: router.renameRequest) { _, request in
                if let request { name = request.currentName }
            }
    }
}
#endif
