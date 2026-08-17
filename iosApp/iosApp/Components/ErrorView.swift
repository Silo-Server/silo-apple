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
                if let secondary = secondaryAction {
                    Button(secondary.title, action: secondary.run)
                        .buttonStyle(.plain)
                        .foregroundColor(.siloSecondaryText)
                        .font(.siloBody)
                        .padding(.top, 4)
                }
            }
            .padding(.top, SiloTheme.smallPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .siloBackground()
    }

    private var headline: String {
        if state.isAuthFailure { return "Session expired" }
        if state.isNotFound { return "Not found" }
        return "Something went wrong"
    }

    // MARK: - Action selection

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

    private var primaryAction: Action? {
        if state.isAuthFailure {
            return Action(title: "Sign In Again", run: resolvedOnSignOut)
        }
        if state.isNotFound, let goBack = resolvedOnGoBack {
            return Action(title: "Go Back", run: goBack)
        }
        if let onRetry {
            return Action(title: "Try Again", run: onRetry)
        }
        if let goBack = resolvedOnGoBack {
            return Action(title: "Go Back", run: goBack)
        }
        return nil
    }

    private var secondaryAction: Action? {
        if state.isAuthFailure {
            return onRetry.map { Action(title: "Try Again", run: $0) }
        }
        if state.isNotFound, resolvedOnGoBack != nil {
            if let onRetry { return Action(title: "Try Again", run: onRetry) }
            return nil
        }
        return nil
    }
}
