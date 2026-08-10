import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct AppleDeviceIdentity: Sendable {
    let id: String
    let name: String
    let platform: String
    /// Canonical settings family used by `profile_client` resolution.
    /// Kept separate from `platform`: the latter is diagnostic/device
    /// metadata (`iOS`, `tvOS`, `macOS`), while this intentionally groups
    /// interchangeable form factors across operating systems.
    let clientFamily: String

    init(id: String, name: String, platform: String, clientFamily: String) {
        self.id = id
        self.name = name
        self.platform = platform
        self.clientFamily = clientFamily
    }

    static let current = AppleDeviceIdentity(
        id: AppleDeviceIdentity.loadOrCreateID(),
        name: AppleDeviceIdentity.currentName(),
        platform: AppleDeviceIdentity.currentPlatform(),
        clientFamily: AppleDeviceIdentity.currentClientFamily()
    )

    private static let keychainAccount = "com.continuum.device.identity"

    private static func loadOrCreateID() -> String {
        let keychain = SharedKeychain()
        if let existing = keychain.get(keychainAccount), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        _ = keychain.set(fresh, for: keychainAccount)
        return fresh
    }

    private static func currentName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #elseif canImport(AppKit)
        return Host.current().localizedName ?? "Mac"
        #else
        return "Apple Device"
        #endif
    }

    private static func currentPlatform() -> String {
        #if os(tvOS)
        return "tvOS"
        #elseif os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #else
        return "Apple"
        #endif
    }

    private static func currentClientFamily() -> String {
        #if os(tvOS)
        return "tv"
        #elseif os(macOS)
        return "desktop"
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "mobile"
        #else
        return "desktop"
        #endif
    }
}
