import SwiftUI

#if !os(tvOS)
/// "Choose a new password" on iPhone, iPad and Mac, shown after signing in
/// with a temporary password an admin set. `PasswordChangeModel` owns the
/// rules; this view lays them out. Apple TV has none: its profile picker
/// shows the refusal as an error (`ProfileSelectionViewModel.handsOffToPasswordChange`).
struct PasswordChangeView: View {
    var router: AppRouter
    @State private var model = PasswordChangeModel()
    /// Counts failed attempts so the fields shake on each one.
    @State private var failures = 0
    @FocusState private var focusedField: Field?
    @Environment(\.locale) private var locale

    private enum Field: Hashable { case current, new, confirmation }

    var body: some View {
        MarqueeStage(scrim: .bottomDeep, frostStart: 0.40) {
            switch model.phase {
            case .refreshFailed(let retrying):
                refreshFailed(retrying: retrying)
            case .unconfirmed(let checking):
                unconfirmed(checking: checking)
            case .editing, .saving:
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
        MarqueeHeadline(title: AppLanguage.string(.signInPasswordChangeTitle), lead: model.lead)
        VStack(spacing: 0) {
            MarqueeFieldGroup(isError: model.error != nil) {
                MarqueeTextField(
                    systemImage: "key",
                    placeholder: AppLanguage.string(.signInPasswordChangeTemporary),
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
                    placeholder: AppLanguage.string(.signInPasswordChangeNew),
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
                    placeholder: AppLanguage.string(.signInPasswordChangeConfirm),
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
                Text(model.isBusy ? LocalizedStringResource.signInPasswordChangeSaving : .signInPasswordChangeSave)
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
            title: AppLanguage.string(.signInPasswordChangeChangedTitle),
            lead: AppLanguage.string(.signInPasswordChangeChangedLead)
        )
        VStack(spacing: 0) {
            Button {
                Task { await model.retryRefresh(router: router) }
            } label: {
                Text(retrying ? LocalizedStringResource.signInPasswordChangeTryingAgain : .commonTryAgain)
            }
            .buttonStyle(.marquee(.primary, isLoading: retrying))
            .disabled(retrying)

            signOutButton
                .padding(.top, 6)
        }
        .padding(.top, 24)
    }

    // MARK: - Outcome unknown

    @ViewBuilder
    private func unconfirmed(checking: Bool) -> some View {
        MarqueeHeadline(
            title: AppLanguage.string(.signInPasswordChangeUnconfirmedTitle),
            lead: AppLanguage.string(.signInPasswordChangeUnconfirmedLead)
        )
        VStack(spacing: 0) {
            Button {
                Task { await model.confirmChange(router: router) }
            } label: {
                Text(checking ? LocalizedStringResource.signInPasswordChangeChecking : .commonTryAgain)
            }
            .buttonStyle(.marquee(.primary, isLoading: checking))
            .disabled(checking)
            .accessibilityIdentifier("passwordChange.confirm")

            signOutButton
                .padding(.top, 6)
        }
        .padding(.top, 24)
    }

    private var signOutButton: some View {
        Button(.commonSignOut) { router.signOutAndReset() }
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
