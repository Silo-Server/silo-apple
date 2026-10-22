import SwiftUI

#if !os(tvOS)
/// "Choose a new password" on iPhone, iPad and Mac, shown after signing in
/// with a temporary password an admin set. `PasswordChangeModel` owns the
/// rules; this view lays them out. tvOS uses `TVPasswordChangeView`.
struct PasswordChangeView: View {
    var router: AppRouter
    @State private var model = PasswordChangeModel()
    /// Counts failed attempts so the fields shake on each one.
    @State private var failures = 0
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case current, new, confirmation }

    var body: some View {
        MarqueeStage(scrim: .bottomDeep, frostStart: 0.40) {
            if case .refreshFailed(let retrying) = model.phase {
                refreshFailed(retrying: retrying)
            } else {
                form
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.error)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
        .sensoryFeedback(.error, trigger: model.error) { _, error in error != nil }
        .task {
            MarqueeScene.shared.focus = .account
            MarqueeScene.shared.personalTint = nil
            await model.load(router: router)
        }
    }

    // MARK: - Form

    @ViewBuilder
    private var form: some View {
        MarqueeHeadline(title: "Choose a new password", lead: model.lead)
        VStack(spacing: 0) {
            MarqueeFieldGroup(isError: model.error != nil) {
                MarqueeTextField(
                    systemImage: "key",
                    placeholder: "Temporary password",
                    text: $model.currentPassword,
                    focus: $focusedField,
                    equals: .current,
                    content: .password,
                    isSecure: true,
                    isDisabled: model.isBusy,
                    submitLabel: .next,
                    onSubmit: { focusedField = .new }
                )
                MarqueeTextField(
                    systemImage: "lock",
                    placeholder: "New password",
                    text: $model.newPassword,
                    focus: $focusedField,
                    equals: .new,
                    content: .newPassword,
                    isSecure: true,
                    isDisabled: model.isBusy,
                    submitLabel: .next,
                    onSubmit: { focusedField = .confirmation }
                )
                MarqueeTextField(
                    systemImage: "lock",
                    placeholder: "Confirm new password",
                    text: $model.confirmation,
                    focus: $focusedField,
                    equals: .confirmation,
                    content: .newPassword,
                    isSecure: true,
                    isDisabled: model.isBusy,
                    submitLabel: .go,
                    onSubmit: save
                )
            }
            .modifier(MarqueeShake(trigger: failures))

            Text(model.requirementsHint)
                .font(.system(size: 13))
                .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
                .padding(.leading, 4)

            if let error = model.error {
                MarqueeErrorText(error.message)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                    .padding(.leading, 4)
                    .accessibilityIdentifier("passwordChange.error")
            }

            Button(action: save) {
                Text(model.isBusy ? "Saving…" : "Save password")
            }
            .buttonStyle(.marquee(.primary, isLoading: model.isBusy))
            .keyboardShortcut(.defaultAction)
            .disabled(model.isBusy)
            .padding(.top, 14)
            .accessibilityIdentifier("passwordChange.save")

            signOutButton
                .padding(.top, 6)
        }
        .padding(.top, 24)
    }

    // MARK: - Saved, not signed in

    @ViewBuilder
    private func refreshFailed(retrying: Bool) -> some View {
        MarqueeHeadline(
            title: "Password changed",
            lead: "Your new password is saved, but signing you in didn't finish."
        )
        VStack(spacing: 0) {
            Button {
                Task { await model.retryRefresh(router: router) }
            } label: {
                Text(retrying ? "Trying again…" : "Try again")
            }
            .buttonStyle(.marquee(.primary, isLoading: retrying))
            .disabled(retrying)

            signOutButton
                .padding(.top, 6)
        }
        .padding(.top, 24)
    }

    private var signOutButton: some View {
        Button("Sign out") { router.signOutAndReset() }
            .buttonStyle(.marqueePlain)
            .disabled(model.isBusy)
            .accessibilityIdentifier("passwordChange.signOut")
    }

    // MARK: - Actions

    private func save() {
        guard !model.isBusy else { return }
        focusedField = nil
        Task {
            if await !model.save(router: router) { failures += 1 }
        }
    }
}
#endif
