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

/// The two add rows on Change Account (spec §4.1): another account on a
/// saved server, or another server.
enum AddChoice {
    case account
    case server

    var title: String {
        switch self {
        case .account: "Add an account"
        case .server: "Add a server"
        }
    }

    /// The line under the title.
    var detail: String {
        switch self {
        case .account: "Sign in to another account on a saved server"
        case .server: "Connect this \(DeviceNoun.current) to another Silo server"
        }
    }
}
