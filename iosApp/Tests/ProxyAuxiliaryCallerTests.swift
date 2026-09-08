import AetherEngine
import Foundation
import Network
import XCTest
@testable import Silo

final class ProxyAuxiliaryCallerTests: XCTestCase {
    private let sessionID = "11111111-1111-4111-8111-111111111111"
    private let origin = URL(string: "https://proxy.example")!
    private var sidecar: String { "\(origin)/stream/v3/\(sessionID)/subtitles/1.ass?file_id=42&embedded_stream_index=0" }
    private var fonts: String { "\(origin)/stream/v3/\(sessionID)/subtitles/1/fonts?file_id=42&embedded_stream_index=0" }

    private func plan(expires: String = "2030-01-01T00:00:00Z", fontURL: String? = nil, requestedFile: Int = 42, effectiveFile: Int = 42, baseURL: URL? = nil, apiRoutes: Bool = false) throws -> PlaybackV3Plan {
        let url = try PlaybackV3FixtureTestSupport.fixtureURL(named: "decision_response", bundleClass: Self.self)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var value = try XCTUnwrap(object["playback_plan"] as? [String: Any])
        var stream = try XCTUnwrap(value["stream"] as? [String: Any])
        stream["url"] = "\(origin)/stream/v3/\(sessionID)"
        value["stream"] = stream
        value["expires_at"] = expires
        value["requested_media_file_id"] = requestedFile
        value["effective_media_file_id"] = effectiveFile
        value["subtitle"] = ["mode": "render", "track_id": "file:42:subtitle:1",
            "artifact": ["url": sidecar, "mime_type": "text/x-ssa", "format": "ass", "timing_origin_seconds": 0],
            "inventory": [["track_id": "file:42:subtitle:1", "combined_index": 1,
                "source": "embedded", "codec": "ass", "language": "eng", "label": "English",
                "forced": false, "default": false, "hearing_impaired": false, "delivery": "sidecar",
                "url": sidecar, "font_bundle_url": fontURL ?? fonts]]]
        var selected = try XCTUnwrap(value["selected_tracks"] as? [String: Any])
        selected["subtitle"] = ["id": "file:42:subtitle:1", "index": 1]
        value["selected_tracks"] = selected
        object["playback_plan"] = value
        var json = String(decoding: try JSONSerialization.data(withJSONObject: object, options: .withoutEscapingSlashes), as: UTF8.self)
        if let baseURL { json = json.replacingOccurrences(of: origin.absoluteString, with: baseURL.absoluteString) }
        if apiRoutes { json = json.replacingOccurrences(of: origin.absoluteString + "/stream/v3/", with: "/api/v2/stream/") }
        let response = try PlaybackV3FixtureTestSupport.decoder.decode(PlaybackV3DecisionResponse.self, from: Data(json.utf8))
        guard case .playable(let plan, _) = response.validatedForApple() else { throw PlaybackSequencedError.invalidResponse }
        return plan
    }

    private func fixture() async throws -> (TokenStore, CapturedOrdinaryRequestAuth) {
        let name = "ProxyAuxiliaryCallerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: defaults, standard: defaults))
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://api.example")
        try await tokens.installAccountSession(accessToken: "captured-access", refreshToken: "refresh", accountID: "account")
        await tokens.setProfileId("profile")
        _ = await tokens.setProfileToken("pin-secret")
        let captured = await tokens.captureOrdinaryRequestAuth()
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return (tokens, try XCTUnwrap(captured))
    }

