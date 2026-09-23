import Foundation

enum WatchPartyAPIError: LocalizedError, Sendable {
    case invalidRequest
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "This Watch Party request is no longer valid. Reopen the room and try again."
        case .invalidResponse: return "The server returned an incomplete Watch Party response."
        }
    }
}

/// Watch Party rooms (`/api/v2/watch-together`). Every call runs for the
/// server, account, and profile that opened the room, passed in as `auth`;
/// room-scoped calls add the room's `X-Room-Token` proof. The contract's
/// `non_retryable` operations (start, selection, promote) are dispatched once
/// and never re-sent after a 401 refresh (`HTTPClient` excludes them); callers
/// re-read the room instead.
extension APIv2Client {
    private static let watchPartyBase = "/api/v2/watch-together"

    func watchPartyCapabilities(auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyCapabilities {
        try await watchPartyRead(path: Self.watchPartyBase + "/capabilities", auth: auth)
    }

    func createWatchPartyRoom(selectionMode: WatchPartySelectionMode, roomId: String = UUID().uuidString.lowercased(),
                              auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        guard UUID(uuidString: roomId) != nil, [.hostPick, .vote].contains(selectionMode) else {
            throw WatchPartyAPIError.invalidRequest
        }
        struct Body: Encodable { let roomId: String; let selectionMode: WatchPartySelectionMode }
        return try await watchPartyRoomResponse(method: "POST", path: Self.watchPartyBase + "/rooms", expectedRoomId: roomId,
            body: watchPartyEncode(Body(roomId: roomId, selectionMode: selectionMode)), status: 201, auth: auth)
    }

    func joinWatchPartyRoom(code: String? = nil, joinToken: String? = nil,
                            auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        guard !(code?.isEmpty ?? true) || !(joinToken?.isEmpty ?? true) else { throw WatchPartyAPIError.invalidRequest }
        struct Body: Encodable { let code: String?; let joinToken: String? }
        return try await watchPartyRoomResponse(method: "POST", path: Self.watchPartyBase + "/join",
            body: watchPartyEncode(Body(code: code, joinToken: joinToken)), auth: auth)
    }

    func watchPartyRoom(id: String, token: String, auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        try await watchPartyRoomResponse(method: "GET", path: watchPartyRoomPath(id), expectedRoomId: id, token: token, auth: auth)
    }

    func stageWatchPartySelection(roomId: String, token: String, selection: WatchPartySelection,
                                  auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        try validateWatchPartySelection(selection)
        return try await watchPartyRoomResponse(method: "PUT", path: watchPartyRoomPath(roomId) + "/staged-selection",
            expectedRoomId: roomId, token: token, body: watchPartyEncode(selection), auth: auth)
    }

    func setWatchPartySelection(roomId: String, token: String, selection: WatchPartySelection,
                                auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        try validateWatchPartySelection(selection)
        return try await watchPartyRoomResponse(method: "PUT", path: watchPartyRoomPath(roomId) + "/selection",
            expectedRoomId: roomId, token: token, body: watchPartyEncode(selection), auth: auth)
    }

    func startWatchPartyPlayback(roomId: String, token: String,
                                 auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        try await watchPartyRoomResponse(method: "POST", path: watchPartyRoomPath(roomId) + "/playback/start",
            expectedRoomId: roomId, token: token, auth: auth)
    }

    func stopWatchPartyPlayback(roomId: String, token: String,
                                auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        try await watchPartyRoomResponse(method: "POST", path: watchPartyRoomPath(roomId) + "/playback/stop",
            expectedRoomId: roomId, token: token, auth: auth)
    }

    func setWatchPartySelectionMode(roomId: String, token: String, mode: WatchPartySelectionMode,
                                    auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        guard [.hostPick, .vote].contains(mode) else { throw WatchPartyAPIError.invalidRequest }
        struct Body: Encodable { let selectionMode: WatchPartySelectionMode }
        return try await watchPartyRoomResponse(method: "PATCH", path: watchPartyRoomPath(roomId) + "/selection-mode",
            expectedRoomId: roomId, token: token, body: watchPartyEncode(Body(selectionMode: mode)), auth: auth)
    }

    func setWatchPartyPolicy(roomId: String, token: String, policy: WatchPartyGuestControlPolicy,
                             auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        guard [.hostOnly, .guestPlayPause].contains(policy) else { throw WatchPartyAPIError.invalidRequest }
        struct Body: Encodable { let guestControlPolicy: WatchPartyGuestControlPolicy }
        return try await watchPartyRoomResponse(method: "PATCH", path: watchPartyRoomPath(roomId) + "/policy",
            expectedRoomId: roomId, token: token, body: watchPartyEncode(Body(guestControlPolicy: policy)), auth: auth)
    }

    func closeWatchPartyRoom(roomId: String, token: String, auth: CapturedOrdinaryRequestAuth) async throws {
        _ = try await watchPartyRequest(method: "DELETE", path: watchPartyRoomPath(roomId), token: token, status: 204, auth: auth)
    }

    func watchPartySuggestions(roomId: String, token: String, cursor: String? = nil, limit: Int = 100,
                               auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartySuggestionPage {
        guard (1...200).contains(limit) else { throw WatchPartyAPIError.invalidRequest }
        var query = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        let page: WatchPartySuggestionPage = try await watchPartyRead(path: watchPartyRoomPath(roomId) + "/suggestions",
            query: query, token: token, auth: auth)
        guard page.items.allSatisfy({ $0.roomId == roomId && !$0.id.isEmpty }),
              !page.page.hasMore || !(page.page.nextCursor?.isEmpty ?? true) else { throw WatchPartyAPIError.invalidResponse }
        return page
    }

    func addWatchPartySuggestion(roomId: String, token: String, suggestion: WatchPartyNewSuggestion,
                                 auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartySuggestionReceipt {
        guard UUID(uuidString: suggestion.suggestionId) != nil, !suggestion.contentId.isEmpty,
              ["movie", "episode"].contains(suggestion.contentType), !suggestion.title.isEmpty else {
            throw WatchPartyAPIError.invalidRequest
        }
        let raw = try await watchPartyRequest(method: "POST", path: watchPartyRoomPath(roomId) + "/suggestions",
            token: token, body: watchPartyEncode(suggestion), status: 201, auth: auth)
        let receipt = try watchPartyDecode(WatchPartySuggestionReceipt.self, raw)
        guard receipt.suggestionId == suggestion.suggestionId else { throw WatchPartyAPIError.invalidResponse }
        return receipt
    }

    func deleteWatchPartySuggestion(roomId: String, token: String, suggestionId: String,
                                    auth: CapturedOrdinaryRequestAuth) async throws {
        _ = try await watchPartyRequest(method: "DELETE", path: watchPartySuggestionPath(roomId, suggestionId),
            token: token, status: 204, auth: auth)
    }

    func voteWatchPartySuggestion(roomId: String, token: String, suggestionId: String, voted: Bool,
                                  auth: CapturedOrdinaryRequestAuth) async throws {
        _ = try await watchPartyRequest(method: voted ? "POST" : "DELETE",
            path: watchPartySuggestionPath(roomId, suggestionId) + "/vote", token: token, status: 204, auth: auth)
    }

    func promoteWatchPartySuggestion(roomId: String, token: String, suggestionId: String,
                                     auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        guard !suggestionId.isEmpty else { throw WatchPartyAPIError.invalidRequest }
        struct Body: Encodable { let suggestionId: String }
        return try await watchPartyRoomResponse(method: "POST", path: watchPartyRoomPath(roomId) + "/suggestions/promote",
            expectedRoomId: roomId, token: token, body: watchPartyEncode(Body(suggestionId: suggestionId)), auth: auth)
    }

    func watchPartyMemberState(roomId: String, token: String, contentIds: [String],
                               auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyMemberState {
        guard (1...200).contains(contentIds.count), contentIds.allSatisfy({ !$0.isEmpty }) else {
            throw WatchPartyAPIError.invalidRequest
        }
        struct Body: Encodable { let contentIds: [String] }
        let raw = try await watchPartyRequest(method: "POST", path: watchPartyRoomPath(roomId) + "/member-state",
            token: token, body: watchPartyEncode(Body(contentIds: contentIds)), auth: auth)
        let state = try watchPartyDecode(WatchPartyMemberState.self, raw)
        let requested = Set(contentIds)
        guard state.items.allSatisfy({ requested.contains($0.contentId) }) else { throw WatchPartyAPIError.invalidResponse }
        return state
    }

    func watchPartyPicker(roomId: String, token: String, auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyPicker {
        try await watchPartyRead(path: watchPartyRoomPath(roomId) + "/picker", token: token, auth: auth)
    }

    func watchPartySocketTicket(roomId: String, token: String,
                                auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartySocketTicket {
        let raw = try await watchPartyRequest(method: "POST", path: watchPartyRoomPath(roomId) + "/ws-ticket",
            token: token, auth: auth)
        let ticket = try watchPartyDecode(WatchPartySocketTicket.self, raw)
        guard ticket.protocol == "silo.room.v2", !ticket.ticket.isEmpty,
              ticket.ticket.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_").contains($0) }),
              // The server clamps `expires_in` at 0 when the bearer is about to
              // expire; connecting then fails and reconnects with a new ticket.
              ticket.expiresIn >= 0, ticket.maxConnectionSeconds > 0 else { throw WatchPartyAPIError.invalidResponse }
        return ticket
    }

    func watchPartySourceFallback(roomId: String, token: String, selectionRevision: Int64, failedFileId: String,
                                  reason: WatchPartySourceFallbackReason,
                                  auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        guard selectionRevision > 0, Self.isPositiveWatchPartyID(failedFileId) else { throw WatchPartyAPIError.invalidRequest }
        struct Body: Encodable { let selectionRevision: Int64; let failedFileId: String; let reason: WatchPartySourceFallbackReason }
        return try await watchPartyRoomResponse(method: "POST", path: watchPartyRoomPath(roomId) + "/source-fallback",
            expectedRoomId: roomId, token: token,
            body: watchPartyEncode(Body(selectionRevision: selectionRevision, failedFileId: failedFileId, reason: reason)),
            auth: auth)
    }

    // MARK: Internals

    private func watchPartyRoomResponse(method: String, path: String, expectedRoomId: String? = nil,
                                        token: String? = nil, body: Data? = nil, status: Int = 200,
                                        auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        let raw = try await watchPartyRequest(method: method, path: path, token: token, body: body, status: status, auth: auth)
        let response = try watchPartyDecode(WatchPartyRoomResponse.self, raw)
        guard !response.room.roomId.isEmpty, !response.roomAccessToken.isEmpty,
              expectedRoomId == nil || response.room.roomId == expectedRoomId else { throw WatchPartyAPIError.invalidResponse }
        return response
    }

    private func watchPartyRead<T: Decodable>(path: String, query: [String: String] = [:], token: String? = nil,
                                              auth: CapturedOrdinaryRequestAuth) async throws -> T {
        try watchPartyDecode(T.self, await watchPartyRequest(method: "GET", path: path, query: query, token: token, auth: auth))
    }

    private func watchPartyRequest(method: String, path: String, query: [String: String] = [:], token: String? = nil,
                                   body: Data? = nil, status: Int = 200,
                                   auth: CapturedOrdinaryRequestAuth) async throws -> HTTPRawResponse {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        var headers: [String: String] = [:]
        if let token {
            guard !token.isEmpty, !token.contains("\r"), !token.contains("\n") else { throw WatchPartyAPIError.invalidRequest }
            headers["X-Room-Token"] = token
        }
        let requestHeaders = headers
        let identity = Self.requestIdentity(auth, profile: profile)
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: method, path: path, query: query, body: body, headers: requestHeaders,
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        try Task.checkCancellation()
        guard raw.statusCode == status else { throw APIv2Error.httpStatus(raw.statusCode) }
        return raw
    }

    private func watchPartyDecode<T: Decodable>(_ type: T.Type, _ raw: HTTPRawResponse) throws -> T {
        try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(type, from: raw.data)
    }

    private func watchPartyEncode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(value)
    }

    private func watchPartyRoomPath(_ id: String) throws -> String {
        try Self.watchPartyBase + "/rooms/" + watchPartySegment(id)
    }

    private func watchPartySuggestionPath(_ roomId: String, _ suggestionId: String) throws -> String {
        try watchPartyRoomPath(roomId) + "/suggestions/" + watchPartySegment(suggestionId)
    }

    private func watchPartySegment(_ value: String) throws -> String {
        guard let encoded = CatalogPathSegment.encode(value) else { throw WatchPartyAPIError.invalidRequest }
        return encoded
    }

    private func validateWatchPartySelection(_ selection: WatchPartySelection) throws {
        guard !selection.contentId.isEmpty,
              selection.fileId.map(Self.isPositiveWatchPartyID) ?? true,
              selection.libraryId.map(Self.isPositiveWatchPartyID) ?? true else { throw WatchPartyAPIError.invalidRequest }
    }

    private static func isPositiveWatchPartyID(_ value: String) -> Bool {
        guard let number = Int64(value), number > 0 else { return false }
        return String(number) == value
    }
}
