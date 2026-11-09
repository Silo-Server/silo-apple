import SwiftUI

#if !os(tvOS)
/// "Forgot password?" on iPhone, iPad and Mac, pushed from `LoginView` when
/// the server emails reset links. `ForgotPasswordModel` owns the rules; this
/// view lays them out.
struct ForgotPasswordView: View {
    @State private var model: ForgotPasswordModel
    @FocusState private var focusedField: Field?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    private enum Field: Hashable { case login }

    init(login: String) {
        _model = State(initialValue: ForgotPasswordModel(login: login))
    }

    var body: some View {
        MarqueeStage(scrim: .bottomDeep, frostStart: 0.40, onBack: model.isSending ? nil : { dismiss() }) {
            MarqueeTopBar {
                MarqueeIconButton(systemImage: "chevron.left", accessibilityLabel: AppLanguage.string(.accountBackToSignIn)) { dismiss() }
                    .disabled(model.isSending)
            } trailing: { EmptyView() }
        } content: {
            switch model.phase {
            case .sent(let login):
                sent(login: login)
            case .unavailable:
                unavailable
            case .editing, .sending:
                form
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.error)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
        .sensoryFeedback(.error, trigger: model.error) { _, error in error != nil }
        .navigationBarBackButtonHidden()
        .marqueeTransparentNavigation()
    }

    // MARK: - Form

    @ViewBuilder
    private var form: some View {
        MarqueeHeadline(
            title: AppLanguage.string(.signInForgotTitle),
            lead: AppLanguage.string(.signInForgotLead)
        )
        VStack(spacing: 0) {
            MarqueeTextField(
                systemImage: "person",
                placeholder: AppLanguage.string(.signInForgotLoginPlaceholder),
                text: $model.login,
                focus: $focusedField,
                equals: .login,
                content: .username,
                isError: model.error != nil,
                isDisabled: model.isSending,
                submitLabel: .send,
                onSubmit: send
            )

            if let error = model.error {
                MarqueeErrorText(error.message)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                    .padding(.leading, 4)
                    .accessibilityIdentifier("forgotPassword.error")
            }

            Button(action: send) {
                Text(model.isSending ? LocalizedStringResource.signInForgotSending : .signInForgotSend)
            }
            .buttonStyle(.marquee(.primary, isLoading: model.isSending))
            .keyboardShortcut(.defaultAction)
            .disabled(model.isSending)
            .padding(.top, 14)
            .accessibilityIdentifier("forgotPassword.send")
        }
        .padding(.top, 24)
        .onAppear {
            if model.login.isEmpty { focusedField = .login }
        }
    }

    // MARK: - Sent

    @ViewBuilder
    private func sent(login: String) -> some View {
        MarqueeHeadline(
            title: AppLanguage.string(.signInForgotSentTitle),
            lead: AppLanguage.string(.signInForgotSentLead(login))
        )
        VStack(spacing: 0) {
            Text(.signInForgotSentNote)
                .font(.system(size: 13))
                .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            backToSignIn
                .padding(.top, 20)
        }
        .padding(.top, 24)
    }

    // MARK: - Unavailable

    @ViewBuilder
    private var unavailable: some View {
        MarqueeHeadline(
            title: AppLanguage.string(.signInForgotTitle),
            lead: AppLanguage.string(.signInForgotUnavailableLead)
        )
        backToSignIn
            .padding(.top, 24)
    }

    private var backToSignIn: some View {
        Button(.accountBackToSignIn) { dismiss() }
            .buttonStyle(.marquee(.primary))
            .accessibilityIdentifier("forgotPassword.done")
    }

    // MARK: - Actions

    private func send() {
        guard !model.isSending else { return }
        focusedField = nil
        Task { await model.send() }
    }
}
#endif