    private func scope(_ tokens: TokenStore, _ auth: CapturedOrdinaryRequestAuth,
                       plan: PlaybackV3Plan? = nil) throws -> ProxyAuxiliaryScope {
        let scope = try ProxyAuxiliaryScope(plan: try plan ?? self.plan(), sessionID: sessionID,
            sourceURL: origin, auth: auth, tokens: tokens, sessionConfiguration: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [AuxiliaryProtocol.self]
                return configuration
            }, isActive: { true })
        addTeardownBlock { scope.invalidate(); AuxiliaryProtocol.reset() }
        return scope
    }

    func testExactRoutesAndImmutableSourcePins() {
        for raw in [sidecar, fonts, sidecar.replacingOccurrences(of: "embedded_stream_index=0", with: "downloaded_subtitle_id=7"),
                    sidecar.replacingOccurrences(of: "embedded_stream_index=0", with: "external_subtitle_key=" + String(repeating: "a", count: 64)),
                    sidecar.replacingOccurrences(of: ".ass", with: ".sup") + "&windowed=true&position=5&duration=10"] {
            XCTAssertNotNil(StreamRequest.proxyAuxiliaryPins(rawURL: raw, sessionID: sessionID, origin: origin, fileID: 42, track: 1), raw)
        }
        for raw in [sidecar + "&st=secret", sidecar + "&token=secret", sidecar + "&file_id=42",
                    sidecar + "&downloaded_subtitle_id=7", sidecar + "#fragment", sidecar + "&position=5",
                    sidecar.replacingOccurrences(of: "file_id=42", with: "file_id=43"),
                    sidecar.replacingOccurrences(of: "proxy.example", with: "other.example"),
                    sidecar.replacingOccurrences(of: "11111111-1111", with: "22222222-2222"),
                    sidecar.replacingOccurrences(of: "/1.ass", with: "/2.ass"),
                    sidecar.replacingOccurrences(of: "/1.ass", with: "/%31.ass"),
                    sidecar.replacingOccurrences(of: ".ass", with: ".exe"), fonts + "&windowed=1",
                    sidecar.replacingOccurrences(of: "embedded_stream_index=0", with: "downloaded_subtitle_id=0")] {
            XCTAssertNil(StreamRequest.proxyAuxiliaryPins(rawURL: raw, sessionID: sessionID, origin: origin, fileID: 42, track: 1), raw)
        }
    }

    func testFontPinsMustMatchSelectedArtifact() async throws {
        let (tokens, auth) = try await fixture()
        let wrong = try plan(fontURL: fonts.replacingOccurrences(of: "embedded_stream_index=0", with: "embedded_stream_index=2"))
        XCTAssertThrowsError(try scope(tokens, auth, plan: wrong))
    }

    func testCapturedHeadersExcludePINAndPlanRemainsSecretFree() async throws {
        let (tokens, auth) = try await fixture()
        let plan = try plan()
        let scope = try scope(tokens, auth, plan: plan)
        XCTAssertEqual(scope.headers, ["Authorization": "Bearer captured-access", "X-Profile-Id": "profile"])
        XCTAssertTrue(plan.stream.headers.isEmpty)
        try await scope.requireCurrent()
    }

    func testRotationAndExpiryRefuseOriginalAuthority() async throws {
        let (tokens, auth) = try await fixture()
        let active = try scope(tokens, auth)
        _ = await tokens.saveTokens(accessToken: "rotated-access", refreshToken: "rotated-refresh")
        do { try await active.requireCurrent(); XCTFail("Rotated token must not be adopted") } catch {}
        let current = await tokens.captureOrdinaryRequestAuth()
        let expired = try scope(tokens, XCTUnwrap(current), plan: plan(expires: "2020-01-01T00:00:00Z"))
        do { try await expired.requireCurrent(); XCTFail("Expired plan") } catch {}
    }

    @MainActor
    func testExactBytesBecomeLocalInitialAndDynamicResources() async throws {
        let (tokens, auth) = try await fixture()
        let scope = try scope(tokens, auth)
        let payload = Data("[Script Info]\nTitle: Exact bytes\n".utf8)
        AuxiliaryProtocol.configure(data: payload, mime: "text/x-ssa")
        let local = try await scope.materialize(sidecar)
        XCTAssertTrue(local.isFileURL)
        XCTAssertEqual(try Data(contentsOf: local), payload)
        XCTAssertEqual(AuxiliaryProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer captured-access")
        XCTAssertEqual(AuxiliaryProtocol.requests.first?.value(forHTTPHeaderField: "X-Profile-Id"), "profile")
        XCTAssertNil(AuxiliaryProtocol.requests.first?.value(forHTTPHeaderField: "X-Profile-Token"))
        AuxiliaryProtocol.configure(data: Data("[]".utf8), mime: "application/json")
        let font = try await scope.materialize(fonts)
        let loadedFonts = try await ASSSubtitleSession.loadFonts(URLRequest(url: font))
        XCTAssertTrue(loadedFonts.isEmpty)
        let spec = try AetherLoadSpec(validating: plan(), sessionID: sessionID, matchContentEnabled: false,
            sourceURLOverride: origin, requestHeaders: scope.headers,
            resolveURL: { scope.localURL(for: $0) }, panelIsInHDRMode: false)
        XCTAssertEqual(spec.options.externalSubtitles.first?.url, local)
        XCTAssertEqual(spec.options.externalSubtitles.first?.httpHeaders, [:])
        XCTAssertEqual(spec.subtitleFontRequests.values.first?.url, font)
        XCTAssertTrue(spec.subtitleFontRequests.values.first?.allHTTPHeaderFields?.isEmpty ?? true)
        let delivered = try await scope.materializeTrack(ExternalSubtitleTrack(url: URL(string: sidecar)!),
            fontRequest: URLRequest(url: URL(string: fonts)!))
        XCTAssertEqual(delivered.track.url, local)
        XCTAssertEqual(delivered.track.httpHeaders, [:])
        XCTAssertEqual(delivered.fontRequest?.url, font)
        XCTAssertTrue(delivered.fontRequest?.allHTTPHeaderFields?.isEmpty ?? true)
        scope.invalidate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: font.path))
        XCTAssertNil(scope.localURL(for: sidecar))
    }

    func testUnissuedURLAndBadResponsesHaveNoFallback() async throws {
        let (tokens, auth) = try await fixture()
        let scope = try scope(tokens, auth)
        do { _ = try await scope.materialize(sidecar + "&token=secret"); XCTFail("Unissued URL") } catch {}
        XCTAssertTrue(AuxiliaryProtocol.requests.isEmpty)
        for (status, mime) in [(401, "text/x-ssa"), (200, "text/html"), (302, "text/x-ssa")] {
            AuxiliaryProtocol.reset()
            let scope = try self.scope(tokens, auth)
            AuxiliaryProtocol.configure(data: Data("refused".utf8), mime: mime, status: status)
            do { _ = try await scope.materialize(sidecar); XCTFail("Invalid response \(status) \(mime)") } catch {}
            XCTAssertNil(scope.localURL(for: sidecar))
            XCTAssertEqual(AuxiliaryProtocol.requests.count, 1)
            do { try await scope.requireCurrent(); XCTFail("Refused credential lifetime must be invalidated") } catch {}
        }
    }

    func testCoincidentOriginKeepsOpaqueAPIAndSignedResourcesInTheirOwnFamily() async throws {
        let (tokens, auth) = try await fixture()
        let scope = try scope(tokens, auth)
        for raw in ["\(origin)/api/v2/stream/\(sessionID)/subtitles/1.ass?st=opaque&file_id=42&embedded_stream_index=0",
                    "\(origin)/stream/subtitles/signed-token/1.ass"] {
            let track = ExternalSubtitleTrack(url: URL(string: raw)!, httpHeaders: ["X-Existing": "existing"])
            let request = URLRequest(url: URL(string: raw + "&font=1")!)
            let delivered = try await scope.materializeTrack(track, fontRequest: request)
            XCTAssertEqual(delivered.track.url, track.url)
            XCTAssertEqual(delivered.track.httpHeaders, track.httpHeaders)
            XCTAssertEqual(delivered.fontRequest, request)
        }
        XCTAssertTrue(AuxiliaryProtocol.requests.isEmpty)
    }

    func testEffectiveSourcePinsAndConcurrentDownloadsAreExact() async throws {
        let (tokens, auth) = try await fixture()
        let changedRequested = try scope(tokens, auth, plan: plan(requestedFile: 99))
        AuxiliaryProtocol.configure(data: Data("[Script Info]".utf8), mime: "text/x-ssa")
        async let first = changedRequested.materialize(sidecar)
        async let second = changedRequested.materialize(sidecar)
        let (one, two) = try await (first, second)
        XCTAssertEqual(one, two)
        XCTAssertEqual(AuxiliaryProtocol.requests.count, 1)
        XCTAssertThrowsError(try scope(tokens, auth, plan: plan(effectiveFile: 99)))
    }

    func testAPIHeaderAuxiliaryAliasesShareOneDownloadAndKeepSignedFamilyDistinct() async throws {
        let (tokens, auth) = try await fixture()
        let plan = try plan(apiRoutes: true)
        let source = URL(string: auth.account.serverURL + plan.stream.url)!
        let scope = try ProxyAuxiliaryScope(plan: plan, sessionID: sessionID, sourceURL: source,
            auth: auth, tokens: tokens, sessionConfiguration: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [AuxiliaryProtocol.self]
                return configuration
            }, isActive: { true })
        defer { scope.invalidate(); AuxiliaryProtocol.reset() }
        let raw = try XCTUnwrap(plan.subtitle.artifact?.url)
        let absolute = auth.account.serverURL + raw
        XCTAssertTrue(StreamRequest.isHeaderAuthenticatedAuxiliaryURL(raw))
        XCTAssertFalse(StreamRequest.isHeaderAuthenticatedAuxiliaryURL(raw + "&st=opaque"))
        AuxiliaryProtocol.configure(data: Data("[Script Info]".utf8), mime: "text/x-ssa")
        async let relativeFile = scope.materialize(raw)
        async let absoluteFile = scope.materialize(absolute)
        let (first, second) = try await (relativeFile, absoluteFile)
        XCTAssertEqual(first, second)
        XCTAssertEqual(AuxiliaryProtocol.requests.count, 1)
        XCTAssertEqual(AuxiliaryProtocol.requests.first?.url?.absoluteString, absolute)
    }

    @MainActor
    func testControllerReplacementFailureAndStopInvalidateOnlyOwnedScope() async throws {
        let (tokens, auth) = try await fixture()
        let first = try scope(tokens, auth)
        let second = try scope(tokens, auth)
        let third = try scope(tokens, auth)
        let controller = try AetherPlaybackController()
        defer { controller.stop() }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        var spec = try AetherLoadSpec(directURL: missing, headers: [:], startPosition: 0, audioOnly: false)
        spec.proxyAuxiliaryScope = first
        _ = controller.beginLoad(spec)
        spec.proxyAuxiliaryScope = second
        let epoch = controller.beginLoad(spec)
        do { try await first.requireCurrent(); XCTFail("Replacement must invalidate previous scope") } catch {}
        do { try await controller.finishLoad(epoch); XCTFail("Missing owned file must fail") } catch {}
        do { try await second.requireCurrent(); XCTFail("Failed load must invalidate scope") } catch {}
        spec.proxyAuxiliaryScope = third
        _ = controller.beginLoad(spec)
        controller.stop()
        do { try await third.requireCurrent(); XCTFail("Stop must invalidate scope") } catch {}
    }

    func testActualHTTPRedirectDoesNotDeliverCredentialsToDestination() async throws {
        for crossOrigin in [false, true] {
            let destination = try AuxiliaryRedirectServer()
            let server = try AuxiliaryRedirectServer()
            defer { server.stop(); destination.stop() }
            let destinationPort = try await destination.readyPort()
            let port = try await server.readyPort()
            let base = URL(string: "http://127.0.0.1:\(port)")!
            server.redirect(to: "http://127.0.0.1:\(crossOrigin ? destinationPort : port)/redirect-target")
            let (tokens, auth) = try await fixture()
            let scope = try ProxyAuxiliaryScope(plan: plan(baseURL: base), sessionID: sessionID,
                sourceURL: base, auth: auth, tokens: tokens, isActive: { true })
            defer { scope.invalidate() }
            let raw = sidecar.replacingOccurrences(of: origin.absoluteString, with: base.absoluteString)
            do { _ = try await scope.materialize(raw); XCTFail("Redirect must refuse") } catch {}
            XCTAssertEqual(server.requestCount, 1)
            XCTAssertEqual(destination.requestCount, 0)
            XCTAssertNil(scope.localURL(for: raw))
        }
    }

    func testRedirectDelegateAlwaysRefusesNewRequest() throws {
        let delegate = ProxyAuxiliaryDownloadDelegate(limit: 100)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: sidecar)!)
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: sidecar)!, statusCode: 302, httpVersion: nil, headerFields: nil))
        for target in [sidecar, "https://other.example/stolen"] {
            var called = false
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: target)!)) { request in called = true; XCTAssertNil(request) }
            XCTAssertTrue(called)
        }
    }
}

