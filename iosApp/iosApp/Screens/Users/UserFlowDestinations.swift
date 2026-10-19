import SwiftUI

/// The root screen of the account-flow auth states: Choose an Account and
/// "Sign in to…" (plan §2.10). Dispatches to the platform's screen.
struct UserFlowRoot: View {
    var router: AppRouter

    var body: some View {
        switch router.authState {
        case .needsAccount(let focus):
            UserFlowDestination(route: .chooseAccount(focus: focus), router: router)
        case .needsSignInTarget(let context):
            UserFlowDestination(route: .signInTarget(context), router: router, isRoot: true)
        default:
            EmptyView()
        }
    }
}

/// An account-flow route on any navigation stack, on the platform's screen.
struct UserFlowDestination: View {
    let route: Route
    var router: AppRouter
    /// The screen is an auth-state root: Back has nowhere to go, so the
    /// screen offers its own way out.
    var isRoot = false

    var body: some View {
        switch route {
        case .chooseAccount(let focus):
            #if os(tvOS)
            TVChooseAccountScreen(router: router, focus: focus)
            #else
            ChooseAccountScreen(router: router, focus: focus)
            #endif
        case .signInTarget(let context):
            #if os(tvOS)
            TVSignInTargetScreen(router: router, context: context, isRoot: isRoot)
            #else
            SignInTargetScreen(router: router, context: context, isRoot: isRoot)
            #endif
        #if !os(tvOS)
        // Apple TV shows its accounts in Settings › Accounts (`TVSettingsView`).
        case .manageAccounts:
            ManageAccountsView(router: router)
        #endif
        default:
            EmptyView()
        }
    }
}
