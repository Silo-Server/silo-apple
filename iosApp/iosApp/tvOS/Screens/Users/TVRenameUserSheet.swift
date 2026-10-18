#if os(tvOS)
import SwiftUI

/// Rename a user on Apple TV (spec §4, §5.2, §5.7): the tvOS keyboard,
/// filled in with the current name. Saving an empty name restores the
/// default name. The name is stored on this Apple TV for everyone and
/// doesn't change the account on the server.
struct TVRenameUserSheet: View {
    var router: AppRouter
    let request: UserRenameRequest

    var body: some View {
        TVRenameUserContent(
            currentName: request.currentName,
            defaultName: defaultName,
            save: { name in
                let userID = request.id
                router.renameRequest = nil
                Task { await router.users.renameUser(userID, to: name) }
            },
            cancel: { router.renameRequest = nil }
        )
    }

    /// The name an empty field restores: the oldest sign-in's username.
    private var defaultName: String? {
        guard let snapshot = router.users.snapshot,
              let user = snapshot.user(withID: request.id) else { return nil }
        let serverNames = Dictionary(
            ServerRegistry.shared.entries.map { ($0.id, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        return SiloUserNaming.defaultName(for: user, in: snapshot, serverNames: serverNames)
    }
}

/// What the rename sheet draws, in the first-run text-form layout: the field
/// on the left, the type-on-your-phone card on the right.
///
/// Focus: the field first. Done on the keyboard moves focus to Save; Menu
/// cancels.
struct TVRenameUserContent: View {
    let currentName: String
    /// What an empty name restores. Nil when it can't be worked out.
    var defaultName: String?
    let save: (String) -> Void
    let cancel: () -> Void

    @State private var name: String
    @FocusState private var focused: Field?
    @State private var focusAfterKeyboard: Field?

    enum Field: Hashable {
        case name
        case save
        case cancel
    }

    init(currentName: String, defaultName: String? = nil, save: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.currentName = currentName
        self.defaultName = defaultName
        self.save = save
        self.cancel = cancel
        _name = State(initialValue: currentName)
    }

    var body: some View {
        ZStack {
            MarqueeBackdrop()
            MarqueeTVScreen {
                Text("Rename user")
                    .font(.system(size: MarqueeMetrics.heroFont, weight: .heavy))
                    .kerning(-2)
                    .foregroundStyle(Color.siloOnSurface)
                    .accessibilityAddTraits(.isHeader)
                MarqueeTVBody("The name is saved on this Apple TV for everyone. It doesn't change the account on the server.")
                    .padding(.top, 22)

                MarqueeTVField(
                    systemImage: "person",
                    placeholder: defaultName ?? "Name",
                    text: $name,
                    focus: $focused,
                    equals: .name
                )
                .frame(width: 760)
                .padding(.top, 40)
                .submitLabel(.done)
                .onSubmit { focusAfterKeyboard = .save }
                .focusSection()

                Text(emptyHint)
                    .font(.system(size: 22))
                    .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                    .frame(width: 760, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)

                HStack(spacing: 22) {
                    Button("Save") { save(name) }
                        .buttonStyle(.marquee(.primary, fullWidth: false))
                        .focused($focused, equals: .save)
                    Button(ConfirmationCopy.cancelTitle, action: cancel)
                        .buttonStyle(.marquee(.plain, fullWidth: false))
                        .focused($focused, equals: .cancel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 40)
                .focusSection()
                .defaultFocus($focused, .save, priority: .userInitiated)
            } card: {
                TVTypeOnPhoneCard()
            }
        }
        .defaultFocus($focused, .name, priority: .userInitiated)
        .marqueeTVSeedFocus($focused, .name)
        .marqueeTVFocusAfterKeyboard($focused, pending: $focusAfterKeyboard)
        .onExitCommand(perform: cancel)
    }

    private var emptyHint: String {
        if let defaultName { return "Leave it empty to use \u{201C}\(defaultName)\u{201D}." }
        return "Leave it empty to use the account's name."
    }
}
#endif
