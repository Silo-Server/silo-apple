import Foundation

/// Local theme songs (`docs/catalog-api.md`, "Local theme songs, V2" in
/// silo-server). Both calls are profile-scoped. The playback grant is
/// `natural_idempotent`: a replay only issues another short-lived URL.
extension APIv2Client {
    func themeSongsCapability(auth: CapturedOrdinaryRequestAuth) async throws -> APIv2ThemeSongsCapability {
        let raw = try await collectionRequest("GET", path: "/api/v2/catalog/themes/capabilities", status: 200, auth: auth)
        return try HTTPClient.makeJSONDecoder().decode(APIv2ThemeSongsCapability.self, from: raw.data)
    }

    func themePlayback(ownerId: String, themeId: String, accepting formats: [APIv2ThemeAudioFormat],
                       auth: CapturedOrdinaryRequestAuth) async throws -> APIv2ThemePlayback {
        let path = "/api/v2/catalog/items/\(try catalogPathSegment(ownerId))/themes/\(try catalogPathSegment(themeId))/playback"
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try encoder.encode(ThemePlaybackBody(acceptedFormats: formats))
        let raw = try await collectionRequest("POST", path: path, body: body, status: 200, auth: auth)
        return try HTTPClient.makeJSONDecoder().decode(APIv2ThemePlayback.self, from: raw.data)
    }
}

private struct ThemePlaybackBody: Encodable {
    let acceptedFormats: [APIv2ThemeAudioFormat]
}
