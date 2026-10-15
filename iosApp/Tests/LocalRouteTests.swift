#if canImport(AetherEngine)
import AetherEngine
#endif
import CryptoKit
import Foundation
import Nuke
import Security
import XCTest
@testable import Silo

/// The local route (`LocalRoute`, `LocalRouteTrust`, `LocalRouteController`):
/// which requests move to the server's LAN address, what proves that address
/// is the server, and when the route is taken away again.
final class LocalRouteTests: XCTestCase {
    /// Never a real server, so no other test's requests can match it.
    private let savedOrigin = "https://local-route-tests.example"
    private let localOrigin = "https://192.168.1.20:8080"

    override func tearDown() {
        LocalRoute.publish(nil)
        LocalRouteTrust.removeAll()
        super.tearDown()
    }

    private func route(generation: UInt64 = 1) -> LocalRoute {
        LocalRoute(serverID: "server", savedOrigin: savedOrigin, localOrigin: localOrigin, generation: generation)
    }

    // MARK: - Rewriting

    func testRoutesOnlyRequestsToTheSavedOriginAndKeepsPathAndQuery() throws {
        let route = route()
        var request = URLRequest(url: try XCTUnwrap(URL(string: savedOrigin + "/api/v2/catalog/items?page=2")))
        request.setValue("Bearer token", forHTTPHeaderField: "Authorization")

        let routed = try XCTUnwrap(route.routed(request))
        XCTAssertEqual(routed.url?.absoluteString, localOrigin + "/api/v2/catalog/items?page=2")
        XCTAssertEqual(routed.value(forHTTPHeaderField: "Authorization"), "Bearer token")

        XCTAssertNil(route.routed(URLRequest(url: try XCTUnwrap(URL(string: "https://elsewhere.example/api/v2/x")))))
        XCTAssertNil(route.routed(URLRequest(url: try XCTUnwrap(URL(string: "http://local-route-tests.example/api/v2/x")))),
                     "another scheme is another origin")
        XCTAssertNotNil(route.routed(URLRequest(url: try XCTUnwrap(URL(string: savedOrigin + ":443/api/v2/x")))),
                        "an explicit default port is the same origin")
    }

