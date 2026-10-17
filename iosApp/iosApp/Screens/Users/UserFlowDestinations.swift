import SwiftUI

/// The root screen of the user-flow auth states: Choose a User, Choose a
/// Server, and "Sign in to…" (plan §2.10). Dispatches to the platform's
/// screen.
struct UserFlowRoot: View {
    var router: AppRouter

    var body: some View {
        switch router.authState {
        case .needsUser(let focus):
            UserFlowDestination(route: .chooseUser(focusUserID: focus), router: router)
        case .needsServer(let userID, let focus):
            UserFlowDestination(route: .chooseServer(userID: userID, focusServerID: focus), router: router)
        case .needsSignInTarget(let context):
            UserFlowDestination(route: .signInTarget(context), router: router, isRoot: true)
        default:
            EmptyView()
        }
    }
}

/// A user-flow route on any navigation stack, on the platform's screen.
struct UserFlowDestination: View {
    let route: Route
    var router: AppRouter
    /// The screen is an auth-state root: Back has nowhere to go, so the
    /// screen offers its own way out.
    var isRoot = false

    var body: some View {
        switch route {
        case .chooseUser(let focus):
            #if os(tvOS)
            TVChooseUserScreen(router: router, focusUserID: focus)
            #else
            ChooseUserScreen(router: router, focusUserID: focus)
            #endif
        case .chooseServer(let userID, let focus):
            #if os(tvOS)
            TVChooseServerScreen(router: router, userID: userID, focusServerID: focus)
            #else
            ChooseServerScreen(router: router, userID: userID, focusServerID: focus)
            #endif
        case .signInTarget(let context):
            #if os(tvOS)
            TVSignInTargetScreen(router: router, context: context, isRoot: isRoot)
            #else
            SignInTargetScreen(router: router, context: context, isRoot: isRoot)
            #endif
        case .manageUsers:
            #if os(tvOS)
            TVUsersSettingsPane(router: router)
            #else
            ManageUsersView(router: router)
            #endif
        default:
            EmptyView()
        }
    }
}
