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

/// Every call retains the server, account, and profile that opened the room.
/// HTTPClient performs the dispatch check; the owner fence rejects late replies.
struct WatchPartyAPI: Sendable {
    private let http: HTTPClient
    private let tokenStore: TokenStore
    private let isUpdateRequired: @Sendable () async -> Bool
    private static let base = "/api/v2/watch-together"

    init(http: HTTPClient = .shared, tokenStore: TokenStore = .shared,
         isUpdateRequired: @escaping @Sendable () async -> Bool = {
             await MainActor.run { ConnectionMonitor.shared.isServerUpdateRequired }
         }) {
        self.http = http
        self.tokenStore = tokenStore
        self.isUpdateRequired = isUpdateRequired
    }

    func capabilities(auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyCapabilities {
        try await read(path: Self.base + "/capabilities", auth: auth)
    }

    func create(selectionMode: WatchPartySelectionMode, roomId: String = UUID().uuidString.lowercased(),
                auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        guard UUID(uuidString: roomId) != nil, [.hostPick, .vote].contains(selectionMode) else {
            throw WatchPartyAPIError.invalidRequest
        }
        struct Body: Encodable { let roomId: String; let selectionMode: WatchPartySelectionMode }
        return try await roomResponse(method: "POST", path: Self.base + "/rooms", expectedRoomId: roomId,
            body: encode(Body(roomId: roomId, selectionMode: selectionMode)), status: 201, auth: auth)
    }

    func join(code: String? = nil, joinToken: String? = nil,
              auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        guard !(code?.isEmpty ?? true) || !(joinToken?.isEmpty ?? true) else { throw WatchPartyAPIError.invalidRequest }
        struct Body: Encodable { let code: String?; let joinToken: String? }
        return try await roomResponse(method: "POST", path: Self.base + "/join",
            body: encode(Body(code: code, joinToken: joinToken)), auth: auth)
    }

    func room(id: String, token: String, auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        try await roomResponse(method: "GET", path: roomPath(id), expectedRoomId: id, token: token, auth: auth)
    }

    func stage(roomId: String, token: String, selection: WatchPartySelection,
               auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        try validate(selection)
        return try await roomResponse(method: "PUT", path: roomPath(roomId) + "/staged-selection",
            expectedRoomId: roomId, token: token, body: encode(selection), auth: auth)
    }

    func select(roomId: String, token: String, selection: WatchPartySelection,
                auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        try validate(selection)
        return try await roomResponse(method: "PUT", path: roomPath(roomId) + "/selection",
            expectedRoomId: roomId, token: token, body: encode(selection), auth: auth)
    }

    func start(roomId: String, token: String, auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        try await roomResponse(method: "POST", path: roomPath(roomId) + "/playback/start",
            expectedRoomId: roomId, token: token, auth: auth)
    }

    func stop(roomId: String, token: String, auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        try await roomResponse(method: "POST", path: roomPath(roomId) + "/playback/stop",
            expectedRoomId: roomId, token: token, auth: auth)
    }

    func setMode(roomId: String, token: String, mode: WatchPartySelectionMode,
                 auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        guard [.hostPick, .vote].contains(mode) else { throw WatchPartyAPIError.invalidRequest }
        struct Body: Encodable { let selectionMode: WatchPartySelectionMode }
        return try await roomResponse(method: "PATCH", path: roomPath(roomId) + "/selection-mode",
            expectedRoomId: roomId, token: token, body: encode(Body(selectionMode: mode)), auth: auth)
    }

    func setPolicy(roomId: String, token: String, policy: WatchPartyGuestControlPolicy,
                   auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        guard [.hostOnly, .guestPlayPause].contains(policy) else { throw WatchPartyAPIError.invalidRequest }
        struct Body: Encodable { let guestControlPolicy: WatchPartyGuestControlPolicy }
        return try await roomResponse(method: "PATCH", path: roomPath(roomId) + "/policy",
            expectedRoomId: roomId, token: token, body: encode(Body(guestControlPolicy: policy)), auth: auth)
    }

    func close(roomId: String, token: String, auth: CapturedOrdinaryRequestAuth) async throws {
        _ = try await request(method: "DELETE", path: roomPath(roomId), token: token, status: 204, auth: auth)
    }

    func suggestions(roomId: String, token: String, cursor: String? = nil, limit: Int = 100,
                     auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartySuggestionPage {
        guard (1...200).contains(limit) else { throw WatchPartyAPIError.invalidRequest }
        var query = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        let page: WatchPartySuggestionPage = try await read(path: roomPath(roomId) + "/suggestions",
            query: query, token: token, auth: auth)
        guard page.items.allSatisfy({ $0.roomId == roomId && !$0.id.isEmpty }),
              !page.page.hasMore || !(page.page.nextCursor?.isEmpty ?? true) else { throw WatchPartyAPIError.invalidResponse }
        return page
    }

    func addSuggestion(roomId: String, token: String, suggestion: WatchPartyNewSuggestion,
                       auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartySuggestionReceipt {
        guard UUID(uuidString: suggestion.suggestionId) != nil, !suggestion.contentId.isEmpty,
              ["movie", "episode"].contains(suggestion.contentType), !suggestion.title.isEmpty else {
            throw WatchPartyAPIError.invalidRequest
        }
        let raw = try await request(method: "POST", path: roomPath(roomId) + "/suggestions",
            token: token, body: encode(suggestion), status: 201, auth: auth)
        let receipt = try decode(WatchPartySuggestionReceipt.self, raw)
        guard receipt.suggestionId == suggestion.suggestionId else { throw WatchPartyAPIError.invalidResponse }
        return receipt
    }

    func deleteSuggestion(roomId: String, token: String, suggestionId: String,
                          auth: CapturedOrdinaryRequestAuth) async throws {
        _ = try await request(method: "DELETE", path: suggestionPath(roomId, suggestionId), token: token, status: 204, auth: auth)
    }

    func vote(roomId: String, token: String, suggestionId: String, voted: Bool,
              auth: CapturedOrdinaryRequestAuth) async throws {
        _ = try await request(method: voted ? "POST" : "DELETE", path: suggestionPath(roomId, suggestionId) + "/vote",
            token: token, status: 204, auth: auth)
    }

    func promote(roomId: String, token: String, suggestionId: String,
                 auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        guard !suggestionId.isEmpty else { throw WatchPartyAPIError.invalidRequest }
        struct Body: Encodable { let suggestionId: String }
        return try await roomResponse(method: "POST", path: roomPath(roomId) + "/suggestions/promote",
            expectedRoomId: roomId, token: token, body: encode(Body(suggestionId: suggestionId)), auth: auth)
    }

    func memberState(roomId: String, token: String, contentIds: [String],
                     auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyMemberState {
        guard (1...200).contains(contentIds.count), contentIds.allSatisfy({ !$0.isEmpty }) else {
            throw WatchPartyAPIError.invalidRequest
        }
        struct Body: Encodable { let contentIds: [String] }
        let raw = try await request(method: "POST", path: roomPath(roomId) + "/member-state",
            token: token, body: encode(Body(contentIds: contentIds)), auth: auth)
        let state = try decode(WatchPartyMemberState.self, raw)
        let requested = Set(contentIds)
        guard state.items.allSatisfy({ requested.contains($0.contentId) }) else { throw WatchPartyAPIError.invalidResponse }
        return state
    }

    func picker(roomId: String, token: String, auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyPicker {
        try await read(path: roomPath(roomId) + "/picker", token: token, auth: auth)
    }

    func socketTicket(roomId: String, token: String, auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartySocketTicket {
        let raw = try await request(method: "POST", path: roomPath(roomId) + "/ws-ticket", token: token, auth: auth)
        let ticket = try decode(WatchPartySocketTicket.self, raw)
        guard ticket.protocol == "silo.room.v2", !ticket.ticket.isEmpty,
              ticket.ticket.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_").contains($0) }),
              ticket.expiresIn > 0, ticket.maxConnectionSeconds > 0 else { throw WatchPartyAPIError.invalidResponse }
        return ticket
    }

    func sourceFallback(roomId: String, token: String, selectionRevision: Int64, failedFileId: String,
                        reason: WatchPartySourceFallbackReason, auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        guard selectionRevision > 0, isPositiveID(failedFileId) else { throw WatchPartyAPIError.invalidRequest }
        struct Body: Encodable { let selectionRevision: Int64; let failedFileId: String; let reason: WatchPartySourceFallbackReason }
        return try await roomResponse(method: "POST", path: roomPath(roomId) + "/source-fallback",
            expectedRoomId: roomId, token: token,
            body: encode(Body(selectionRevision: selectionRevision, failedFileId: failedFileId, reason: reason)), auth: auth)
    }

    private func roomResponse(method: String, path: String, expectedRoomId: String? = nil,
                              token: String? = nil, body: Data? = nil, status: Int = 200,
                              auth: CapturedOrdinaryRequestAuth) async throws -> WatchPartyRoomResponse {
        let raw = try await request(method: method, path: path, token: token, body: body, status: status, auth: auth)
        let response = try decode(WatchPartyRoomResponse.self, raw)
        guard !response.room.roomId.isEmpty, !response.roomAccessToken.isEmpty,
              expectedRoomId == nil || response.room.roomId == expectedRoomId else { throw WatchPartyAPIError.invalidResponse }
        return response
    }

    private func read<T: Decodable>(path: String, query: [String: String] = [:], token: String? = nil,
                                    auth: CapturedOrdinaryRequestAuth) async throws -> T {
        try decode(T.self, await request(method: "GET", path: path, query: query, token: token, auth: auth))
    }

    private func request(method: String, path: String, query: [String: String] = [:], token: String? = nil,
                         body: Data? = nil, status: Int = 200, auth: CapturedOrdinaryRequestAuth) async throws -> HTTPRawResponse {
        if await isUpdateRequired() { throw APIv2Error.serverUpdateRequired }
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.authorityChanged
        }
        var headers: [String: String] = [:]
        if let token {
            guard !token.isEmpty, !token.contains("\r"), !token.contains("\n") else { throw WatchPartyAPIError.invalidRequest }
            headers["X-Room-Token"] = token
        }
        let requestHeaders = headers
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let raw: HTTPRawResponse
        do {
            raw = try await tokenStore.withOwnerFence(auth) {
                try await http.requestData(method: method, path: path, query: query, body: body, headers: requestHeaders,
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        } catch HTTPError.http(let code, let body) {
            if let body, let problem = try? HTTPClient.makeJSONDecoder().decode(APIv2Problem.self, from: Data(body.utf8)) {
                throw APIv2Error.problem(problem)
            }
            throw APIv2Error.httpStatus(code)
        }
        try Task.checkCancellation()
        guard raw.statusCode == status else { throw APIv2Error.httpStatus(raw.statusCode) }
        return raw
    }

    private func decode<T: Decodable>(_ type: T.Type, _ raw: HTTPRawResponse) throws -> T {
        try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(type, from: raw.data)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(value)
    }

    private func roomPath(_ id: String) throws -> String { try Self.base + "/rooms/" + segment(id) }
    private func suggestionPath(_ roomId: String, _ suggestionId: String) throws -> String {
        try roomPath(roomId) + "/suggestions/" + segment(suggestionId)
    }

    private func segment(_ value: String) throws -> String {
        guard !value.isEmpty, let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else {
            throw WatchPartyAPIError.invalidRequest
        }
        return encoded
    }

    private func validate(_ selection: WatchPartySelection) throws {
        guard !selection.contentId.isEmpty,
              selection.fileId.map(isPositiveID) ?? true,
              selection.libraryId.map(isPositiveID) ?? true else { throw WatchPartyAPIError.invalidRequest }
    }

    private func isPositiveID(_ value: String) -> Bool {
        guard let number = Int64(value), number > 0 else { return false }
        return String(number) == value
    }
}
