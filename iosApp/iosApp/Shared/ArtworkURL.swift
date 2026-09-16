import Foundation

/// Resolve artwork while decoding its response, before models outlive a server
/// switch. Never consult the active server from a view or an image cache.
enum ArtworkURLResolver {
    static let serverURLKey = CodingUserInfoKey(rawValue: "artworkServerURL")!

    static func resolve(_ value: String, serverURL: URL?) -> String {
        guard value.hasPrefix("/"), !value.hasPrefix("//"),
              let serverURL,
              var origin = URLComponents(url: serverURL, resolvingAgainstBaseURL: true),
              ["http", "https"].contains(origin.scheme?.lowercased() ?? ""),
              origin.host != nil else { return value }
        origin.user = nil
        origin.password = nil
        origin.percentEncodedPath = ""
        origin.percentEncodedQuery = nil
        origin.fragment = nil
        // Concatenate the origin with the opaque signed path. URLComponents
        // queryItems would decode/re-encode signatures and encoded object keys.
        guard let base = origin.string else { return value }
        return base + value
    }
}

@propertyWrapper
struct ArtworkURL: Codable, Equatable, Hashable, Sendable {
    var wrappedValue: String?

    init(wrappedValue: String?) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String?.self)
        wrappedValue = value.map {
            ArtworkURLResolver.resolve($0, serverURL: decoder.userInfo[ArtworkURLResolver.serverURLKey] as? URL)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: ArtworkURL.Type, forKey key: Key) throws -> ArtworkURL {
        try decodeIfPresent(type, forKey: key) ?? ArtworkURL(wrappedValue: nil)
    }
}

extension KeyedEncodingContainer {
    mutating func encode(_ value: ArtworkURL, forKey key: Key) throws {
        try encodeIfPresent(value.wrappedValue, forKey: key)
    }
}

@propertyWrapper
struct RequiredArtworkURL: Codable, Equatable, Hashable, Sendable {
    var wrappedValue: String

    init(wrappedValue: String) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        wrappedValue = ArtworkURLResolver.resolve(
            value, serverURL: decoder.userInfo[ArtworkURLResolver.serverURLKey] as? URL
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}
