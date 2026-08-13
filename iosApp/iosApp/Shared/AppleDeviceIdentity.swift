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
    /// Product name the server shows in admin Activity (e.g. `Silo Apple TV`).
    /// Deliberately human-facing and stable per product, not per device.
    let clientName: String
    /// `CFBundleShortVersionString` (marketing version), or `unknown`.
    let appVersion: String
    /// `CFBundleVersion` (build number), or `unknown`. Reported separately so
    /// operators can tell two builds of the same marketing version apart.
    let appBuild: String
    /// How this binary was produced: `dev`, `sideload`, or `release`.
    let channel: String

    /// The new client-identity fields default to visibly-unresolved
    /// placeholders. Only `current` is a real snapshot of this process; any
    /// other construction (tests, synthetic identities) is not expected to
    /// describe a shipped build.
    init(
        id: String,
        name: String,
        platform: String,
        clientFamily: String,
        clientName: String = "Silo",
        appVersion: String = "unknown",
        appBuild: String = "unknown",
        channel: String = "unknown"
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.clientFamily = clientFamily
        self.clientName = clientName
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.channel = channel
    }

    static let current = AppleDeviceIdentity(
        id: AppleDeviceIdentity.loadOrCreateID(),
        name: AppleDeviceIdentity.currentName(),
        platform: AppleDeviceIdentity.currentPlatform(),
        clientFamily: AppleDeviceIdentity.currentClientFamily(),
        clientName: AppleDeviceIdentity.currentClientName(),
        appVersion: AppleDeviceIdentity.bundleString("CFBundleShortVersionString"),
        appBuild: AppleDeviceIdentity.bundleString("CFBundleVersion"),
        channel: AppleDeviceIdentity.currentChannel()
    )

    private static let keychainAccount = "com.continuum.device.identity"

    private static func loadOrCreateID() -> String {
        let keychain = SharedKeychain(audience: .userIndependent)
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

    /// Mirrors `currentClientFamily()`'s idiom split so an iPad and an iPhone
    /// running the same binary are distinguishable in admin Activity.
    private static func currentClientName() -> String {
        #if os(tvOS)
        return "Silo Apple TV"
        #elseif os(macOS)
        return "Silo Mac"
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? "Silo iPad" : "Silo iPhone"
        #else
        return "Silo"
        #endif
    }

    /// A missing version/build reports as `unknown` rather than a plausible
    /// number: an unreadable Info.plist should look broken, not like 1.0.
    private static func bundleString(_ key: String) -> String {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    /// `SiloBuildChannel` is fed by the `SILO_BUILD_CHANNEL` build setting
    /// (see project.yml), which the unsigned sideload lanes override. An
    /// absent or unexpanded value means an ordinary release build.
    private static func currentChannel() -> String {
        #if DEBUG
        return "dev"
        #else
        let raw = Bundle.main.object(forInfoDictionaryKey: "SiloBuildChannel") as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "release" : trimmed
        #endif
    }
}

extension AppleDeviceIdentity {
    /// The device + client identity headers every Silo request carries.
    /// Kept here so no call site drifts from the others; empty values are
    /// omitted rather than sent as blank headers.
    func applyHeaders(to request: inout URLRequest) {
        let headers: [(String, String)] = [
            ("X-Silo-Device-Id", id),
            ("X-Silo-Device-Name", name),
            ("X-Silo-Device-Platform", platform),
            ("X-Silo-Client-Family", clientFamily),
            ("X-Silo-Client", clientName),
            ("X-Silo-Client-Version", appVersion),
            ("X-Silo-Client-Build", appBuild),
            ("X-Silo-Client-Channel", channel)
        ]
        for (field, value) in headers where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: field)
        }
    }
}
