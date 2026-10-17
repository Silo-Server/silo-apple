import Foundation

/// The text of one confirmation or prompt, in the shape
/// `TVSettingsConfirmationOverlay` and an alert take. Cancel is always the
/// other choice.
struct ConfirmationCopy: Equatable, Sendable {
    static let cancelTitle = "Cancel"

    let title: String
    let message: String
    let confirmTitle: String
    /// Sign-outs and removals are destructive; the sign-in prompts aren't.
    let confirmIsDestructive: Bool
    /// A second destructive choice, such as Sign Out & Remove Server.
    var additionalDestructiveTitle: String? = nil
}

/// Copy for signing out and removing (spec §5.6) and for the questions a
/// sign-in can raise (spec §5.4.1). Saved sign-ins are shared by everyone on
/// the device, so the copy names the device.
enum SignOutConfirmationCopy {
    /// How the copy names the device. iOS, iPadOS, and macOS pass their own.
    struct Device: Equatable, Sendable {
        /// After "this" in sentences: "Apple TV", "iPhone", "device".
        let noun: String
        /// After "This" in titles and buttons: "Apple TV", "iPhone", "Device".
        let titleNoun: String

        init(noun: String, titleNoun: String? = nil) {
            self.noun = noun
            self.titleNoun = titleNoun ?? noun
        }

        static let appleTV = Device(noun: "Apple TV")
    }

    static let signOutTitle = "Sign Out"
    static let signOutAndRemoveServerTitle = "Sign Out & Remove Server"
    static let removeTitle = "Remove"

    /// The server row's long-press action.
    static func signOutOfServerTitle(serverName: String) -> String {
        "Sign Out of \(serverName)"
    }

    /// The user card's long-press action.
    static func removeFromDeviceTitle(device: Device) -> String {
        "Remove from This \(device.titleNoun)"
    }

    /// Sign out and Sign Out of {server}: one sign-in. If it was the user's
    /// last sign-in, the user goes too.
    static func signOut(userName: String, serverName: String, device: Device) -> ConfirmationCopy {
        ConfirmationCopy(
            title: "Sign out of \(serverName)?",
            message: "Everyone on this \(device.noun) will need to sign in again to use \(userName) on \(serverName).",
            confirmTitle: signOutTitle,
            confirmIsDestructive: true,
            additionalDestructiveTitle: signOutAndRemoveServerTitle
        )
    }

    /// Remove from This Apple TV: every sign-in in the user, which removes
    /// the user. `serverNames` are the user's servers.
    static func removeUser(userName: String, serverNames: [String], device: Device) -> ConfirmationCopy {
        let effect = serverNames.isEmpty
            ? "\(userName) will be removed for everyone on this \(device.noun)."
            : "\(userName) will be signed out of \(listed(serverNames)) for everyone on this \(device.noun)."
        return ConfirmationCopy(
            title: "Remove \(userName) from this \(device.noun)?",
            message: effect + " Profiles and watch history stay on the \(serverNames.count == 1 ? "server" : "servers").",
            confirmTitle: removeTitle,
            confirmIsDestructive: true
        )
    }

    /// Sign Out & Remove Server, and removing a server in Manage Servers:
    /// the server and every user's sign-in on it. `userNames` are the users
    /// signed in to it; a user whose only sign-in this is goes too.
    static func signOutAndRemoveServer(serverName: String, userNames: [String], device: Device) -> ConfirmationCopy {
        let message = userNames.isEmpty
            ? "\(serverName) will be removed from the servers saved on this \(device.noun)."
            : "\(listed(userNames)) will be signed out of \(serverName) for everyone on this \(device.noun). Profiles and watch history stay on the server."
        return ConfirmationCopy(
            title: "Remove \(serverName) from this \(device.noun)?",
            message: message,
            confirmTitle: removeTitle,
            confirmIsDestructive: true
        )
    }

    /// Add Server signed in to a different account on a server the user
    /// already has (spec §5.4.1). `newUsername` is nil when the sign-in
    /// didn't report one.
    static func separateUser(existingUserName: String, serverName: String, newUsername: String?) -> ConfirmationCopy {
        ConfirmationCopy(
            title: "\(existingUserName) already uses \(serverName).",
            message: newUsername.map { "You signed in as \($0)." } ?? "You signed in with a different account.",
            confirmTitle: newUsername.map { "Add \($0) as a Separate User" } ?? "Add as a Separate User",
            confirmIsDestructive: false
        )
    }

    /// The account is saved in another user, where it stays (spec §5.4.1).
    static func switchToUser(otherUserName: String, serverName: String) -> ConfirmationCopy {
        ConfirmationCopy(
            title: "\(otherUserName) already uses this account.",
            message: "An account can be in only one user. Switch to \(otherUserName) to use it on \(serverName).",
            confirmTitle: "Switch to \(otherUserName)",
            confirmIsDestructive: false
        )
    }

    /// "a", "a and b", "a, b, and c".
    private static func listed(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }
}
