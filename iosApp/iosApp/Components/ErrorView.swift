import SwiftUI

/// Error screen with status-aware copy and recovery buttons.
///
/// `onGoBack` and `onSignOut` fall back to the ambient `AppRouter`, so call
/// sites normally only supply `onRetry`. `onGoBack` auto-hides at the root
/// of the navigation stack. Pass an explicit closure to override either.
struct ErrorView: View {
    let state: ErrorState
    var onRetry: (() -> Void)? = nil
    var onGoBack: (() -> Void)? = nil
    var onSignOut: (() -> Void)? = nil
    var onManageServers: (() -> Void)? = nil

    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(spacing: SiloTheme.padding) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.siloError)

            Text(headline)
                .font(.siloHeadline)
                .foregroundColor(.siloOnSurface)
                .multilineTextAlignment(.center)

            Text(state.message)
                .font(.siloBody)
                .foregroundColor(.siloSecondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, SiloTheme.largePadding)

            VStack(spacing: SiloTheme.smallPadding) {
                if let primary = primaryAction {
                    Button(primary.title, action: primary.run)
                        .siloPrimaryButton()
                        .frame(width: 200)
                }
                ForEach(Array(secondaryActions.enumerated()), id: \.offset) { _, action in
                    Button(action.title, action: action.run)
                        .buttonStyle(.plain)
                        .foregroundColor(.siloSecondaryText)
                        .font(.siloBody)
                        .padding(.top, 4)
                }
            }
            .padding(.top, SiloTheme.smallPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headline: String { Self.headline(for: state) }

    nonisolated static func headline(for state: ErrorState) -> String {
        if state.updateRequirement != nil { return "Update required" }
        if state.isAuthFailure { return "Session expired" }
        if state.isForbidden { return "Not allowed" }
        if state.isNotFound { return "Not found" }
        return "Something went wrong"
    }

    // MARK: - Action selection

    enum Recovery: Equatable { case signInAgain, goBack, tryAgain }

    struct RecoveryPlan: Equatable {
        let primary: Recovery?
        let secondary: [Recovery]
    }

    /// Which recovery actions a state offers. Only a 401 offers sign-in; a
    /// 403 or 404 prefers leaving the screen, since retrying rarely helps.
    nonisolated static func recoveryPlan(for state: ErrorState, canRetry: Bool, canGoBack: Bool) -> RecoveryPlan {
        if state.isAuthFailure {
            return RecoveryPlan(primary: .signInAgain, secondary: canRetry ? [.tryAgain] : [])
        }
        if state.isNotFound || state.isForbidden, canGoBack {
            return RecoveryPlan(primary: .goBack, secondary: canRetry ? [.tryAgain] : [])
        }
        if canRetry { return RecoveryPlan(primary: .tryAgain, secondary: []) }
        if canGoBack { return RecoveryPlan(primary: .goBack, secondary: []) }
        return RecoveryPlan(primary: nil, secondary: [])
    }

    private struct Action {
        let title: String
        let run: () -> Void
    }

    private var resolvedOnGoBack: (() -> Void)? {
        if let onGoBack { return onGoBack }
        return router.path.isEmpty ? nil : { router.goBack() }
    }

    private var resolvedOnSignOut: () -> Void {
        onSignOut ?? { router.signOutAndReset() }
    }

    private var plan: RecoveryPlan {
        Self.recoveryPlan(for: state, canRetry: onRetry != nil, canGoBack: resolvedOnGoBack != nil)
    }

    private var primaryAction: Action? {
        plan.primary.flatMap(action(for:))
    }

    private var secondaryActions: [Action] {
        var actions: [Action] = []
        if let onManageServers {
            actions.append(Action(title: "Manage Servers", run: onManageServers))
        }
        actions.append(contentsOf: plan.secondary.compactMap(action(for:)))
        return actions
    }

    private func action(for recovery: Recovery) -> Action? {
        switch recovery {
        case .signInAgain:
            return Action(title: "Sign In Again", run: resolvedOnSignOut)
        case .goBack:
            return resolvedOnGoBack.map { Action(title: "Go Back", run: $0) }
        case .tryAgain:
            return onRetry.map { Action(title: "Try Again", run: $0) }
        }
    }
}
