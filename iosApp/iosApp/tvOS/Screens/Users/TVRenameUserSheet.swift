#if os(tvOS)
import SwiftUI

/// Rename a user on Apple TV (spec §5.2): the tvOS keyboard, pre-filled with
/// the current name. Saving an empty name restores the default. WP4
/// finishes the look.
struct TVRenameUserSheet: View {
    var router: AppRouter
    let request: UserRenameRequest

    @State private var name = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Rename \(request.currentName)")
                .font(.system(size: 44, weight: .heavy))
                .accessibilityAddTraits(.isHeader)
            TextField("Name", text: $name)
                .focused($isFieldFocused)
                .submitLabel(.done)
                .onSubmit(save)
            Text("Names are saved on this Apple TV for everyone and don't change the account on the server. Leave it empty to use the account's name.")
                .font(.system(size: 22))
                .opacity(0.62)
            HStack(spacing: 20) {
                Button("Save", action: save)
                    .buttonStyle(TVSettingsPaneRowStyle())
                    .frame(width: 260)
                Button(ConfirmationCopy.cancelTitle) { router.renameRequest = nil }
                    .buttonStyle(TVSettingsPaneRowStyle())
                    .frame(width: 260)
            }
            .focusSection()
        }
        .frame(maxWidth: 1080, alignment: .leading)
        .padding(80)
        .onAppear {
            name = request.currentName
            isFieldFocused = true
        }
    }

    private func save() {
        let userID = request.id
        router.renameRequest = nil
        Task { await router.users.renameUser(userID, to: name) }
    }
}
#endif
