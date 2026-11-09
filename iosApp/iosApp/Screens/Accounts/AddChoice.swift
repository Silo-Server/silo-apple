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

    var title: LocalizedStringResource {
        switch self {
        case .account: .changeAccountAddAccount
        case .server: .accountsAddAServer
        }
    }

    /// The line under the title. One whole sentence per device, so a
    /// translation can agree with the device's name.
    var detail: LocalizedStringResource {
        switch self {
        case .account: .pickerAddAccountDetail
        case .server:
            switch AppleDeviceIdentity.current.clientFamily {
            case "tablet": .accountsAddServerDetailIpad
            case "desktop": .accountsAddServerDetailMac
            case "tv": .accountsAddServerDetailAppleTv
            default: .accountsAddServerDetailIphone
            }
        }
    }
}
