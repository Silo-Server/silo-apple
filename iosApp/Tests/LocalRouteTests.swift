import CryptoKit
import Foundation
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

    func testCancelledTasksSayNothingAboutTheRoute() {
        XCTAssertTrue(LocalRoute.isRouteFailure(URLError(.timedOut), taskCancelled: false))
        XCTAssertTrue(LocalRoute.isRouteFailure(URLError(.cancelled), taskCancelled: false))
        XCTAssertFalse(LocalRoute.isRouteFailure(URLError(.cancelled), taskCancelled: true))
        XCTAssertFalse(LocalRoute.isRouteFailure(CancellationError(), taskCancelled: false))
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

    func testPinOfAPresentedCertificateMatchesTheServerForm() throws {
        let der = try XCTUnwrap(Data(base64Encoded: Self.certificateDER))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, nil), &trust), errSecSuccess)
        XCTAssertEqual(LocalRouteTrust.spkiPin(of: try XCTUnwrap(trust)), Self.certificatePin)
    }

    func testPinOfAKeyIsTheHashOfItsSubjectPublicKeyInfo() throws {
        let key = P256.Signing.PrivateKey().publicKey
        let expected = Data(SHA256.hash(data: key.derRepresentation)).base64EncodedString()
        XCTAssertEqual(LocalRouteTrust.spkiPin(ofUncompressedP256Point: key.x963Representation), expected)

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

    private func makeClient(_ stub: StubURLProtocol.Handler) async throws -> HTTPClient {
        let suiteName = "local-route-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        let tokenStore = TokenStore(
            keychain: SharedKeychain(service: "LocalRouteTests.\(UUID().uuidString)", accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokenStore.switchActiveServer(serverId: "server")
        await tokenStore.setServerUrl(savedOrigin)
        return HTTPClient(session: stub.makeSession(), tokenStore: tokenStore)
    }

    func testActiveServerRequestsTakeTheRouteAndReportTheSavedOrigin() async throws {
        let stub = StubURLProtocol.Handler()
        stub.route(StubURLProtocol.method("GET", path: "/api/v2/system/info")) { _ in .json("{}") }
        let http = try await makeClient(stub)
        LocalRoute.publish(route())

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
        let http = try await makeClient(stub)
        LocalRoute.publish(route())

        let response = try await http.requestData(method: "POST", path: "/api/v2/playback/progress", body: Data("{}".utf8))

        XCTAssertEqual(stub.requests.map { $0.url?.host }, ["192.168.1.20", "local-route-tests.example"])
        XCTAssertEqual(response.statusCode, 200)
    }

    func testAMutationThatMayHaveArrivedIsNotRepeated() async throws {
        let stub = StubURLProtocol.Handler()
        stub.route(StubURLProtocol.method("POST", path: "/api/v2/playback/progress")) { _ in throw URLError(.timedOut) }
        let http = try await makeClient(stub)
        LocalRoute.publish(route())

        do {
            _ = try await http.requestData(method: "POST", path: "/api/v2/playback/progress", body: Data("{}".utf8))
            XCTFail("expected the timeout to surface")
        } catch HTTPError.network(let underlying) {
            XCTAssertEqual((underlying as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testExplicitAddressReadsNeverTakeTheRoute() async throws {
        let stub = StubURLProtocol.Handler()
        stub.route(StubURLProtocol.method("GET", path: ServerIdentity.identityPath)) { _ in .json(#"{"server_id":"id"}"#) }
        let http = try await makeClient(stub)
        LocalRoute.publish(route())

        let _: ServerIdentityDocument = try await http.getUnauthenticated(serverURL: savedOrigin, path: ServerIdentity.identityPath)

        XCTAssertEqual(stub.requests.map { $0.url?.host }, ["local-route-tests.example"])
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
