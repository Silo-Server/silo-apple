#if os(tvOS)
import SwiftUI

/// Settings-styled rename prompt used instead of a native alert. A text field
/// inside the tvOS alert keeps focus, so Down never reaches its buttons; here
/// the field and buttons share one native focus section.
struct TVServerRenameOverlay: View {
    let entry: ServerEntry
    let dismiss: () -> Void

    @Environment(AppRouter.self) private var router
    @State private var draft: String
    @FocusState private var focusedControl: Control?

    init(entry: ServerEntry, dismiss: @escaping () -> Void) {
        self.entry = entry
        self.dismiss = dismiss
        _draft = State(initialValue: entry.nickname ?? "")
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)

            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Text(ServerRename.title)
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundColor(.siloOnSurface)

                    Text(ServerRename.message(for: entry))
                        .font(.system(size: 22))
                        .foregroundColor(.siloSecondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: rowWidth)

                TextField(ServerRename.placeholder(for: entry), text: $draft)
                    .font(.system(size: 26))
                    .submitLabel(.done)
                    .frame(width: rowWidth)
                    .focused($focusedControl, equals: .name)
                    // Done on the keyboard lands on Save, ready to confirm.
                    .onSubmit { focusedControl = .save }

                HStack(spacing: Self.buttonSpacing) {
                    actionButton("Cancel", control: .cancel, action: dismiss)
                    if entry.nickname != nil {
                        actionButton("Use Server Name", control: .useServerName) { save(nil) }
                    }
                    actionButton("Save", control: .save) { save(draft) }
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 42)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color.siloSurfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(Color.siloChromeRestingBorder, lineWidth: 1)
            )
            .focusSection()
            .defaultFocus($focusedControl, .name, priority: .userInitiated)
            .onExitCommand(perform: dismiss)
        }
        .onAppear { focusedControl = .name }
    }

    private func actionButton(_ title: String, control: Control, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .center)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .buttonStyle(TVSettingsPaneRowStyle())
        .frame(width: Self.buttonWidth)
        .focused($focusedControl, equals: control)
    }

    private func save(_ name: String?) {
        ServerRename.save(name, for: entry, router: router)
        dismiss()
    }

    private enum Control: Hashable {
        case name
        case cancel
        case useServerName
        case save
    }

    private static let buttonWidth: CGFloat = 260
    private static let buttonSpacing: CGFloat = 16

    /// The field and message span the button row.
    private var rowWidth: CGFloat {
        let buttons: CGFloat = entry.nickname == nil ? 2 : 3
        return buttons * Self.buttonWidth + (buttons - 1) * Self.buttonSpacing
    }
}
#endif
