import Foundation

/// Profile events invalidate Home; the section response still owns the rows
/// and their resume positions. Each subscription also covers any missed events.
@MainActor
enum HomeWatchStateRealtime {
    private static let wireProtocol = "silo.events.v2"
    private static let channel = "user_state"

    static func observe(onChange: () -> Void) async {
        let tokens = TokenStore.shared
        guard let owner = await tokens.captureOrdinaryRequestAuth(),
              let profileID = owner.profileId, !profileID.isEmpty,
              owner.credentialOwner != .temporary else { return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration, delegate: SocketDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var retrySeconds = 1
        while !Task.isCancelled {
            guard await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: owner) != nil else { return }
            do {
                let ticket = try await SiloAPI.shared.apiV2Client.homeWatchStateTicket(owner: owner, profileID: profileID)
                try Task.checkCancellation()
                guard await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: owner) != nil else { return }
                let endpoint = try ticket.endpoint(serverURL: owner.account.serverURL)
                let socket = session.webSocketTask(with: endpoint, protocols: [wireProtocol, "silo.ticket.\(ticket.ticket)"])
                socket.maximumMessageSize = 64 * 1024
                socket.resume()
                let deadline = Task {
                    try await Task.sleep(for: .seconds(ticket.maxConnectionSeconds))
                    socket.cancel(with: .goingAway, reason: nil)
                }
                defer {
                    deadline.cancel()
                    socket.cancel(with: .goingAway, reason: nil)
                }
                try await withTaskCancellationHandler {
                    var subscribed = false
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        guard case .string(let text) = message,
                              let frame = try? JSONDecoder().decode(Frame.self, from: Data(text.utf8)) else { continue }
                        guard await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: owner) != nil,
                              !Task.isCancelled else { return }
                        if frame.type == "subscribed", frame.channels?.contains(channel) == true, !subscribed {
                            subscribed = true
                            retrySeconds = 1
                            onChange()
                        } else if subscribed, frame.isWatchStateChange(profileID: profileID) {
                            onChange()
                        }
                    }
                } onCancel: {
                    socket.cancel(with: .goingAway, reason: nil)
                }
            } catch {
                // Home keeps serving its REST snapshot while the socket is unavailable.
            }
            do { try await Task.sleep(for: .seconds(retrySeconds)) } catch { return }
            retrySeconds = min(retrySeconds * 2, 30)
        }
    }

    struct Frame: Decodable {
        struct Change: Decodable {
            let profileID: String
            enum CodingKeys: String, CodingKey { case profileID = "profile_id" }
        }

        let type: String
        let channels: [String]?
        let channel: String?
        let event: String?
        let data: Change?

        func isWatchStateChange(profileID: String) -> Bool {
            type == "event" && channel == "user_state" && event == "user_state.changed"
                && data?.profileID == profileID
        }
    }

    struct Ticket: Decodable {
        let ticket: String
        let expiresIn: Int
        let maxConnectionSeconds: Int
        let `protocol`: String

        func endpoint(serverURL: String) throws -> URL {
            let tokenCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
            guard `protocol` == HomeWatchStateRealtime.wireProtocol, (1...30).contains(expiresIn),
                  (1...300).contains(maxConnectionSeconds), !ticket.isEmpty,
                  ticket.unicodeScalars.allSatisfy(tokenCharacters.contains),
                  var url = URLComponents(string: serverURL), ["http", "https"].contains(url.scheme),
                  url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                throw URLError(.badServerResponse)
            }
            url.scheme = url.scheme == "https" ? "wss" : "ws"
            url.percentEncodedPath = url.percentEncodedPath.split(separator: "/").map { "/" + $0 }.joined()
                + "/api/v2/events/ws"
            url.queryItems = [URLQueryItem(name: "channels", value: HomeWatchStateRealtime.channel)]
            guard let endpoint = url.url else { throw URLError(.badURL) }
            return endpoint
        }
    }

    private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate {
        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                        didOpenWithProtocol selected: String?) {
            if selected != "silo.events.v2" { webSocketTask.cancel(with: .protocolError, reason: nil) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

extension APIv2Client {
    fileprivate func homeWatchStateTicket(owner: CapturedOrdinaryRequestAuth,
                                          profileID: String) async throws -> HomeWatchStateRealtime.Ticket {
        try await gate()
        let identity = Self.requestIdentity(owner, profile: profileID)
        let response = try await tokenStore.withOwnerFence(owner) {
            try await mapErrors {
                try await http.requestData(method: "POST", path: "/api/v2/events/ws-ticket",
                    requestIdentity: identity, expectedAccount: owner.account, expectedAuth: owner)
            }
        }
        guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
        return try HTTPClient.makeJSONDecoder().decode(HomeWatchStateRealtime.Ticket.self, from: response.data)
    }
}
