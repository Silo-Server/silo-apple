import Foundation

/// Shuffle playback (`docs/playback-api.md`, "Shuffle" in silo-server). The
/// server picks every item and applies the profile's access and parental
/// limits, so the client only plays `current` and reports when it ends.
///
/// `createShuffle` is `non_retryable`: a resend would start a second shuffle,
/// so it is dispatched once. Advance and skip name the item they act on and
/// change nothing when that item has already moved, so a retry is harmless.
extension APIv2Client {
    func shuffleCapability(auth: CapturedOrdinaryRequestAuth) async throws -> APIv2ShuffleCapability {
        let raw = try await collectionRequest("GET", path: "/api/v2/shuffles/capabilities", status: 200, auth: auth)
        return try HTTPClient.makeJSONDecoder().decode(APIv2ShuffleCapability.self, from: raw.data)
    }

    /// `201` with the new shuffle; `404` when the scope isn't visible and
    /// `409` when nothing in it can play.
    func createShuffle(scope: ShuffleScopeRequest, imageSize: String?, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2Shuffle {
        let body = try Self.shuffleEncoder.encode(CreateShuffleBody(scope: scope))
        return try await shuffleCall("POST", path: "/api/v2/shuffles", body: body, status: 201, imageSize: imageSize, auth: auth)
    }

    /// Re-checks the shuffle; the server may replace a `next` that can no
    /// longer play. `409` means nothing in the scope can play any more.
    func shuffle(id: String, imageSize: String?, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2Shuffle {
        try await shuffleCall("GET", path: try shufflePath(id), status: 200, imageSize: imageSize, auth: auth)
    }

    /// Moves past `fromContentId`: `next` becomes `current`.
    func advanceShuffle(id: String, fromContentId: String, imageSize: String?, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2Shuffle {
        let body = try Self.shuffleEncoder.encode(AdvanceShuffleBody(fromContentId: fromContentId))
        return try await shuffleCall("POST", path: try shufflePath(id) + "/advance", body: body, status: 200,
                                     imageSize: imageSize, auth: auth)
    }

    /// Pick Another: replaces `nextContentId` with another pick.
    func skipShuffleItem(id: String, nextContentId: String, imageSize: String?, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2Shuffle {
        let body = try Self.shuffleEncoder.encode(SkipShuffleBody(nextContentId: nextContentId))
        return try await shuffleCall("POST", path: try shufflePath(id) + "/skip", body: body, status: 200,
                                     imageSize: imageSize, auth: auth)
    }

    /// Stop shuffling. A shuffle that is already gone also answers `204`.
    func deleteShuffle(id: String, auth: CapturedOrdinaryRequestAuth) async throws {
        _ = try await collectionRequest("DELETE", path: try shufflePath(id), status: 204, auth: auth)
    }

    private func shuffleCall(_ method: String, path: String, body: Data? = nil, status: Int,
                             imageSize: String?, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2Shuffle {
        let raw = try await collectionRequest(method, path: path, query: imageSize.map { ["image_size": $0] } ?? [:],
                                              body: body, status: status, auth: auth)
        return try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(APIv2Shuffle.self, from: raw.data)
    }

    private func shufflePath(_ id: String) throws -> String {
        "/api/v2/shuffles/\(try catalogPathSegment(id))"
    }

    private static var shuffleEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private struct CreateShuffleBody: Encodable {
    let scope: ShuffleScopeRequest
}

private struct AdvanceShuffleBody: Encodable {
    let fromContentId: String
}

private struct SkipShuffleBody: Encodable {
    let nextContentId: String
}