    func testResponsesReportTheSavedOrigin() throws {
        let route = route()
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(URL(string: localOrigin + "/api/v2/catalog/items?page=2")),
            statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["ETag": "\"abc\""]))

        let relabeled = try XCTUnwrap(route.relabeled(response) as? HTTPURLResponse)
        XCTAssertEqual(relabeled.url?.absoluteString, savedOrigin + "/api/v2/catalog/items?page=2")
        XCTAssertEqual(relabeled.statusCode, 200)
        XCTAssertEqual(relabeled.value(forHTTPHeaderField: "ETag"), "\"abc\"")
    }

    func testLocalOriginsArePrivateIPv4OverHTTPSOnTheSamePort() {
        XCTAssertEqual(LocalRoute.localOrigin(forAddress: "http://192.168.1.20:8080"), "https://192.168.1.20:8080")
        XCTAssertEqual(LocalRoute.localOrigin(forAddress: "https://10.0.0.5:8096/"), "https://10.0.0.5:8096")
        XCTAssertEqual(LocalRoute.localOrigin(forAddress: "http://172.16.4.2"), "https://172.16.4.2:80")
        XCTAssertEqual(LocalRoute.localOrigin(forAddress: "https://172.31.0.9"), "https://172.31.0.9")
        // A public address could carry a publicly valid certificate; a host
        // name or an overlay address is not the local network.
        XCTAssertNil(LocalRoute.localOrigin(forAddress: "http://203.0.113.7:8080"))
        XCTAssertNil(LocalRoute.localOrigin(forAddress: "http://100.64.0.4:8080"))
        XCTAssertNil(LocalRoute.localOrigin(forAddress: "http://silo.lan:8080"))
        XCTAssertNil(LocalRoute.localOrigin(forAddress: "http://172.32.0.1:8080"))
        XCTAssertNil(LocalRoute.localOrigin(forAddress: "ftp://192.168.1.20"))
    }

    // MARK: - Failures

    func testRetriesOnTheSavedAddressOnlyWhenSafe() {
        let refused = URLError(.cannotConnectToHost)
        let timedOut = URLError(.timedOut)
        XCTAssertTrue(LocalRoute.mayRetryOnSavedAddress(after: refused, method: "POST"),
                      "nothing reached a server")
        XCTAssertTrue(LocalRoute.mayRetryOnSavedAddress(after: URLError(.cancelled), method: "POST"),
                      "a refused key surfaces as a cancelled challenge before anything is sent")
        XCTAssertFalse(LocalRoute.mayRetryOnSavedAddress(after: timedOut, method: "POST"),
                       "the server may already have acted on it")
        XCTAssertTrue(LocalRoute.mayRetryOnSavedAddress(after: timedOut, method: "GET"))
        XCTAssertFalse(LocalRoute.mayRetryOnSavedAddress(after: CocoaError(.fileNoSuchFile), method: "GET"))
    }

    func testOnlyConnectionFailuresSayTheRouteStoppedWorking() {
        XCTAssertTrue(LocalRoute.isRouteFailure(URLError(.timedOut)))
        XCTAssertTrue(LocalRoute.isRouteFailure(URLError(.cannotConnectToHost)))
        XCTAssertTrue(LocalRoute.isRouteFailure(URLError(.networkConnectionLost)))
        // An identity change cancels every task; a refused key is reported by
        // the trust check itself.
        XCTAssertFalse(LocalRoute.isRouteFailure(URLError(.cancelled)))
        XCTAssertFalse(LocalRoute.isRouteFailure(CancellationError()))
        XCTAssertFalse(LocalRoute.isRouteFailure(URLError(.badServerResponse)))
    }

    func testDroppingTakesOnlyTheRouteThatFailed() {
        let current = route(generation: 2)
        LocalRoute.publish(current)
        LocalRoute.drop(route(generation: 1))
        XCTAssertEqual(LocalRoute.active, current)
        LocalRoute.drop(current)
        XCTAssertNil(LocalRoute.active)
    }

    // MARK: - Pins

    /// A self-signed P-256 certificate and the pin the server would publish
    /// for it (`openssl ... | openssl dgst -sha256 -binary | base64` over the
    /// DER SubjectPublicKeyInfo).
    private static let certificateDER = """
        MIIBnDCCAUGgAwIBAgIUSxpnkdZA5xBXafcjvWFhk6Q6n7wwCgYIKoZIzj0EAwIwIjEgMB4GA1UEAwwXU2lsbyBsb2NhbCBuZXR3b3JrIHRlc3Qw\
        IBcNMjYxMDE1MTYyNjM2WhgPMjEyNjA5MjExNjI2MzZaMCIxIDAeBgNVBAMMF1NpbG8gbG9jYWwgbmV0d29yayB0ZXN0MFkwEwYHKoZIzj0CAQYI\
        KoZIzj0DAQcDQgAECLBMnaOC4XmHFgOm3leZovbEDjiTS1aQvQvEpuK7+pijHaDLyjiMKHTukpbZEXtFlmvWIgDwKjx3KNlfjqrw6aNTMFEwHQYD\
        VR0OBBYEFC7Vqs9kCy3x862iCj89njKDZo1CMB8GA1UdIwQYMBaAFC7Vqs9kCy3x862iCj89njKDZo1CMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZI\
        zj0EAwIDSQAwRgIhAIJ3l11Gx4MVk08d0KY55qthP1N4i3qYmJgq4r2AOzl2AiEAjp3SZvZjf1LC0glmNaZdSdMnretJtK8EK5t2ZUmliVU=
        """
    private static let certificatePin = "mQuI10m45NjfkRTAse2d3Yh1LRWZ1fvUpC1L5I7+YNM="

    func testPinOfAPresentedCertificateMatchesTheServerForm() async throws {
        let der = try XCTUnwrap(Data(base64Encoded: Self.certificateDER))
        // Off the main thread, as URLSession asks: trust APIs warn there.
        let pin = await Task.detached { () -> String? in
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
            var trust: SecTrust?
            guard SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, nil), &trust) == errSecSuccess,
                  let trust else { return nil }
            return LocalRouteTrust.spkiPin(of: trust)
        }.value
        XCTAssertEqual(pin, Self.certificatePin)
    }

    func testPinOfAKeyIsTheHashOfItsSubjectPublicKeyInfo() throws {
        let key = P256.Signing.PrivateKey().publicKey
        let expected = Data(SHA256.hash(data: key.derRepresentation)).base64EncodedString()

        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 256,
        ]
        let secKey = try XCTUnwrap(SecKeyCreateWithData(key.x963Representation as CFData, attributes as CFDictionary, nil))
        XCTAssertEqual(LocalRouteTrust.spkiPin(of: secKey), expected)
    }

    func testUnpinnedHostsKeepTheSystemsHandling() {
        LocalRouteTrust.trust(localOrigin, pin: Self.certificatePin)
        let elsewhere = URLProtectionSpace(host: "192.168.1.21", port: 8080, protocol: "https", realm: nil,
                                           authenticationMethod: NSURLAuthenticationMethodServerTrust)
        XCTAssertNil(LocalRouteTrust.evaluate(elsewhere))
        let pinned = URLProtectionSpace(host: "192.168.1.20", port: 8080, protocol: "https", realm: nil,
                                        authenticationMethod: NSURLAuthenticationMethodServerTrust)
        XCTAssertEqual(LocalRouteTrust.evaluate(pinned), false,
                       "a pinned address with no certificate to check is refused, never left to the system")
    }

    // MARK: - Sending

    /// A client that sees `route` as the active local route, whatever the
    /// test host's own app is doing.
    private func makeClient(_ stub: StubURLProtocol.Handler, route: LocalRoute?) async throws -> HTTPClient {
        let suiteName = "local-route-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        let tokenStore = TokenStore(
            keychain: SharedKeychain(service: "LocalRouteTests.\(UUID().uuidString)", accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokenStore.switchActiveServer(serverId: "server")
        await tokenStore.setServerUrl(savedOrigin)
        return HTTPClient(session: stub.makeSession(), tokenStore: tokenStore, localRoute: { route })
    }

    func testActiveServerRequestsTakeTheRouteAndReportTheSavedOrigin() async throws {
        let stub = StubURLProtocol.Handler()
        stub.route(StubURLProtocol.method("GET", path: "/api/v2/system/info")) { _ in .json("{}") }
        let http = try await makeClient(stub, route: route())

        let response = try await http.requestData(method: "GET", path: "/api/v2/system/info")

        XCTAssertEqual(stub.requests.map { $0.url?.host }, ["192.168.1.20"])
        XCTAssertEqual(stub.requests.first?.url?.port, 8080)
        XCTAssertEqual(response.url?.absoluteString, savedOrigin + "/api/v2/system/info",
                       "callers see the saved address, so nothing they store names the LAN")
    }

    func testARefusedConnectionGoesAgainToTheSavedAddress() async throws {
        let stub = StubURLProtocol.Handler()
        stub.route(StubURLProtocol.method("POST", path: "/api/v2/playback/progress")) { request in
            if request.url?.host == "192.168.1.20" { throw URLError(.cannotConnectToHost) }
            return .json("{}")
        }
        let http = try await makeClient(stub, route: route())

        let response = try await http.requestData(method: "POST", path: "/api/v2/playback/progress", body: Data("{}".utf8))

        XCTAssertEqual(stub.requests.map { $0.url?.host }, ["192.168.1.20", "local-route-tests.example"])
        XCTAssertEqual(response.statusCode, 200)
    }

    func testAMutationThatMayHaveArrivedIsNotRepeated() async throws {
        let stub = StubURLProtocol.Handler()
        stub.route(StubURLProtocol.method("POST", path: "/api/v2/playback/progress")) { _ in throw URLError(.timedOut) }
        let http = try await makeClient(stub, route: route())

        do {
            _ = try await http.requestData(method: "POST", path: "/api/v2/playback/progress", body: Data("{}".utf8))
            XCTFail("expected the timeout to surface")
        } catch HTTPError.network(let underlying) {
            XCTAssertEqual((underlying as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testSignInStaysOnTheSavedAddress() async throws {
        let stub = StubURLProtocol.Handler()
        stub.route(StubURLProtocol.method("POST", path: "/api/v2/auth/device/start")) { _ in .json("{}") }
        let http = try await makeClient(stub, route: route())

        _ = try await http.requestData(method: "POST", path: "/api/v2/auth/device/start", body: Data("{}".utf8))

        XCTAssertEqual(stub.requests.map { $0.url?.host }, ["local-route-tests.example"],
                       "the server builds verification links from the origin a sign-in arrives on")
    }

    func testTheHealthCheckFollowsTheRoute() async throws {
        let stub = StubURLProtocol.Handler()
        stub.route(StubURLProtocol.method("GET", path: ServerIdentity.identityPath)) { _ in .json(#"{"server_id":"id"}"#) }
        let http = try await makeClient(stub, route: route())

        let _: ServerIdentityDocument = try await http.getUnauthenticatedFromActiveServer(ServerIdentity.identityPath)

        XCTAssertEqual(stub.requests.map { $0.url?.host }, ["192.168.1.20"],
                       "reachability describes the server every other request goes to")
    }

    func testArtworkLoadsOverTheRouteUnderTheSavedAddress() async throws {
        let stub = StubURLProtocol.Handler()
        stub.route(StubURLProtocol.any) { _ in .init(status: 200, headers: ["Content-Type": "image/png"], body: Data([1, 2, 3])) }
        let configuration = URLSessionConfiguration.ephemeral
        stub.install(into: configuration)
        let route = route()
        let loader = LocalRouteDataLoader(loader: DataLoader(configuration: configuration), localRoute: { route })

        let (error, urls) = await load(savedOrigin + "/api/v2/artwork/poster.png", with: loader)

        XCTAssertNil(error)
        XCTAssertEqual(stub.requests.map { $0.url?.host }, ["192.168.1.20"])
        XCTAssertEqual(urls, [savedOrigin + "/api/v2/artwork/poster.png"])
    }

    func testArtworkThatFailsOnTheRouteLoadsFromTheSavedAddress() async throws {
        let stub = StubURLProtocol.Handler()
        stub.route(StubURLProtocol.any) { request in
            if request.url?.host == "192.168.1.20" { throw URLError(.cannotConnectToHost) }
            return .init(status: 200, headers: ["Content-Type": "image/png"], body: Data([1, 2, 3]))
        }
        let configuration = URLSessionConfiguration.ephemeral
        stub.install(into: configuration)
        let route = route()
        let loader = LocalRouteDataLoader(loader: DataLoader(configuration: configuration), localRoute: { route })

        let (error, urls) = await load(savedOrigin + "/api/v2/artwork/poster.png", with: loader)

        XCTAssertNil(error)
        XCTAssertEqual(stub.requests.map { $0.url?.host }, ["192.168.1.20", "local-route-tests.example"])
        XCTAssertEqual(urls, [savedOrigin + "/api/v2/artwork/poster.png"])
    }

    private func load(_ address: String, with loader: LocalRouteDataLoader) async -> (Error?, [String]) {
        let responses = ResponseLog()
        let error: Error? = await withCheckedContinuation { continuation in
            _ = loader.loadData(
                with: URLRequest(url: URL(string: address)!),
                didReceiveData: { _, response in responses.append(response) },
                completion: { continuation.resume(returning: $0) }
            )
        }
        return (error, responses.urls)
    }

    // MARK: - Playback

    private func owner(serverID: String = "server", serverURL: String? = nil) -> CapturedOrdinaryRequestAuth {
        CapturedOrdinaryRequestAuth(
            account: RefreshAccountIdentity(serverId: serverID, serverURL: serverURL ?? savedOrigin, credentialGenerationID: UUID()),
            credentialOwner: .persistentServer(serverId: serverID),
            accessToken: "token", profileId: nil, profileToken: nil
        )
    }

    func testOnlyTheOwnersSavedOriginMediaMovesToTheRoute() throws {
        let media = try XCTUnwrap(URL(string: savedOrigin + "/api/v2/stream/session-one?seek=12"))
        let request = StreamRequest(url: media, headers: ["Authorization": "Bearer token"], serverUrl: savedOrigin, capturedAuth: owner())

        let routed = request.routed(over: route())
        XCTAssertEqual(routed.url.absoluteString, localOrigin + "/api/v2/stream/session-one?seek=12")
        XCTAssertEqual(routed.serverUrl, savedOrigin, "subtitles, fonts and the credentials stay on the saved address")
        XCTAssertEqual(routed.headers, request.headers)
        XCTAssertEqual(routed.localRoute, route())

        let proxy = StreamRequest(url: try XCTUnwrap(URL(string: "https://proxy.example/stream/v3/session-one")),
                                  headers: [:], serverUrl: savedOrigin, capturedAuth: owner())
        XCTAssertEqual(proxy.routed(over: route()).url, proxy.url, "a proxy node's origin is not the saved address")
        let otherServer = StreamRequest(url: media, headers: [:], serverUrl: savedOrigin, capturedAuth: owner(serverID: "other"))
        XCTAssertNil(otherServer.routed(over: route()).localRoute)
        XCTAssertNil(request.routed(over: nil).localRoute)
    }

    #if canImport(AetherEngine)
    func testRoutedMediaIsScopedToTheRouteButOwnedByTheSavedAddress() throws {
        let media = try XCTUnwrap(URL(string: localOrigin + "/api/v2/stream/session-one"))
        XCTAssertNoThrow(try PlaybackMediaAuthorization.make(
            sourceURL: media, serverURL: savedOrigin, transportServerURL: localOrigin, sessionID: "session-one",
            expectedAuth: owner(), baseHeaders: [:], http: HTTPClient(session: URLSession(configuration: .ephemeral))))
        XCTAssertThrowsError(try PlaybackMediaAuthorization.make(
            sourceURL: media, serverURL: savedOrigin, sessionID: "session-one",
            expectedAuth: owner(), baseHeaders: [:], http: HTTPClient(session: URLSession(configuration: .ephemeral))),
            "without the route, media on another origin is outside the session's scope")
        XCTAssertThrowsError(try PlaybackMediaAuthorization.make(
            sourceURL: media, serverURL: savedOrigin, transportServerURL: localOrigin, sessionID: "session-one",
            expectedAuth: owner(serverURL: "https://elsewhere.example"), baseHeaders: [:],
            http: HTTPClient(session: URLSession(configuration: .ephemeral)))) { error in
            XCTAssertEqual(error as? PlaybackMediaAuthorization.ValidationError, .credentialOwnerMismatch)
        }
    }

    @MainActor
    func testOnlyALoadThatCouldNotReachItsSourceLeavesTheRoute() {
        func load(_ kind: PlaybackErrorKind, code: Int? = nil) -> AetherPlaybackController.LoadFailure {
            AetherPlaybackController.LoadFailure(
                failure: PlaybackErrorInfo(kind: kind, message: "load failed",
                                           underlyingDomain: code.map { _ in NSURLErrorDomain }, underlyingCode: code),
                underlying: URLError(.unknown))
        }
        for error: Error in [
            load(.sourceOpenFailed, code: NSURLErrorCannotConnectToHost),
            load(.nativeItemFailed, code: NSURLErrorTimedOut),
            load(.sourceCertificateRejected),
            URLError(.cannotConnectToHost),
        ] {
            XCTAssertTrue(PlayerViewModel.isLocalRouteLoadFailure(error), "\(error)")
        }
        // What the server sent, or a cancelled load, says nothing about the route.
        for error: Error in [
            load(.sourceOpenFailed),
            load(.nativeItemFailed, code: NSURLErrorUserAuthenticationRequired),
            load(.sourceRefused, code: 403),
            load(.softwarePipelineFailed),
            load(.sourceRateLimited),
            URLError(.cancelled),
            CancellationError(),
        ] {
            XCTAssertFalse(PlayerViewModel.isLocalRouteLoadFailure(error), "\(error)")
        }
    }
    #endif

    func testExplicitAddressReadsNeverTakeTheRoute() async throws {
        let stub = StubURLProtocol.Handler()
        stub.route(StubURLProtocol.method("GET", path: ServerIdentity.identityPath)) { _ in .json(#"{"server_id":"id"}"#) }
        let http = try await makeClient(stub, route: route())

        let _: ServerIdentityDocument = try await http.getUnauthenticated(serverURL: savedOrigin, path: ServerIdentity.identityPath)

        XCTAssertEqual(stub.requests.map { $0.url?.host }, ["local-route-tests.example"])
    }

    // MARK: - Learning the pin

    func testThePinIsReadWithTheSavedAddresssBearer() async throws {
        let stub = StubURLProtocol.Handler()
        stub.route(StubURLProtocol.method("GET", path: ServerIdentity.connectionsPath)) { _ in
            .json(Self.connectionsJSON(pin: "pin"))
        }
        let configuration = URLSessionConfiguration.ephemeral
        stub.install(into: configuration)

        let document = await LocalRouteProbe.connections(origin: savedOrigin, bearer: "token", configuration: configuration)

        XCTAssertEqual(document?.localRoute?.spkiSha256, "pin")
        XCTAssertEqual(stub.requests.map { $0.header("Authorization") }, ["Bearer token"])
    }

    func testAPinBehindARedirectIsNotLearned() async throws {
        let origin = try RedirectingOrigin(document: Self.connectionsJSON(pin: "elsewhere"))
        let saved = try await origin.start()
        defer { origin.stop() }

        let document = await LocalRouteProbe.connections(origin: saved, bearer: "token")

        XCTAssertNil(document)
        XCTAssertEqual(origin.requestedPaths(), [ServerIdentity.connectionsPath])
        // An ordinary session follows the same redirect.
        let url = try XCTUnwrap(URL(string: saved + ServerIdentity.connectionsPath))
        let (_, followed) = try await URLSession(configuration: .ephemeral).data(from: url)
        XCTAssertEqual(followed.url?.path, RedirectingOrigin.elsewherePath)
    }

    private static func connectionsJSON(pin: String) -> String {
        #"{"state":"available","allowed":true,"server_id":"deployment","endpoints":[],"local_route":{"spki_sha256":"\#(pin)"}}"#
    }
}

/// When `LocalRouteController` turns the route on and off.
@MainActor
final class LocalRouteControllerTests: XCTestCase {
    private let pin = "mQuI10m45NjfkRTAse2d3Yh1LRWZ1fvUpC1L5I7+YNM="
    private var storeKey = ""

    override func setUp() {
        super.setUp()
        storeKey = "LocalRouteControllerTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: storeKey)
        LocalRoute.publish(nil)
        LocalRouteTrust.removeAll()
        super.tearDown()
    }

    private func entry(url: String = "https://local-route-tests.example", identity: String? = "deployment") -> ServerEntry {
        ServerEntry(id: "server", url: url, fetchedName: "Home", lastUsedAt: Date(), verifiedServerId: identity)
    }

    private func connections(pin: String?, url: String? = "http://192.168.1.20:8080") throws -> ServerConnectionsDocument {
        let localRoute = pin.map { pin in
            #","local_route":{"spki_sha256":"\#(pin)""# + (url.map { #","url":"\#($0)""# } ?? "") + "}"
        } ?? ""
        let json = #"{"state":"available","allowed":true,"server_id":"deployment","endpoints":[]"# + localRoute + "}"
        return try HTTPClient.makeJSONDecoder().decode(ServerConnectionsDocument.self, from: Data(json.utf8))
    }

    private func makeController(
        document: @escaping @Sendable () -> ServerConnectionsDocument?,
        confirms: @escaping @Sendable (String) -> Bool,
        addresses: [String] = []
    ) -> LocalRouteController {
        LocalRouteController(environment: .init(
            fetchConnections: { _ in document() },
            probe: { origin, _, _ in confirms(origin) },
            resolveIPv4: { _ in addresses },
            registerSensitiveHost: { _ in },
            store: LocalRouteStore(defaultsKey: storeKey),
            startsSystemMonitors: false,
            retryDelay: .seconds(3600),
            connectionsRefreshInterval: 3600
        ))
    }

    func testActivatesTheConfiguredLocalAddressOnceItProvesItself() async throws {
        let document = try connections(pin: pin)
        let controller = makeController(document: { document }, confirms: { $0 == "https://192.168.1.20:8080" })

        controller.update(activeServer: entry(), isSignedIn: true)
        await controller.settle()

        XCTAssertEqual(controller.activeLocalOrigin, "https://192.168.1.20:8080")
        let route = try XCTUnwrap(LocalRoute.active)
        XCTAssertEqual(route.savedOrigin, "https://local-route-tests.example")
        XCTAssertEqual(route.localOrigin, "https://192.168.1.20:8080")
    }

    func testNoRouteWhenNoCandidateProvesItself() async throws {
        let document = try connections(pin: pin)
        let controller = makeController(document: { document }, confirms: { _ in false })

        controller.update(activeServer: entry(), isSignedIn: true)
        await controller.settle()

        XCTAssertNil(controller.activeLocalOrigin)
        XCTAssertNil(LocalRoute.active)
    }

    func testNeedsAnHTTPSSavedAddressAndAnIdentity() async throws {
        let document = try connections(pin: pin)
        let controller = makeController(document: { document }, confirms: { _ in true })

        for server in [entry(url: "http://192.168.1.20:8080"), entry(identity: nil),
                       entry(url: "https://local-route-tests.example/silo")] {
            controller.update(activeServer: server, isSignedIn: true)
            await controller.settle()
            XCTAssertNil(controller.activeLocalOrigin, "\(server.url) \(server.verifiedServerId ?? "no identity")")
        }
        controller.update(activeServer: entry(), isSignedIn: false)
        await controller.settle()
        XCTAssertNil(controller.activeLocalOrigin, "signed out")
    }

    func testAnyNetworkChangeDropsTheRouteUntilItChecksOutAgain() async throws {
        let document = try connections(pin: pin)
        let controller = makeController(document: { document }, confirms: { _ in true })
        controller.update(activeServer: entry(), isSignedIn: true)
        await controller.settle()
        XCTAssertNotNil(LocalRoute.active)

        controller.pathChanged(allowsLocal: true)
        XCTAssertNil(LocalRoute.active, "the old address may lead somewhere else on the new network")

        await controller.settle()
        XCTAssertNotNil(LocalRoute.active)
    }

    func testAKnownKeyIsCheckedWithoutWaitingForTheSavedAddress() async throws {
        let store = LocalRouteStore(defaultsKey: storeKey)
        store.save(LocalRouteRecord(pin: pin, localURL: "http://192.168.1.20:8080"), for: "server")
        let gate = AsyncStream<Void>.makeStream()
        let document = try connections(pin: pin)
        let controller = LocalRouteController(environment: .init(
            fetchConnections: { _ in
                for await _ in gate.stream { break }
                return document
            },
            probe: { _, _, _ in true },
            resolveIPv4: { _ in [] },
            registerSensitiveHost: { _ in },
            store: store,
            startsSystemMonitors: false,
            retryDelay: .seconds(3600),
            connectionsRefreshInterval: 3600
        ))

        controller.update(activeServer: entry(), isSignedIn: true)
        let deadline = Date().addingTimeInterval(5)
        while controller.activeLocalOrigin == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.activeLocalOrigin, "https://192.168.1.20:8080",
                       "the saved address had not answered yet")

        gate.continuation.yield()
        gate.continuation.finish()
        await controller.settle()
        XCTAssertEqual(controller.activeLocalOrigin, "https://192.168.1.20:8080")
    }

    func testLosingTheLANDropsTheRouteAtOnce() async throws {
        let document = try connections(pin: pin)
        let controller = makeController(document: { document }, confirms: { _ in true })
        controller.update(activeServer: entry(), isSignedIn: true)
        await controller.settle()
        XCTAssertNotNil(LocalRoute.active)

        controller.pathChanged(allowsLocal: false)

        XCTAssertNil(LocalRoute.active)
        XCTAssertNil(controller.activeLocalOrigin)
    }

    func testOnlyTheCurrentRoutesFailureDropsIt() async throws {
        let document = try connections(pin: pin)
        let controller = makeController(document: { document }, confirms: { _ in true })
        controller.update(activeServer: entry(), isSignedIn: true)
        await controller.settle()
        let current = try XCTUnwrap(LocalRoute.active)

        let stale = LocalRoute(serverID: current.serverID, savedOrigin: current.savedOrigin,
                               localOrigin: current.localOrigin, generation: current.generation - 1)
        controller.routeFailed(stale)
        XCTAssertEqual(LocalRoute.active, current, "a request sent on an earlier route says nothing about this one")

        controller.routeFailed(current)
        XCTAssertNil(LocalRoute.active)
    }

    func testAServerWithoutTheFeatureHasNoRoute() async throws {
        let document = try connections(pin: nil)
        let controller = makeController(document: { document }, confirms: { _ in true })

        controller.update(activeServer: entry(), isSignedIn: true)
        await controller.settle()

        XCTAssertNil(controller.activeLocalOrigin)
    }

    func testAHostNameIsTriedAtItsPrivateAddresses() async throws {
        let document = try connections(pin: pin, url: "http://silo.lan:8096")
        let controller = makeController(
            document: { document }, confirms: { $0 == "https://10.0.0.7:8096" }, addresses: ["10.0.0.7"])

        controller.update(activeServer: entry(), isSignedIn: true)
        await controller.settle()

        XCTAssertEqual(controller.activeLocalOrigin, "https://10.0.0.7:8096")
    }

    func testAdvertisedAddressesAreCandidates() async throws {
        let document = try connections(pin: pin, url: nil)
        let controller = makeController(document: { document }, confirms: { $0 == "https://192.168.1.30:8080" })
        controller.update(activeServer: entry(), isSignedIn: true)
        await controller.settle()
        XCTAssertNil(controller.activeLocalOrigin)

        controller.advertised(["advert": "https://192.168.1.30:8080"])
        await controller.settle()

        XCTAssertEqual(controller.activeLocalOrigin, "https://192.168.1.30:8080")
    }

    func testANewKeyDropsTheRouteAndItsTrust() async throws {
        let first = try connections(pin: pin)
        let second = try connections(pin: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
        let current = LockedBox(first)
        let knownPin = pin
        let controller = LocalRouteController(environment: .init(
            fetchConnections: { _ in current.value },
            probe: { _, pin, _ in pin == knownPin },
            resolveIPv4: { _ in [] },
            registerSensitiveHost: { _ in },
            store: LocalRouteStore(defaultsKey: storeKey),
            startsSystemMonitors: false,
            retryDelay: .seconds(3600),
            connectionsRefreshInterval: 0
        ))
        controller.update(activeServer: entry(), isSignedIn: true)
        await controller.settle()
        XCTAssertNotNil(controller.activeLocalOrigin)

        current.value = second
        controller.refresh()
        await controller.settle()

        XCTAssertNil(controller.activeLocalOrigin, "the address no longer presents the pinned key")
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class ResponseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [URLResponse] = []

    func append(_ response: URLResponse) {
        lock.withLock { responses.append(response) }
    }

    var urls: [String] {
        lock.withLock { Array(Set(responses.compactMap { $0.url?.absoluteString })) }
    }
}