private final class AuxiliaryProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []
    private static var responseData = Data()
    private static var mime = "text/x-ssa"
    private static var status = 200
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func configure(data: Data, mime: String, status: Int = 200) {
        lock.withLock { responseData = data; self.mime = mime; self.status = status }
    }
    static func reset() { lock.withLock { recorded = []; responseData = Data(); status = 200 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (data, mime, status) = Self.lock.withLock {
            Self.recorded.append(request)
            return (Self.responseData, Self.mime, Self.status)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class AuxiliaryRedirectServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "AuxiliaryRedirectServer")
    private let lock = NSLock()
    private var target = ""
    private var count = 0
    var requestCount: Int { lock.withLock { count } }
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.receive(connection, data: Data())
        }
        listener.start(queue: queue)
    }
    func readyPort() async throws -> UInt16 {
        for _ in 0..<100 {
            if let port = listener.port, port.rawValue != 0 { return port.rawValue }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.cannotConnectToHost)
    }
    func redirect(to target: String) { lock.withLock { self.target = target } }
    func stop() { listener.cancel() }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = data; if let bytes { request.append(bytes) }
            guard String(decoding: request, as: UTF8.self).contains("\r\n\r\n") else {
                if complete || error != nil { connection.cancel() } else { self.receive(connection, data: request) }
                return
            }
            let target = self.lock.withLock { self.count += 1; return self.target }
            let response = "HTTP/1.1 302 Found\r\nLocation: \(target)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
