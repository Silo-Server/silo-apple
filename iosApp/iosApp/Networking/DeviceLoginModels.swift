import Foundation

struct DeviceLoginStartRequest: Codable {
    let deviceName: String?
    let devicePlatform: String?
    var clientPurpose: String? = nil
    var temporary: Bool? = nil
}

/// `deviceCode` is the TV-only secret used for polling; it must never be
/// displayed. `verificationUriComplete` is the URL encoded into the QR —
/// scanning it deep-links into the web app's `/activate?token=…` page.
struct DeviceLoginStartResponse: Codable, Equatable {
    let deviceCode: String
    let userCode: String
    let matchCode: String
    let verificationUri: String
    let verificationUriComplete: String
    let expiresAt: Date
    let expiresIn: Int
    let interval: Int
    let deviceName: String
    let devicePlatform: String
    var clientPurpose: String? = nil
    var temporary: Bool? = nil
}

enum DeviceLoginStatus: String {
    case pending
    case approved
    case denied
    case expired
    case consumed
    /// The device withdrew its own request (`cancelDeviceLogin`).
    case canceled
    case unknown

    init(raw: String) {
        self = DeviceLoginStatus(rawValue: raw) ?? .unknown
    }
}

/// A pairing request as the approving client shows it: the authoritative
/// match code and the requesting device. Pairing and the SiloRemote handoff
/// both build it from the v2 lookup (`APIv2DeviceLookup.presentation`).
struct DeviceLookupResponse {
    let matchCode: String?
    let deviceName: String?
    let devicePlatform: String?
    let status: String?
    var clientPurpose: String? = nil
    var temporary: Bool? = nil
    /// The server's own spelling of the code (`4821-7730`), empty once the
    /// request can no longer be decided.
    var userCode: String? = nil
    /// Partially masked address the request came from.
    var ipAddressHint: String? = nil
    var expiresAt: Date? = nil
    /// When the device started the request, for "Requested 2 min ago".
    var requestedAt: Date? = nil
    /// The deployment identity and display name, for the approval card and
    /// app links. Absent from servers that predate them.
    var serverId: String? = nil
    var serverName: String? = nil
}

/// Eight-character TV sign-in codes as people see and type them.
///
/// The server spells a code `4821-7730` (older servers `ABCD-EFGH`), and
/// lookups ignore case, spaces and dashes. Every screen shows it grouped 4+4 with a space, and VoiceOver
/// reads it one character at a time. A code means nothing without its
/// server: two servers can issue the same digits.
enum DeviceUserCode {
    /// Letters and digits only, uppercased: what a lookup needs.
    static func normalized(_ raw: String) -> String {
        String(raw.uppercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Grouped 4+4 for display (`4821 7730`). Older servers send eight
    /// letters (`ABCD-EFGH`), which group the same way; anything else is
    /// shown as the server sent it.
    static func display(_ raw: String) -> String {
        let code = normalized(raw)
        guard code.count == 8 else { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
        return "\(code.prefix(4)) \(code.suffix(4))"
    }

    /// One element read character by character.
    static func spokenCharacters(_ raw: String) -> String {
        normalized(raw).map(String.init).joined(separator: " ")
    }

    /// What the "Sign in a TV" field keeps of typed or pasted text: ASCII
    /// letters and digits, uppercased, at most eight, grouped 4+4. Current
    /// servers issue digits and older ones letters, and the phone can't tell
    /// which kind of server the TV is on before the lookup.
    static func entryText(_ raw: String) -> String {
        let code = String(raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8))
        return code.count > 4 ? "\(code.prefix(4)) \(code.dropFirst(4))" : code
    }

    /// Whether `raw` is a complete eight-character code, digits or letters.
    static func isComplete(_ raw: String) -> Bool {
        let code = normalized(raw)
        return code.count == 8 && code.allSatisfy(\.isASCII)
    }
}
