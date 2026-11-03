import Foundation

/// What this device is called in copy: "Connect this iPhone…",
/// "…from this Mac."
enum DeviceNoun {
    static var current: String {
        switch AppleDeviceIdentity.current.clientFamily {
        case "tablet": "iPad"
        case "desktop": "Mac"
        case "tv": "Apple TV"
        default: "iPhone"
        }
    }
}

/// One choice behind Add on "Who's watching?" (spec §4.1). Every platform
/// draws the same list in `AddChoiceSheet`.
enum AddChoice: String, CaseIterable, Identifiable {
    case profile
    case account
    case server

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: "Add a profile"
        case .account: "Add an account"
        case .server: "Add a server"
        }
    }

    /// The line under the title.
    var detail: String {
        switch self {
        case .profile: "For someone else on this account"
        case .account: "Sign in to another account on a saved server"
        case .server: "Connect this \(DeviceNoun.current) to another Silo server"
        }
    }

    var systemImage: String {
        switch self {
        case .profile: "person.crop.circle.badge.plus"
        case .account: "person.2"
        case .server: "server.rack"
        }
    }

    /// The choices in order. Add a profile needs the household's primary
    /// profile, as creating one always has.
    static func available(canAddProfile: Bool) -> [AddChoice] {
        allCases.filter { $0 != .profile || canAddProfile }
    }
}

extension AppRouter {
    /// Runs an Add choice other than Add a profile, which the picker handles
    /// itself (it may ask for the primary profile's PIN first).
    func choose(_ choice: AddChoice) {
        switch choice {
        case .profile:
            break
        case .account:
            // Change Account, on the active server's Add an account, so any
            // saved server can be picked.
            showChangeAccount(focusingAddAccountOn: ServerRegistry.shared.activeServerId)
        case .server:
            resetToServerSetup()
        }
    }
}
