#if os(iOS)
import Foundation

struct ServerInvitation: Identifiable, Equatable {
    enum Action: String, Equatable {
        case addServer = "add-server"
        case signup
    }

    let sourceURL: URL
    let action: Action
    let serverURL: URL
    let inviteCode: String?

    var id: String { "\(action.rawValue)|\(serverURL.absoluteString)" }
    var hostname: String { serverURL.host ?? serverURL.absoluteString }
    var usesPlainHTTP: Bool { serverURL.scheme?.lowercased() == "http" }
}

enum ServerInvitationParser {
    static let maximumURLBytes = 2_048
    static let maximumFragmentBytes = 1_024
    static let maximumInviteBytes = 256

    enum ParseError: Error, Equatable {
        case oversized
        case malformed
        case unsupportedVersion
        case unsupportedAction
        case invalidServer
        case credentialsNotAllowed
    }

    static func parse(_ url: URL) throws -> ServerInvitation {
        let rawURL = url.absoluteString
        guard rawURL.utf8.count <= maximumURLBytes else { throw ParseError.oversized }
        guard !containsControlCharacters(rawURL),
              let sourceComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
              sourceComponents.scheme?.lowercased() == "https",
              sourceComponents.host?.isEmpty == false,
              sourceComponents.user == nil,
              sourceComponents.password == nil,
              let fragment = sourceComponents.percentEncodedFragment,
              !fragment.isEmpty else {
            throw ParseError.malformed
        }
        guard fragment.utf8.count <= maximumFragmentBytes else { throw ParseError.oversized }

        guard let fragmentComponents = URLComponents(string: "https://invitation.invalid/?\(fragment)"),
              let items = fragmentComponents.queryItems,
              !items.isEmpty else {
            throw ParseError.malformed
        }

        let allowedKeys: Set<String> = ["v", "action", "server", "invite"]
        var values: [String: String] = [:]
        for item in items {
            guard allowedKeys.contains(item.name),
                  values[item.name] == nil,
                  let value = item.value,
                  !containsControlCharacters(value) else {
                throw ParseError.malformed
            }
            values[item.name] = value
        }

        guard values["v"] == "1" else { throw ParseError.unsupportedVersion }
        guard let actionValue = values["action"],
              let action = ServerInvitation.Action(rawValue: actionValue) else {
            throw ParseError.unsupportedAction
        }
        guard let serverValue = values["server"], !serverValue.isEmpty else {
            throw ParseError.invalidServer
        }

        let serverURL = try validatedServerURL(serverValue)
        let inviteCode: String?
        if let rawInvite = values["invite"] {
            guard !rawInvite.isEmpty,
                  rawInvite.utf8.count <= maximumInviteBytes,
                  !containsControlCharacters(rawInvite) else {
                throw ParseError.malformed
            }
            inviteCode = rawInvite
        } else {
            inviteCode = nil
        }

        return ServerInvitation(
            sourceURL: url,
            action: action,
            serverURL: serverURL,
            inviteCode: inviteCode
        )
    }

    private static func validatedServerURL(_ value: String) throws -> URL {
        guard value.utf8.count <= maximumFragmentBytes,
              !containsControlCharacters(value),
              let decodedValue = value.removingPercentEncoding,
              !containsControlCharacters(decodedValue),
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.fragment == nil else {
            throw ParseError.invalidServer
        }
        guard components.user == nil, components.password == nil else {
            throw ParseError.credentialsNotAllowed
        }

        components.scheme = scheme
        components.host = host
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.percentEncodedPath == "/" {
            components.percentEncodedPath = ""
        }
        guard let normalizedURL = components.url else { throw ParseError.invalidServer }
        return normalizedURL
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
#endif
