import Foundation

/// The text of one confirmation or prompt, in the shape
/// `TVSettingsConfirmationOverlay` and an alert take. Cancel is always the
/// other choice.
struct ConfirmationCopy: Equatable, Sendable {
    static let cancelTitle = "Cancel"

    let title: String
    let message: String
    let confirmTitle: String
    let confirmIsDestructive: Bool
    /// A second destructive choice, such as Remove Account.
    var additionalDestructiveTitle: String? = nil
}

/// Copy for signing out of and removing accounts (spec §5.6). The copy
/// names the device. On Apple TV, saved accounts are shared by every Apple
/// TV user, so it also says who is affected.
enum SignOutConfirmationCopy {
    /// How the copy names the device. iOS, iPadOS, and macOS pass their own.
    struct Device: Equatable, Sendable {
        /// After "this" in sentences: "Apple TV", "iPhone", "device".
        let noun: String
        /// After "This" in titles and buttons: "Apple TV", "iPhone", "Device".
        let titleNoun: String
        /// Whether several people share the device's accounts: Apple TV
        /// users do; one person uses an iPhone, iPad, or Mac.
        let isShared: Bool

        init(noun: String, titleNoun: String? = nil, isShared: Bool = false) {
            self.noun = noun
            self.titleNoun = titleNoun ?? noun
            self.isShared = isShared
        }

        static let appleTV = Device(noun: "Apple TV", isShared: true)
    }

    static let signOutTitle = "Sign Out"
    static let removeAccountTitle = "Remove Account"
    static let removeTitle = "Remove"

    /// The account card's long-press action.
    static func removeFromDeviceTitle(device: Device) -> String {
        "Remove from This \(device.titleNoun)"
    }

    /// Sign out of one account. Its card stays, showing Sign in again;
    /// `offersRemove` adds Remove Account, which forgets it.
    static func signOut(accountName: String, serverName: String, device: Device,
                        offersRemove: Bool = false) -> ConfirmationCopy {
        ConfirmationCopy(
            title: "Sign out of \(accountName)?",
            message: device.isShared
                ? "Everyone on this \(device.noun) will need to sign in again to use \(accountName) on \(serverName)."
                : "You'll need to sign in again to use \(accountName) on \(serverName).",
            confirmTitle: signOutTitle,
            confirmIsDestructive: true,
            additionalDestructiveTitle: offersRemove ? removeAccountTitle : nil
        )
    }

    /// Remove one account from the device. Removing the last account on a
    /// server also forgets the server.
    static func removeAccount(accountName: String, serverName: String, device: Device) -> ConfirmationCopy {
        ConfirmationCopy(
            title: "Remove \(accountName) from this \(device.noun)?",
            message: "\(accountName) will be signed out of \(serverName) \(device.isShared ? "for everyone on" : "on") this \(device.noun). Profiles and watch history stay on the server.",
            confirmTitle: removeTitle,
            confirmIsDestructive: true
        )
    }
}
