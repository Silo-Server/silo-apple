import XCTest
@testable import Silo
import zlib

final class HostedDiagnosticsAPITests: XCTestCase {
    override func tearDown() {
        HostedDiagnosticsStubProtocol.reset()
        SelfHostedDiagnosticsStubProtocol.reset()
        super.tearDown()
    }

    func testDefaultCollectorSessionHasNoSharedCookiesOrCredentials() throws {
        XCTAssertEqual(
            HostedDiagnosticsAPI.defaultBaseURL,
            try XCTUnwrap(URL(string: "https://diagnostics.siloserver.org"))
        )

        let session = HostedDiagnosticsAPI.makeIsolatedSession()
        defer { session.invalidateAndCancel() }
        let configuration = session.configuration

        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testCollectorBaseURLMustBeHTTPSOriginWithoutPathOrIdentity() async throws {
        for rawURL in [
            "http://collector.example",
            "https://collector.example/private-prefix",
            "https://user:password@collector.example",
            "https://collector.example?server=private",
            "https://collector.example#private",
        ] {
            let api = HostedDiagnosticsAPI(
                baseURL: try XCTUnwrap(URL(string: rawURL)),
                session: makeSession(),
                credentialStore: HostedTestCredentialStore(credential: nil)
            )
            do {
                _ = try await api.capabilities()
                XCTFail("Expected invalid origin rejection for \(rawURL)")
            } catch let error as HostedDiagnosticsAPIError {
                XCTAssertEqual(error, .invalidBaseURL, rawURL)
            }
        }
    }

    func testHostedUploadUsesOnlyAnonymousCollectorCredentialAndMapsState() async throws {
        let reportID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let bundle = Data("gzip-bundle-fixture".utf8)
        let credentialStore = HostedTestCredentialStore(
            credential: HostedDiagnosticsCredential(
                installationID: "install_apple_test",
                installationToken: "hosted-installation-token"
            )
        )
        HostedDiagnosticsStubProtocol.configure(reportID: reportID, bundle: bundle)
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: credentialStore
        )

        let response = try await api.upload(
            reportID: reportID,
            manifest: makeManifest(),
            bundleData: bundle
        )

        XCTAssertEqual(response.reportID, reportID.uuidString.lowercased())
        XCTAssertEqual(response.shortID, "SILO-APPLE1234")
        XCTAssertEqual(response.state, .processing)
        XCTAssertEqual(credentialStore.saveCount, 0, "an existing installation must be reused")

        let requests = HostedDiagnosticsStubProtocol.requests()
        XCTAssertEqual(requests.map(\.path), [
            "/v1/reports",
            "/v1/reports/\(reportID.uuidString.lowercased())/bundle",
            "/v1/reports/\(reportID.uuidString.lowercased())",
        ])
        for request in requests {
            XCTAssertEqual(request.host, "collector.example")
            XCTAssertNil(request.profileHeader)
            XCTAssertNil(request.profileTokenHeader)
            XCTAssertNil(request.siloDeviceIDHeader)
            XCTAssertNil(request.cookieHeader)
            XCTAssertEqual(request.authorization, "Bearer hosted-installation-token")
            XCTAssertNotEqual(request.authorization, "Bearer silo-account-token")
        }
        let upload = try XCTUnwrap(requests.first(where: { $0.method == "PUT" }))
        XCTAssertEqual(upload.timeoutInterval, 120)
        XCTAssertEqual(upload.contentType, "application/gzip")
        XCTAssertEqual(upload.contentLength, String(bundle.count))
        XCTAssertEqual(upload.uploadToken, "one-time-upload-token")
        XCTAssertEqual(upload.body, bundle)
        let status = try XCTUnwrap(requests.first(where: { $0.method == "GET" }))
        XCTAssertEqual(status.timeoutInterval, 10)

        let create = try XCTUnwrap(requests.first(where: { $0.path == "/v1/reports" }))
        let createJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: create.body) as? [String: Any]
        )
        XCTAssertEqual(createJSON["report_id"] as? String, reportID.uuidString.lowercased())
        XCTAssertEqual(createJSON["bundle_bytes"] as? Int, bundle.count)
        let manifest = try XCTUnwrap(createJSON["manifest"] as? [String: Any])
        let report = try XCTUnwrap(manifest["report"] as? [String: Any])
        XCTAssertNil(report["profile_id"])
        XCTAssertEqual(manifest["playback_session_ids"] as? [String], [])
        XCTAssertFalse(String(decoding: create.body, as: UTF8.self).contains("silo-account-token"))
    }

    func testHostedDeleteUsesAnonymousCredentialAndRequiresDurableNoContentReceipt() async throws {
        let reportID = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        let credential = HostedDiagnosticsCredential(
            installationID: "install-delete-test",
            installationToken: "hosted-delete-token"
        )
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: HostedTestCredentialStore(credential: credential)
        )

        HostedDiagnosticsStubProtocol.configureDelete(reportID: reportID, statusCode: 204)
        try await api.deleteReport(reportID: reportID)
        var request = try XCTUnwrap(HostedDiagnosticsStubProtocol.requests().last)
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.path, "/v1/reports/\(reportID.uuidString.lowercased())")
        XCTAssertEqual(request.authorization, "Bearer hosted-delete-token")
        XCTAssertNil(request.profileHeader)
        XCTAssertNil(request.profileTokenHeader)
        XCTAssertNil(request.siloDeviceIDHeader)

        HostedDiagnosticsStubProtocol.configureDelete(reportID: reportID, statusCode: 404)
        do {
            try await api.deleteReport(reportID: reportID)
            XCTFail("A foreign/unowned report must keep the erasure intent retryable")
        } catch let error as HostedDiagnosticsAPIError {
            XCTAssertEqual(error, .http(statusCode: 404, code: "report_not_found"))
        }
        request = try XCTUnwrap(HostedDiagnosticsStubProtocol.requests().last)
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.path, "/v1/reports/\(reportID.uuidString.lowercased())")
    }

    func testValidatedPutAcceptanceSurvivesInformationalStatusFailure() async throws {
        let reportID = try XCTUnwrap(UUID(uuidString: "99999999-8888-7777-6666-555555555555"))
        let bundle = Data("accepted-before-status-failure".utf8)
        HostedDiagnosticsStubProtocol.configureStatusFailureAfterAccepted(
            reportID: reportID,
            bundle: bundle
        )
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: HostedTestCredentialStore(
                credential: HostedDiagnosticsCredential(
                    installationID: "install-status-fallback",
                    installationToken: "status-fallback-token"
                )
            )
        )

        let response = try await api.upload(
            reportID: reportID,
            manifest: makeManifest(),
            bundleData: bundle
        )

        XCTAssertEqual(response.reportID, reportID.uuidString.lowercased())
        XCTAssertEqual(response.shortID, "SILO-APPLE1234")
        XCTAssertEqual(response.state, .processing)
        XCTAssertEqual(
            HostedDiagnosticsStubProtocol.requests().last?.path,
            "/v1/reports/\(reportID.uuidString.lowercased())"
        )
    }

    func testPutAcceptanceWrongShortIDRetainsPendingEvidence() async throws {
        let fixture = try makePendingHostedReport(label: "wrong-short-id")
        let bundle = Data("wrong-short-id-bundle".utf8)
        let reportID = fixture.report.id
        HostedDiagnosticsStubProtocol.configurePutAcceptance(
            reportID: reportID,
            bundle: bundle,
            body: #"{"report_id":"\#(reportID.uuidString.lowercased())","short_id":"SILO-WRONG9999","state":"processing"}"#
        )

        let error = await captureHostedUploadError(reportID: reportID, bundle: bundle)

        XCTAssertEqual(error, .remoteReportIdentityMismatch)
        await assertRetryRetains(error, fixture: fixture)
        XCTAssertFalse(HostedDiagnosticsStubProtocol.requests().contains { $0.method == "GET" })
    }

    func testPutAcceptanceNonDurableStatesRetainPendingEvidence() async throws {
        for state in ["receiving", "uploaded", "rejected", "deleting", "deleted"] {
            let fixture = try makePendingHostedReport(label: "non-durable-\(state)")
            let bundle = Data("non-durable-\(state)-bundle".utf8)
            let reportID = fixture.report.id
            HostedDiagnosticsStubProtocol.configurePutAcceptance(
                reportID: reportID,
                bundle: bundle,
                body: #"{"report_id":"\#(reportID.uuidString.lowercased())","short_id":"SILO-APPLE1234","state":"\#(state)"}"#
            )

            let error = await captureHostedUploadError(reportID: reportID, bundle: bundle)

            XCTAssertEqual(error, .invalidResponse, state)
            await assertRetryRetains(error, fixture: fixture, message: state)
            XCTAssertFalse(
                HostedDiagnosticsStubProtocol.requests().contains { $0.method == "GET" },
                state
            )
        }
    }

    func testMalformedPutAcceptanceRetainsPendingEvidence() async throws {
        let fixture = try makePendingHostedReport(label: "malformed-put")
        let bundle = Data("malformed-put-bundle".utf8)
        HostedDiagnosticsStubProtocol.configurePutAcceptance(
            reportID: fixture.report.id,
            bundle: bundle,
            body: #"{"report_id":broken-json"#
        )

        let error = await captureHostedUploadError(
            reportID: fixture.report.id,
            bundle: bundle
        )

        guard case .underlying = error else {
            return XCTFail("Expected malformed 202 to produce a retryable decode failure, got \(error)")
        }
        await assertRetryRetains(error, fixture: fixture)
        XCTAssertFalse(HostedDiagnosticsStubProtocol.requests().contains { $0.method == "GET" })
    }

    func testReadyPutAcceptanceIsDurable() async throws {
        let reportID = try XCTUnwrap(UUID(uuidString: "eeeeeeee-dddd-cccc-bbbb-aaaaaaaaaaaa"))
        let bundle = Data("ready-put-bundle".utf8)
        HostedDiagnosticsStubProtocol.configurePutAcceptance(
            reportID: reportID,
            bundle: bundle,
            body: #"{"report_id":"\#(reportID.uuidString.lowercased())","short_id":"SILO-APPLE1234","state":"ready"}"#
        )

        let response = try await makeHostedUploadAPI().upload(
            reportID: reportID,
            manifest: makeManifest(),
            bundleData: bundle
        )

        XCTAssertEqual(response.shortID, "SILO-APPLE1234")
        XCTAssertEqual(response.state, .processing, "the subsequent GET may return the latest state")
    }

    func testHostedCaptureContextKeepsLocalOwnershipHashOutOfManifest() throws {
        let binding = DiagnosticsBinding.hosted(
            serverRegistryID: "aHR0cHM6Ly9wZXJzb25hbC5leGFtcGxl",
            accountUserID: "account-42"
        )
        let context = DiagnosticsCaptureContext(
            binding: binding,
            profileID: "profile-secret",
            consentMode: .prompt,
            noticeVersion: 3,
            appVersion: "1.0",
            appBuild: "7",
            platform: .ios,
            osVersion: "26.0",
            destinationServerInstanceID: HostedDiagnosticsCapabilities.pinnedCollectorID
        )

        let draft = context.makeManifestDraft(
            type: .manual,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            crash: nil,
            deviceSummary: DiagnosticsManifest.DeviceSummary(
                manufacturer: "Apple",
                model: "iPhone",
                os: "26.0",
                formFactor: "phone"
            ),
            playbackSessionIDs: ["server-playback-session"],
            captureSessionID: "capture-session",
            consentMode: .manual
        )
        let data = try DiagnosticsJSONCoding.makeEncoder().encode(draft)
        let rendered = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(draft.destination.serverInstanceID, HostedDiagnosticsCapabilities.pinnedCollectorID)
        XCTAssertNil(draft.report.profileID)
        XCTAssertEqual(draft.playbackSessionIds, [])
        XCTAssertNotEqual(binding.accountUserID, "account-42")
        XCTAssertTrue(binding.accountUserID.hasPrefix("hosted-account:"))
        XCTAssertNotEqual(
            binding,
            DiagnosticsBinding.hosted(
                serverRegistryID: "aHR0cHM6Ly9wZXJzb25hbC5leGFtcGxl",
                accountUserID: "different-account"
            )
        )
        XCTAssertFalse(rendered.contains(binding.serverInstanceID))
        XCTAssertFalse(rendered.contains("account-42"))
        XCTAssertFalse(rendered.contains("profile-secret"))
        XCTAssertFalse(rendered.contains("personal.example"))
    }

    func testInstallationCredentialIsPersistedThroughIsolatedStoreAbstraction() async throws {
        let reportID = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        let bundle = Data("new-installation-bundle".utf8)
        let credentialStore = HostedTestCredentialStore(credential: nil)
        HostedDiagnosticsStubProtocol.configure(reportID: reportID, bundle: bundle)
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: credentialStore
        )

        _ = try await api.upload(
            reportID: reportID,
            manifest: makeManifest(),
            bundleData: bundle
        )

        XCTAssertEqual(credentialStore.saveCount, 1)
        XCTAssertEqual(
            credentialStore.load(),
            HostedDiagnosticsCredential(
                installationID: "install_apple_generated",
                installationToken: "generated-installation-token"
            )
        )
        let requests = HostedDiagnosticsStubProtocol.requests()
        XCTAssertEqual(requests.map(\.path).first, "/v1/installations")
        let installation = try XCTUnwrap(requests.first)
        XCTAssertEqual(installation.timeoutInterval, 10)
        XCTAssertNil(installation.authorization)
        XCTAssertNil(installation.cookieHeader)
        XCTAssertNil(installation.profileHeader)
        XCTAssertNil(installation.profileTokenHeader)
        XCTAssertNil(installation.siloDeviceIDHeader)
        let installationJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: installation.body) as? [String: Any]
        )
        XCTAssertEqual(
            Set(installationJSON.keys),
            Set(["platform", "app_id", "app_version", "app_build"])
        )
        XCTAssertFalse(String(decoding: installation.body, as: UTF8.self).contains("server_url"))
        for request in requests.dropFirst() {
            XCTAssertEqual(request.authorization, "Bearer generated-installation-token")
        }
    }

    func testConcurrentInstallationCredentialRequestsAreSingleFlight() async throws {
        let credentialStore = HostedTestCredentialStore(credential: nil)
        let unusedReportID = try XCTUnwrap(
            UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")
        )
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: credentialStore
        )
        HostedDiagnosticsStubProtocol.configure(
            reportID: unusedReportID,
            bundle: Data()
        )

        async let first = api.installationCredential(platform: .ios)
        async let second = api.installationCredential(platform: .ios)
        let credentials = try await [first, second]

        XCTAssertEqual(credentials[0], credentials[1])
        XCTAssertEqual(credentialStore.saveCount, 1)
        XCTAssertEqual(
            HostedDiagnosticsStubProtocol.requests().count {
                $0.method == "POST" && $0.path == "/v1/installations"
            },
            1
        )
    }

    func testRevokedInstallationTokenIsClearedAndReregisteredOnce() async throws {
        let reportID = try XCTUnwrap(UUID(uuidString: "12345678-90ab-cdef-1234-567890abcdef"))
        let bundle = Data("credential-recovery-bundle".utf8)
        let credentialStore = HostedTestCredentialStore(
            credential: HostedDiagnosticsCredential(
                installationID: "revoked-installation",
                installationToken: "revoked-installation-token"
            )
        )
        HostedDiagnosticsStubProtocol.configureInvalidTokenRecovery(
            reportID: reportID,
            bundle: bundle
        )
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: credentialStore
        )

        let response = try await api.upload(
            reportID: reportID,
            manifest: makeManifest(),
            bundleData: bundle
        )

        XCTAssertEqual(response.state, .processing)
        XCTAssertEqual(credentialStore.clearCount, 1)
        XCTAssertEqual(credentialStore.saveCount, 1)
        XCTAssertEqual(
            credentialStore.load(),
            HostedDiagnosticsCredential(
                installationID: "install_apple_generated",
                installationToken: "generated-installation-token"
            )
        )
        let requests = HostedDiagnosticsStubProtocol.requests()
        XCTAssertEqual(requests.map(\.path), [
            "/v1/reports",
            "/v1/installations",
            "/v1/reports",
            "/v1/reports/\(reportID.uuidString.lowercased())/bundle",
            "/v1/reports/\(reportID.uuidString.lowercased())",
        ])
        XCTAssertEqual(requests[0].authorization, "Bearer revoked-installation-token")
        XCTAssertNil(requests[1].authorization)
        for request in requests.dropFirst(2) {
            XCTAssertEqual(request.authorization, "Bearer generated-installation-token")
        }
    }

    func testManifestTokenIsRedactedInReturnedModelArchiveAndCreateEnvelope() async throws {
        let token = "manifest-token-that-must-never-leak"
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let binding = DiagnosticsBinding.hosted(
            serverRegistryID: "local-server-registry-id",
            accountUserID: "local-account-id"
        )
        let context = DiagnosticsCaptureContext(
            binding: binding,
            profileID: nil,
            consentMode: .manual,
            noticeVersion: 1,
            appVersion: token,
            appBuild: "7",
            platform: .ios,
            osVersion: "wss://[host:0123456789ab]/items/42",
            destinationServerInstanceID: HostedDiagnosticsCapabilities.pinnedCollectorID
        )
        let draft = context.makeManifestDraft(
            type: .manual,
            capturedAt: capturedAt,
            crash: nil,
            deviceSummary: DiagnosticsManifest.DeviceSummary(
                manufacturer: "Apple",
                model: "iPhone",
                os: "26.0",
                formFactor: "phone"
            ),
            playbackSessionIDs: [],
            consentMode: .manual
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HostedManifestRedaction-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = PendingReportStore(rootDirectory: root)
        let report = try store.save(PendingReportCapture(
            binding: binding,
            profileID: nil,
            type: .manual,
            fingerprint: "manifest-redaction",
            capturedAt: capturedAt,
            manifest: draft,
            deviceSnapshot: makeDeviceSnapshot(capturedAt: capturedAt),
            artifacts: []
        ))

        let bundle = try DiagnosticsBundleBuilder().build(
            report: report,
            logLines: [],
            droppedLogLines: 0,
            redactionTokens: [token]
        )
        XCTAssertEqual(bundle.manifest.report.appVersion, "[redacted_token]")
        XCTAssertEqual(bundle.manifest.report.osVersion, "wss://redacted.invalid/items/{id}")
        XCTAssertFalse(String(decoding: bundle.manifestData, as: UTF8.self).contains(token))

        let tar = try gunzip(bundle.bundleData)
        let embeddedData = try tarEntry(named: "manifest.json", in: tar)
        let embedded = try DiagnosticsJSONCoding.makeDecoder().decode(
            DiagnosticsManifestDraft.self,
            from: embeddedData
        )
        XCTAssertFalse(String(decoding: embeddedData, as: UTF8.self).contains(token))
        XCTAssertEqual(embedded.schemaVersion, bundle.manifest.schemaVersion)
        XCTAssertEqual(embedded.report, bundle.manifest.report)
        XCTAssertEqual(embedded.destination, bundle.manifest.destination)
        XCTAssertEqual(embedded.consent, bundle.manifest.consent)
        XCTAssertEqual(embedded.crash, bundle.manifest.crash)
        XCTAssertEqual(embedded.deviceSummary, bundle.manifest.deviceSummary)
        XCTAssertEqual(embedded.playbackSessionIds, bundle.manifest.playbackSessionIds)
        XCTAssertEqual(embedded.logSummary, bundle.manifest.logSummary)

        HostedDiagnosticsStubProtocol.configure(reportID: report.id, bundle: bundle.bundleData)
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: HostedTestCredentialStore(
                credential: HostedDiagnosticsCredential(
                    installationID: "install-manifest-redaction",
                    installationToken: "collector-credential"
                )
            )
        )
        _ = try await api.upload(
            reportID: report.id,
            manifest: bundle.manifest,
            bundleData: bundle.bundleData
        )

        let create = try XCTUnwrap(
            HostedDiagnosticsStubProtocol.requests().first(where: { $0.path == "/v1/reports" })
        )
        XCTAssertFalse(String(decoding: create.body, as: UTF8.self).contains(token))
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: create.body) as? [String: Any]
        )
        let envelopeManifestObject = try XCTUnwrap(envelope["manifest"])
        let envelopeManifestData = try JSONSerialization.data(withJSONObject: envelopeManifestObject)
        let envelopeManifest = try DiagnosticsJSONCoding.makeDecoder().decode(
            DiagnosticsManifest.self,
            from: envelopeManifestData
        )
        XCTAssertEqual(envelopeManifest, bundle.manifest)
        XCTAssertEqual(envelopeManifest.report, embedded.report)
    }

    func testHostedFrozenLogsAndBreadcrumbsDropPrivatePlaybackAttributes() async throws {
        let privateLogSessionID = "private-server-playback-session-log"
        let privateBreadcrumbSessionID = "private-server-playback-session-breadcrumb"
        let canonicalRunID = "0198a8f8-6c2d-7e31-8f44-62d198a10111"
        let privateBareUUID = "1198a8f8-6c2d-7e31-8f44-62d198a10112"
        let privateCompactUUID = "5e884898da28047151d0e56f8dc62927"
        let privateUppercaseCompactUUID = "5E884898DA28047151D0E56F8DC62927"
        let logLine = try XCTUnwrap(DiagLog.renderedLine(
            level: .info,
            category: .playback,
            tag: "CMP playback_session_id=\(privateLogSessionID) file_abcdefgh",
            message: "[CMP-ROUTE] playbackSessionId=\(privateLogSessionID) fileId=private-file-log planId=private-plan-log media=5.700124438 range=bytes=0-1023 bytes=67108864 anchorPlayer=0.0 bufAhead=0.0 generatedAhead=0.0 stationaryFor=0.0 cachedAheadBytes=67108864 maxLegacy=4294967295 mixedRadix=127.0x000001 hexDotted=0x7f.1 hexCode=0x7f000001 octalCode=017700000001 \"quotedMetric\":\"0.0\" quotedOctal='017700000001' publicVersion=8.8.8 ac.cur=0.0 ac.pts=0.0 ac.cur=017700000001 ac.pts=0x7f000001 ac.cur=127.0x000001 \"ac.cur\":\"0.0\" ac.pts : 0.0 ac.cur=-0.0 ac.pts=+127.1 shortCount=123456 tooLargeLegacy=4294967296 overflowHex=0x100000000 badOctal=018 wss://[host:0123456789ab]/items/42 http://127.0.0.1:49152/master.m3u8 host=127.0.0.1 http://127.42.7.9:49153/playlist.m3u8 \"host\":\"127.42.7.9\" \"playback_session_id\":\"private-json-session\" request \(privateBareUUID) compact (\(privateCompactUUID)), uppercase \(privateUppercaseCompactUUID); item_42 plan_abcdefgh item_count request_cancelled peer 127.42.7.8 file /Users/alice/private-title.mkv route selected",
            attrs: [
                "sink": .string("HDMI"),
                "fmt": .string("content_abcdefgh"),
                "width": .int(3840),
                "session_id": .string(privateLogSessionID),
                "play_method": .string("transcode"),
                "position_ms": .int(42_500),
                "reason": .string("private-route-reason"),
            ],
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            captureSessionID: canonicalRunID
        ))
        let breadcrumbLine = try XCTUnwrap(DiagLog.renderedLine(
            level: .info,
            category: .playback,
            tag: "PlaybackSessionBridge session_id=\(privateBreadcrumbSessionID) media_abcdefgh",
            message: "playback_session_id=\(privateBreadcrumbSessionID) itemId=private-item-breadcrumb mediaId=private-media-breadcrumb playback stopped",
            attrs: [
                "decoder": .string("VideoToolbox"),
                "dropped_frames": .int(2),
                "session_id": .string(privateBreadcrumbSessionID),
                "play_method": .string("direct_play"),
                "position_ms": .int(84_250),
                "reason": .string("private-stop-reason"),
            ],
            timestamp: Date(timeIntervalSince1970: 1_700_000_001),
            captureSessionID: canonicalRunID
        ))
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_002)
        let binding = DiagnosticsBinding.hosted(
            serverRegistryID: "private-local-server-registry-id",
            accountUserID: "private-local-account-id"
        )
        let context = DiagnosticsCaptureContext(
            binding: binding,
            profileID: nil,
            consentMode: .prompt,
            noticeVersion: 1,
            appVersion: "1.0",
            appBuild: "7",
            platform: .tvos,
            osVersion: "26.0",
            destinationServerInstanceID: HostedDiagnosticsCapabilities.pinnedCollectorID
        )
        let occurredAt = DiagnosticsTimestamp.string(from: capturedAt)
        let manifest = context.makeManifestDraft(
            type: .abnormalExit,
            capturedAt: capturedAt,
            crash: DiagnosticsCrashInfo(
                summary: "Silo did not shut down cleanly last time",
                stackExcerpt: nil,
                thread: nil,
                foreground: true,
                source: .exitSentinel,
                provenance: .postRestart,
                occurredAt: occurredAt
            ),
            deviceSummary: DiagnosticsManifest.DeviceSummary(
                manufacturer: "Apple",
                model: "Apple TV",
                os: "26.0",
                formFactor: "tv"
            ),
            playbackSessionIDs: [privateLogSessionID, privateBreadcrumbSessionID],
            captureSessionID: canonicalRunID
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HostedAttributePrivacy-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = PendingReportStore(rootDirectory: root)
        let report = try store.save(PendingReportCapture(
            binding: binding,
            profileID: nil,
            type: .abnormalExit,
            fingerprint: "hosted-private-attrs",
            capturedAt: capturedAt,
            manifest: manifest,
            deviceSnapshot: makeDeviceSnapshot(capturedAt: capturedAt),
            artifacts: [
                PendingReportArtifact(
                    relativePath: "logs.jsonl",
                    data: Data(logLine.appending("\n").utf8)
                ),
                PendingReportArtifact(
                    relativePath: "breadcrumbs.jsonl",
                    data: Data(breadcrumbLine.appending("\n").utf8)
                ),
                PendingReportArtifact(
                    relativePath: "crash/tombstone.pb",
                    data: Data("opaque-private-native-trace".utf8)
                ),
            ]
        ))
        let localBindingSidecar = try Data(contentsOf: report.directoryURL.appendingPathComponent(
            "binding.json"
        ))
        let renderedLocalBinding = String(decoding: localBindingSidecar, as: UTF8.self)
        XCTAssertFalse(renderedLocalBinding.contains("private-local-server-registry-id"))
        XCTAssertFalse(renderedLocalBinding.contains("private-local-account-id"))
        let localDeviceData = try Data(
            contentsOf: report.directoryURL.appendingPathComponent("device.json")
        )
        let localLogData = try Data(
            contentsOf: report.directoryURL.appendingPathComponent("logs.jsonl")
        )
        XCTAssertTrue(String(decoding: localLogData, as: UTF8.self).contains("anchorPlayer=0.0"))
        XCTAssertTrue(String(decoding: localDeviceData, as: UTF8.self).contains("uid_hash"))
        XCTAssertTrue(String(decoding: localDeviceData, as: UTF8.self).contains("route_hashes"))
        XCTAssertTrue(String(decoding: localDeviceData, as: UTF8.self).contains("server_url"))
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: HostedTestCredentialStore(
                credential: HostedDiagnosticsCredential(
                    installationID: "install-attribute-privacy",
                    installationToken: "collector-attribute-privacy-token"
                )
            )
        )
        let coordinator = DiagnosticsCoordinator(hostedAPI: api, pendingStore: store)

        let bundle = try await coordinator.buildBundle(for: report)
        let tar = try gunzip(bundle.bundleData)
        let logsData = try tarEntry(named: "logs.jsonl", in: tar)
        let breadcrumbsData = try tarEntry(named: "breadcrumbs.jsonl", in: tar)
        let hostedDeviceData = try tarEntry(named: "device.json", in: tar)
        let hostedLog = try XCTUnwrap(decodeLogLines(logsData).first)
        let hostedBreadcrumb = try XCTUnwrap(decodeLogLines(breadcrumbsData).first)

        XCTAssertEqual(hostedLog.attrs, [
            "fmt": .string("[redacted_private_id]"),
            "sink": .string("HDMI"),
            "width": .int(3840),
        ])
        XCTAssertEqual(hostedBreadcrumb.attrs, [
            "decoder": .string("VideoToolbox"),
            "dropped_frames": .int(2),
        ])
        assertPassesCanonicalHostedV1Registry(hostedLog)
        assertPassesCanonicalHostedV1Registry(hostedBreadcrumb)

        let renderedEvidence = String(decoding: logsData + breadcrumbsData, as: UTF8.self)
        for forbidden in [
            "session_id",
            "play_method",
            "position_ms",
            "reason",
            privateLogSessionID,
            privateBreadcrumbSessionID,
            "private-route-reason",
            "private-stop-reason",
            "private-file-log",
            "private-plan-log",
            "private-json-session",
            "private-item-breadcrumb",
            "private-media-breadcrumb",
            binding.serverInstanceID,
            "private-local-account-id",
            "127.0.0.1",
            "127.42.7.9",
            "127.42.7.8",
            privateBareUUID,
            privateCompactUUID,
            privateUppercaseCompactUUID,
            "file_abcdefgh",
            "item_42",
            "plan_abcdefgh",
            "content_abcdefgh",
            "media_abcdefgh",
            "/Users/alice/private-title.mkv",
        ] {
            XCTAssertFalse(renderedEvidence.contains(forbidden), forbidden)
        }
        XCTAssertTrue(renderedEvidence.contains("[redacted_path]"))
        XCTAssertTrue(hostedLog.msg.contains("[redacted_private_id]"))
        XCTAssertTrue(hostedLog.msg.contains("mediaSeconds=5p700124438s"))
        XCTAssertFalse(hostedLog.msg.contains("media=5.700124438"))
        XCTAssertTrue(hostedLog.msg.contains("range=bytes=0-1023"))
        XCTAssertTrue(hostedLog.msg.contains("bytes=67108864B"))
        for key in [
            "anchorPlayer", "bufAhead", "generatedAhead", "stationaryFor",
            "cachedAheadBytes", "maxLegacy", "hexCode", "octalCode", "mixedRadix",
            "hexDotted",
        ] {
            XCTAssertTrue(
                hostedLog.msg.contains("\(key)=[redacted_network_identity]"),
                hostedLog.msg
            )
        }
        XCTAssertTrue(
            hostedLog.msg.contains(#""quotedMetric":"[redacted_network_identity]""#),
            hostedLog.msg
        )
        XCTAssertTrue(
            hostedLog.msg.contains("quotedOctal='[redacted_network_identity]'"),
            hostedLog.msg
        )
        for preserved in [
            "publicVersion=8.8.8", "ac.cur=0.0", "ac.pts=0.0", "shortCount=123456",
            "tooLargeLegacy=4294967296", "overflowHex=0x100000000", "badOctal=018",
        ] {
            XCTAssertTrue(hostedLog.msg.contains(preserved), hostedLog.msg)
        }
        for removed in [
            "ac.cur=017700000001", "ac.pts=0x7f000001", "ac.cur=127.0x000001",
            #""ac.cur":"0.0""#, "ac.pts : 0.0", "ac.cur=-0.0", "ac.pts=+127.1",
        ] {
            XCTAssertFalse(hostedLog.msg.contains(removed), hostedLog.msg)
        }
        XCTAssertTrue(
            hostedLog.msg.contains(#""ac.cur":"[redacted_network_identity]""#),
            hostedLog.msg
        )
        XCTAssertTrue(
            hostedLog.msg.contains("ac.pts : [redacted_network_identity]"),
            hostedLog.msg
        )
        XCTAssertTrue(hostedLog.msg.contains("item_count"))
        XCTAssertTrue(hostedLog.msg.contains("request_cancelled"))
        XCTAssertEqual(hostedLog.run, canonicalRunID)
        XCTAssertEqual(hostedBreadcrumb.run, canonicalRunID)
        XCTAssertEqual(bundle.manifest.report.captureSessionID, canonicalRunID)
        XCTAssertTrue(hostedLog.msg.contains("wss://redacted.invalid/items/{id}"))
        XCTAssertTrue(
            hostedLog.msg.contains("http://redacted.invalid/master.m3u8"),
            hostedLog.msg
        )
        XCTAssertTrue(
            hostedLog.msg.contains("http://redacted.invalid/playlist.m3u8"),
            hostedLog.msg
        )
        XCTAssertFalse(hostedLog.msg.contains("host="), hostedLog.msg)
        XCTAssertFalse(hostedLog.msg.contains("[host:"))
        XCTAssertTrue(hostedBreadcrumb.tag.contains("[redacted_private_id]"))
        XCTAssertEqual(bundle.manifest.playbackSessionIds, [])
        XCTAssertFalse(bundle.manifest.archive.entries.contains("crash/tombstone.pb"))
        XCTAssertFalse(String(decoding: hostedDeviceData, as: UTF8.self).contains("uid_hash"))
        XCTAssertFalse(String(decoding: hostedDeviceData, as: UTF8.self).contains("route_hashes"))
        XCTAssertFalse(String(decoding: hostedDeviceData, as: UTF8.self).contains("server_url"))
        XCTAssertFalse(String(decoding: hostedDeviceData, as: UTF8.self).contains("127.0.0.1"))
        XCTAssertEqual(bundle.manifest.logSummary.lines, 1)
        XCTAssertEqual(
            bundle.manifest.logSummary.bytesGz,
            try DiagnosticsBundleBuilder.gzip(logsData).count
        )
        XCTAssertEqual(
            bundle.manifest.destination.serverInstanceID,
            HostedDiagnosticsCapabilities.pinnedCollectorID
        )
    }

    func testHostedMetricKitBundleDropsContainerPathsAndNormalizesLoopbackOnlyForHosted() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_700_100_000)
        let privateContainerID = "01234567-89ab-4def-8123-456789abcdef"
        let privateBareUUID = "1198a8f8-6c2d-7e31-8f44-62d198a10112"
        let privateBareItemID = "item_42"
        let privateBarePlanID = "plan_abcdefgh"
        let privateManifestID = "content_abcdefgh"
        let privateDeviceSummaryID = "device_abcdefgh"
        let privateCompactUUIDKey = "5e884898da28047151d0e56f8dc62927"
        let metricKitBinaryUUID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let privatePath = "/private/var/mobile/Containers/Data/Application/\(privateContainerID)/Silo.app/Silo"
        let rawStack = Data(
            "frame \(privateBareUUID) \(privateBareItemID) \(privateBarePlanID)\n".utf8
        )
        let rawMetricKit = try JSONSerialization.data(withJSONObject: [
            "diagnosticMetaData": [
                "virtualMemoryRegionInfo": "mapped image \(privatePath)",
                "exceptionReason": "container[\(privatePath)] loopback request http://127.0.0.1:49152/items/42 failed for \(privateBareUUID) \(privateBareItemID) \(privateBarePlanID)",
                privateCompactUUIDKey: "private-keyed-value",
            ],
            "callStacks": [
                "callStackRootFrames": [[
                    "binaryName": "libsystem_kernel.dylib",
                    "binaryUUID": metricKitBinaryUUID,
                    "symbolName": "__pthread_kill",
                    "offsetIntoBinaryTextSegment": 42,
                    "address": 4_294_967_296,
                ]],
            ],
        ], options: [.sortedKeys, .withoutEscapingSlashes])

        func saveReport(
            binding: DiagnosticsBinding,
            destinationServerInstanceID: String,
            rootLabel: String
        ) throws -> PendingReport {
            let context = DiagnosticsCaptureContext(
                binding: binding,
                profileID: nil,
                consentMode: .manual,
                noticeVersion: 1,
                appVersion: "1.0 \(privateManifestID)",
                appBuild: "7",
                platform: .ios,
                osVersion: "26.0",
                destinationServerInstanceID: destinationServerInstanceID
            )
            let occurredAt = DiagnosticsTimestamp.string(from: capturedAt)
            let manifest = context.makeManifestDraft(
                type: .crash,
                capturedAt: capturedAt,
                crash: DiagnosticsCrashInfo(
                    summary: "Crash reported by MetricKit: libsystem_kernel.dylib at \(privatePath) \(privateBareUUID)",
                    stackExcerpt: "libsystem_kernel.dylib at \(privatePath) \(privateBareItemID)",
                    thread: "worker http://[::1]:49152/items/42 \(privateBarePlanID)",
                    foreground: true,
                    source: .metrickit,
                    provenance: .metricReportingPeriod,
                    occurredAt: occurredAt,
                    occurredAtStart: occurredAt,
                    occurredAtEnd: occurredAt
                ),
                deviceSummary: DiagnosticsManifest.DeviceSummary(
                    manufacturer: "Apple",
                    model: "iPhone \(privateDeviceSummaryID)",
                    os: "26.0",
                    formFactor: "phone"
                ),
                playbackSessionIDs: []
            )
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "HostedMetricKit-\(rootLabel)-\(UUID().uuidString)",
                isDirectory: true
            )
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let store = PendingReportStore(rootDirectory: root)
            return try store.save(PendingReportCapture(
                binding: binding,
                profileID: nil,
                type: .crash,
                fingerprint: rootLabel,
                capturedAt: capturedAt,
                manifest: manifest,
                deviceSnapshot: makeDeviceSnapshot(capturedAt: capturedAt),
                artifacts: [
                    PendingReportArtifact(relativePath: "crash/metrickit.json", data: rawMetricKit),
                    PendingReportArtifact(relativePath: "crash/stack.txt", data: rawStack),
                ]
            ))
        }

        let hostedReport = try saveReport(
            binding: .hosted(
                serverRegistryID: "private-source-server",
                accountUserID: "private-source-account"
            ),
            destinationServerInstanceID: HostedDiagnosticsCapabilities.pinnedCollectorID,
            rootLabel: "hosted"
        )
        let hostedBundle = try DiagnosticsBundleBuilder().build(
            report: hostedReport,
            logLines: [],
            droppedLogLines: 0
        )
        let hostedTar = try gunzip(hostedBundle.bundleData)
        let hostedMetricKit = try tarEntry(named: "crash/metrickit.json", in: hostedTar)
        let hostedStack = try tarEntry(named: "crash/stack.txt", in: hostedTar)
        let hostedEmbeddedManifest = try tarEntry(named: "manifest.json", in: hostedTar)
        let hostedEvidence = String(
            decoding: hostedMetricKit + hostedStack + hostedEmbeddedManifest
                + hostedBundle.manifestData,
            as: UTF8.self
        )

        for forbidden in [
            "virtualMemoryRegionInfo",
            privateContainerID,
            privatePath,
            "/private/var",
            "127.0.0.1",
            "[::1]",
            privateBareUUID,
            privateBareItemID,
            privateBarePlanID,
            privateManifestID,
            privateDeviceSummaryID,
            privateCompactUUIDKey,
            "private-keyed-value",
        ] {
            XCTAssertFalse(hostedEvidence.contains(forbidden), forbidden)
        }
        XCTAssertFalse(hostedEvidence.contains("libsystem_kernel.dylib"))
        XCTAssertFalse(hostedEvidence.contains(#""address""#))
        XCTAssertTrue(hostedEvidence.contains("apple-native-library"))
        XCTAssertTrue(hostedEvidence.contains(metricKitBinaryUUID))
        XCTAssertTrue(hostedEvidence.contains("[redacted_private_id]"))
        XCTAssertTrue(hostedEvidence.contains("[redacted_path]"))
        XCTAssertTrue(hostedEvidence.contains("http://redacted.invalid:49152/items/{id}"))

        let selfHostedReport = try saveReport(
            binding: DiagnosticsBinding(
                serverInstanceID: "self-hosted-server-instance",
                accountUserID: "self-hosted-account"
            ),
            destinationServerInstanceID: "self-hosted-server-instance",
            rootLabel: "self-hosted"
        )
        let selfHostedBundle = try DiagnosticsBundleBuilder().build(
            report: selfHostedReport,
            logLines: [],
            droppedLogLines: 0
        )
        let selfHostedMetricKit = try tarEntry(
            named: "crash/metrickit.json",
            in: gunzip(selfHostedBundle.bundleData)
        )
        XCTAssertEqual(selfHostedMetricKit, rawMetricKit)
        let selfHostedStack = try tarEntry(
            named: "crash/stack.txt",
            in: gunzip(selfHostedBundle.bundleData)
        )
        XCTAssertEqual(selfHostedStack, rawStack)
        let selfHostedManifest = try DiagnosticsJSONCoding.makeDecoder().decode(
            DiagnosticsManifest.self,
            from: selfHostedBundle.manifestData
        )
        XCTAssertTrue(selfHostedManifest.crash?.summary.contains(privateBareUUID) == true)
        XCTAssertTrue(selfHostedManifest.crash?.stackExcerpt?.contains(privateBareItemID) == true)
        XCTAssertTrue(selfHostedManifest.crash?.thread?.contains(privateBarePlanID) == true)
        XCTAssertTrue(selfHostedManifest.report.appVersion.contains(privateManifestID))
        XCTAssertTrue(selfHostedManifest.deviceSummary.model.contains(privateDeviceSummaryID))
    }

    func testHostedDeviceSnapshotRedactsBarePrivateIdentifiersInNestedValues() throws {
        let privateUUID = "1198a8f8-6c2d-7e31-8f44-62d198a10112"
        let privateCompactUUIDKey = "5e884898da28047151d0e56f8dc62927"
        let snapshot = DeviceSnapshotPayload(
            capturedAt: DiagnosticsTimestamp.string(from: Date(timeIntervalSince1970: 1_700_200_000)),
            provenance: .preFailure,
            identity: .object([
                "manufacturer": .string("Apple"),
                "model": .string("iPhone item_42"),
                privateCompactUUIDKey: .string("private-keyed-value"),
            ]),
            display: .object([
                "mode": .string("request_cancelled"),
            ]),
            audio: .object([
                "status": .array([.string("plan_abcdefgh"), .string(privateUUID)]),
            ]),
            videoCodecs: .array([
                .object(["decoder": .string("file_abcdefgh")]),
            ]),
            network: .object(["transport": .string("not_collected")])
        )
        let raw = try DiagnosticsJSONCoding.makeEncoder().encode(snapshot)
        let sanitized = try DiagnosticsBundleBuilder.sanitizeHostedDeviceJSON(raw)
        let rendered = String(decoding: sanitized, as: UTF8.self)

        for forbidden in [
            privateUUID,
            privateCompactUUIDKey,
            "private-keyed-value",
            "item_42",
            "plan_abcdefgh",
            "file_abcdefgh",
        ] {
            XCTAssertFalse(rendered.contains(forbidden), forbidden)
        }
        XCTAssertTrue(rendered.contains("[redacted_private_id]"))
        XCTAssertTrue(rendered.contains("request_cancelled"))
        XCTAssertTrue(String(decoding: raw, as: UTF8.self).contains(privateUUID))
        XCTAssertTrue(String(decoding: raw, as: UTF8.self).contains(privateCompactUUIDKey))
    }

    func testManualHostedBundleIsDeterministicAcrossLiveRingAndDebugChanges() async throws {
        let consentStore = DiagnosticsConsentStore.shared
        let originalDebugLogging = consentStore.debugLoggingEnabled
        defer {
            consentStore.debugLoggingEnabled = originalDebugLogging
            DiagLog.ring.clear()
        }
        consentStore.debugLoggingEnabled = false
        DiagLog.ring.clear()

        let frozenLine = try XCTUnwrap(DiagLog.renderedLine(
            level: .info,
            category: .lifecycle,
            tag: "ManualCapture",
            message: "frozen evidence",
            attrs: ["state": .string("foreground")],
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            captureSessionID: "manual-frozen-run"
        ))
        let beforeBuildLine = try XCTUnwrap(DiagLog.renderedLine(
            level: .info,
            category: .lifecycle,
            tag: "LiveRing",
            message: "before first build",
            timestamp: Date(timeIntervalSince1970: 1_700_000_010),
            captureSessionID: "different-live-run"
        ))
        DiagLog.ring.append(beforeBuildLine)

        let capturedAt = Date(timeIntervalSince1970: 1_700_000_001)
        let binding = DiagnosticsBinding.hosted(
            serverRegistryID: "manual-source-server",
            accountUserID: "manual-source-account"
        )
        let context = DiagnosticsCaptureContext(
            binding: binding,
            profileID: nil,
            consentMode: .manual,
            noticeVersion: 1,
            appVersion: "1.0",
            appBuild: "7",
            platform: .ios,
            osVersion: "26.0",
            destinationServerInstanceID: HostedDiagnosticsCapabilities.pinnedCollectorID
        )
        let draft = context.makeManifestDraft(
            type: .manual,
            capturedAt: capturedAt,
            crash: nil,
            deviceSummary: DiagnosticsManifest.DeviceSummary(
                manufacturer: "Apple",
                model: "iPhone",
                os: "26.0",
                formFactor: "phone"
            ),
            playbackSessionIDs: [],
            captureSessionID: "manual-frozen-run",
            consentMode: .manual
        )
        let evidence = DiagnosticsCoordinator.frozenManualEvidence(
            manifest: draft,
            logSnapshot: LogRingSnapshot(lines: [frozenLine], droppedCount: 7)
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HostedManualDeterminism-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = PendingReportStore(rootDirectory: root)
        let report = try store.save(PendingReportCapture(
            binding: binding,
            profileID: nil,
            type: .manual,
            fingerprint: "manual-determinism",
            capturedAt: capturedAt,
            manifest: evidence.manifest,
            deviceSnapshot: makeDeviceSnapshot(capturedAt: capturedAt),
            artifacts: [evidence.artifact]
        ))
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: HostedTestCredentialStore(
                credential: HostedDiagnosticsCredential(
                    installationID: "install-manual-determinism",
                    installationToken: "collector-manual-determinism-token"
                )
            )
        )
        let coordinator = DiagnosticsCoordinator(hostedAPI: api, pendingStore: store)

        let first = try await coordinator.buildBundle(for: report)

        DiagLog.ring.clear()
        let afterBuildLine = try XCTUnwrap(DiagLog.renderedLine(
            level: .error,
            category: .lifecycle,
            tag: "LiveRing",
            message: "after first build",
            timestamp: Date(timeIntervalSince1970: 1_700_000_020),
            captureSessionID: "another-live-run"
        ))
        DiagLog.ring.append(afterBuildLine)
        consentStore.debugLoggingEnabled = true

        let second = try await coordinator.buildBundle(for: report)

        XCTAssertEqual(first.manifest, second.manifest)
        XCTAssertEqual(first.manifestData, second.manifestData)
        XCTAssertEqual(first.bundleData, second.bundleData)
        XCTAssertEqual(
            DiagnosticsSHA256.hex(data: first.bundleData),
            DiagnosticsSHA256.hex(data: second.bundleData)
        )
        XCTAssertEqual(first.manifest.logSummary.droppedLines, 7)
        XCTAssertFalse(first.manifest.logSummary.debugLogging)
        let logs = try tarEntry(named: "logs.jsonl", in: gunzip(first.bundleData))
        let renderedLogs = String(decoding: logs, as: UTF8.self)
        XCTAssertTrue(renderedLogs.contains("frozen evidence"))
        XCTAssertFalse(renderedLogs.contains("before first build"))
        XCTAssertFalse(renderedLogs.contains("after first build"))
    }

    func testHostedInstallationTokenIsIncludedInExactMatchBundleRedaction() async throws {
        let token = "hosted-token-that-must-never-leak"
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: HostedTestCredentialStore(
                credential: HostedDiagnosticsCredential(
                    installationID: "install-redaction-test",
                    installationToken: token
                )
            )
        )

        let redactionTokens = DiagnosticsCoordinator.mergeRedactionTokens(
            ["silo-access-token"],
            hostedInstallationToken: await api.installationTokenForRedaction()
        )
        let scrubbed = DiagnosticsBundleBuilder.scrubExactTokenMatches(
            in: Data("collector_auth=\(token)".utf8),
            tokens: redactionTokens
        )
        let rendered = String(decoding: scrubbed, as: UTF8.self)

        XCTAssertFalse(rendered.contains(token))
        XCTAssertEqual(rendered, "collector_auth=[redacted_token]")
    }

    func testHostedEnvelopeIsFrozenUntilDefinitiveStaleConsentThenReframedFromSanitizedEvidence() throws {
        let oldToken = "old-opaque-token-that-must-stay-redacted"
        let fixture = try makePendingHostedReport(label: "frozen-envelope")
        try FileManager.default.createDirectory(
            at: fixture.report.directoryURL.appendingPathComponent("crash", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("token=\(oldToken)".utf8).write(
            to: fixture.report.directoryURL.appendingPathComponent("crash/stack.txt"),
            options: .atomic
        )
        let builder = DiagnosticsBundleBuilder()
        let first = try builder.build(
            report: fixture.report,
            logLines: [],
            droppedLogLines: 0,
            redactionTokens: [oldToken]
        )
        try fixture.store.saveHostedEnvelope(first, for: fixture.report)

        let exact: DiagnosticsBundleBuildResult
        switch fixture.store.loadHostedEnvelope(for: fixture.report) {
        case .available(let cached):
            exact = cached
        default:
            XCTFail("The committed hosted envelope must load")
            return
        }
        XCTAssertEqual(exact.manifestData, first.manifestData)
        XCTAssertEqual(exact.bundleData, first.bundleData)

        fixture.store.markHostedConsentRefreshRequired(fixture.report)
        let refreshed = try builder.reframeHosted(
            cached: exact,
            consent: DiagnosticsManifest.Consent(mode: .manual, noticeVersion: 2)
        )
        XCTAssertEqual(refreshed.manifest.consent.noticeVersion, 2)
        let refreshedTar = try gunzip(refreshed.bundleData)
        let refreshedStack = try tarEntry(named: "crash/stack.txt", in: refreshedTar)
        XCTAssertFalse(String(decoding: refreshedStack, as: UTF8.self).contains(oldToken))
        XCTAssertEqual(
            Array(refreshed.archiveEntries.dropFirst()).map(\.data),
            Array(first.archiveEntries.dropFirst()).map(\.data)
        )
        XCTAssertNotEqual(refreshed.bundleData, first.bundleData)

        try fixture.store.saveHostedEnvelope(refreshed, for: fixture.report)
        guard case .available(let persisted) = fixture.store.loadHostedEnvelope(for: fixture.report) else {
            XCTFail("The reframed hosted envelope must load")
            return
        }
        XCTAssertEqual(persisted.manifestData, refreshed.manifestData)
        XCTAssertEqual(persisted.bundleData, refreshed.bundleData)
    }

    func testIncompleteHostedEnvelopeStagingIsDiscardedBeforeAnyNetworkBoundary() throws {
        let fixture = try makePendingHostedReport(label: "staging-recovery")
        let staging = fixture.report.directoryURL.appendingPathComponent(
            ".hosted-envelope-staging-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: staging.appendingPathComponent("manifest.json"))

        guard case .missing = fixture.store.loadHostedEnvelope(for: fixture.report) else {
            return XCTFail("A never-published staging directory must be safely rebuildable")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))
    }

    func testCommittedHostedEnvelopeDetectsEntryCorruptionAndKeepsRawEvidence() throws {
        let fixture = try makePendingHostedReport(label: "published-corruption")
        let bundle = try DiagnosticsBundleBuilder().build(
            report: fixture.report,
            logLines: [],
            droppedLogLines: 0
        )
        try fixture.store.saveHostedEnvelope(bundle, for: fixture.report)
        let generation = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.report.directoryURL,
                includingPropertiesForKeys: nil
            ).first {
                $0.lastPathComponent.hasPrefix(".hosted-envelope-")
                    && !$0.lastPathComponent.hasPrefix(".hosted-envelope-staging-")
            }
        )
        try Data("tampered-device-evidence".utf8).write(
            to: generation.appendingPathComponent("entries/device.json"),
            options: .atomic
        )

        guard case .corrupt = fixture.store.loadHostedEnvelope(for: fixture.report) else {
            return XCTFail("A committed generation with altered members must fail closed")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))
    }

    func testHostedProcessingAndRejectionStateRetainLocalEvidence() throws {
        let fixture = try makePendingHostedReport(label: "processing-state")

        fixture.store.markHostedProcessing(fixture.report, shortID: "SILO-PROCESSING")
        var persisted = try XCTUnwrap(
            fixture.store.listReports(for: fixture.report.binding.binding, now: Date()).first
        )
        XCTAssertEqual(persisted.state.hostedRemoteShortID, "SILO-PROCESSING")
        XCTAssertFalse(persisted.state.isPermanentFailure)

        fixture.store.markHostedRejected(persisted, code: "privacy_artifact_rejected")
        persisted = try XCTUnwrap(
            fixture.store.listReports(for: fixture.report.binding.binding, now: Date()).first
        )
        XCTAssertNil(persisted.state.hostedRemoteShortID)
        XCTAssertEqual(persisted.state.hostedRejectionCode, "privacy_artifact_rejected")
        XCTAssertTrue(persisted.state.isPermanentFailure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))
    }

    func testHostedDeleteIntentRemovesEvidenceAndRetriesUntilCollectorAccepts() async throws {
        let fixture = try makePendingHostedReport(label: "durable-delete-intent")
        let bundle = try DiagnosticsBundleBuilder().build(
            report: fixture.report,
            logLines: [],
            droppedLogLines: 0
        )
        try fixture.store.saveHostedEnvelope(bundle, for: fixture.report)
        let root = fixture.report.directoryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let backup = root.appendingPathComponent("delete-crash-backup", isDirectory: true)
        try FileManager.default.copyItem(at: fixture.report.directoryURL, to: backup)
        defer { try? FileManager.default.removeItem(at: backup) }
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: HostedTestCredentialStore(
                credential: HostedDiagnosticsCredential(
                    installationID: "install-delete-retry",
                    installationToken: "delete-retry-token"
                )
            )
        )
        let coordinator = DiagnosticsCoordinator(hostedAPI: api, pendingStore: fixture.store)

        HostedDiagnosticsStubProtocol.configureDelete(
            reportID: fixture.report.id,
            statusCode: 503
        )
        let erased = await coordinator.delete(report: fixture.report)
        XCTAssertFalse(erased)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))

        // Model a process stop after the atomic intent write but before the
        // report directory removal. Loading the durable queue must finish the
        // local erasure before the report can reappear or be sent.
        try FileManager.default.copyItem(at: backup, to: fixture.report.directoryURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))
        let retryBatch = fixture.store.prepareHostedDeletionRetries()
        XCTAssertEqual(retryBatch.reportIDs, [fixture.report.id])
        XCTAssertFalse(retryBatch.hasBlockedLocalEvidence)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))
        let intentBytes = try Data(
            contentsOf: root.appendingPathComponent("hosted-deletion-intents.json")
        )
        let renderedIntent = String(decoding: intentBytes, as: UTF8.self)
        XCTAssertTrue(renderedIntent.contains(fixture.report.id.uuidString.lowercased()))
        XCTAssertFalse(renderedIntent.contains(fixture.report.binding.serverInstanceID))
        XCTAssertFalse(renderedIntent.contains(fixture.report.binding.accountUserID))

        HostedDiagnosticsStubProtocol.configureDelete(
            reportID: fixture.report.id,
            statusCode: 204
        )
        _ = await coordinator.retryHostedDeletions()
        XCTAssertTrue(try fixture.store.hostedDeletionIntents().isEmpty)
    }

    func testForegroundDeletionMaintenanceBoundsEachRetryPass() async throws {
        let fixture = try makePendingHostedReport(label: "bounded-delete-0")
        let capturedAt = fixture.report.binding.capturedAtDate
        let reports = try [
            fixture.report,
            saveAdditionalHostedReport(
                in: fixture.store,
                binding: fixture.report.binding.binding,
                label: "bounded-delete-1",
                capturedAt: capturedAt.addingTimeInterval(1)
            ),
            saveAdditionalHostedReport(
                in: fixture.store,
                binding: fixture.report.binding.binding,
                label: "bounded-delete-2",
                capturedAt: capturedAt.addingTimeInterval(2)
            ),
        ]
        for report in reports {
            try fixture.store.stageHostedDeletionAndDelete(
                report,
                forceRemoteIntent: true
            )
        }
        HostedDiagnosticsStubProtocol.configureDelete(
            reportID: reports[0].id,
            statusCode: 204
        )
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: HostedTestCredentialStore(
                credential: HostedDiagnosticsCredential(
                    installationID: "install-bounded-delete",
                    installationToken: "bounded-delete-token"
                )
            )
        )
        let coordinator = DiagnosticsCoordinator(
            hostedAPI: api,
            pendingStore: fixture.store
        )

        let completedAll = await coordinator.retryHostedDeletions(maximumAttempts: 2)

        XCTAssertFalse(completedAll)
        XCTAssertEqual(
            HostedDiagnosticsStubProtocol.requests().count { $0.method == "DELETE" },
            2
        )
        XCTAssertFalse(try fixture.store.hostedDeletionIntents().isEmpty)
    }

    func testExplicitHostedDeletePrioritizesTheSelectedReport() async throws {
        let fixture = try makePendingHostedReport(label: "selected-delete-backlog")
        let selected = try saveAdditionalHostedReport(
            in: fixture.store,
            binding: fixture.report.binding.binding,
            label: "selected-delete",
            capturedAt: fixture.report.binding.capturedAtDate.addingTimeInterval(1)
        )
        try fixture.store.stageHostedDeletionAndDelete(
            fixture.report,
            forceRemoteIntent: true
        )
        HostedDiagnosticsStubProtocol.configureDelete(
            reportID: selected.id,
            statusCode: 204
        )
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: HostedTestCredentialStore(
                credential: HostedDiagnosticsCredential(
                    installationID: "install-selected-delete",
                    installationToken: "selected-delete-token"
                )
            )
        )
        let coordinator = DiagnosticsCoordinator(hostedAPI: api, pendingStore: fixture.store)

        let erased = await coordinator.delete(report: selected)
        XCTAssertTrue(erased)

        let firstDelete = try XCTUnwrap(
            HostedDiagnosticsStubProtocol.requests().first(where: { $0.method == "DELETE" })
        )
        XCTAssertEqual(
            firstDelete.path,
            "/v1/reports/\(selected.id.uuidString.lowercased())"
        )
    }

    func testTurnOffStagesRemoteErasureBeforePurgingHostedEvidence() async throws {
        let fixture = try makePendingHostedReport(label: "turn-off-delete")
        let bundle = try DiagnosticsBundleBuilder().build(
            report: fixture.report,
            logLines: [],
            droppedLogLines: 0
        )
        try fixture.store.saveHostedEnvelope(bundle, for: fixture.report)
        HostedDiagnosticsStubProtocol.configureDelete(
            reportID: fixture.report.id,
            statusCode: 503
        )
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: HostedTestCredentialStore(
                credential: HostedDiagnosticsCredential(
                    installationID: "install-turn-off",
                    installationToken: "turn-off-delete-token"
                )
            )
        )
        let coordinator = DiagnosticsCoordinator(hostedAPI: api, pendingStore: fixture.store)

        let erased = await coordinator.turnOffAndDelete(binding: fixture.report.binding.binding)
        XCTAssertFalse(erased)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))
        XCTAssertEqual(try fixture.store.hostedDeletionIntents(), [fixture.report.id])
    }

    func testHostedUploadFenceDefersExplicitDeleteUntilNetworkHandoffSettles() async throws {
        let fixture = try makePendingHostedReport(label: "delete-during-create")
        HostedDiagnosticsStubProtocol.configureDelete(
            reportID: fixture.report.id,
            statusCode: 204
        )
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: HostedTestCredentialStore(
                credential: HostedDiagnosticsCredential(
                    installationID: "install-create-delete-race",
                    installationToken: "create-delete-race-token"
                )
            )
        )
        let coordinator = DiagnosticsCoordinator(hostedAPI: api, pendingStore: fixture.store)

        let began = await coordinator.beginHostedUploadFence(for: fixture.report)
        XCTAssertTrue(began)
        await coordinator.markHostedNetworkHandoff(reportID: fixture.report.id)

        // Delete wins locally and durably, but the collector request waits
        // until the possibly accepted create has stopped using this UUID.
        let erasedWhileUploading = await coordinator.delete(report: fixture.report)
        XCTAssertFalse(erasedWhileUploading)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))
        XCTAssertEqual(try fixture.store.hostedDeletionIntents(), [fixture.report.id])
        XCTAssertTrue(HostedDiagnosticsStubProtocol.requests().isEmpty)

        let erasedAfterUpload = await coordinator.endHostedUploadFence(reportID: fixture.report.id)
        XCTAssertTrue(erasedAfterUpload)
        XCTAssertTrue(try fixture.store.hostedDeletionIntents().isEmpty)
        XCTAssertEqual(HostedDiagnosticsStubProtocol.requests().map(\.method), ["DELETE"])
    }

    func testTurnOffErasesReadyHandoffAfterPendingDirectoryIsAlreadyGone() async throws {
        let fixture = try makePendingHostedReport(label: "turn-off-after-ready")
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: HostedTestCredentialStore(
                credential: HostedDiagnosticsCredential(
                    installationID: "install-ready-turn-off-race",
                    installationToken: "ready-turn-off-race-token"
                )
            )
        )
        let coordinator = DiagnosticsCoordinator(hostedAPI: api, pendingStore: fixture.store)

        let began = await coordinator.beginHostedUploadFence(for: fixture.report)
        XCTAssertTrue(began)
        await coordinator.markHostedNetworkHandoff(reportID: fixture.report.id)
        try fixture.store.recordHostedReadyAndDelete(fixture.report)
        _ = await coordinator.endHostedUploadFence(reportID: fixture.report.id)

        HostedDiagnosticsStubProtocol.configureDelete(
            reportID: fixture.report.id,
            statusCode: 204
        )
        let erased = await coordinator.turnOffAndDelete(binding: fixture.report.binding.binding)

        XCTAssertTrue(erased)
        XCTAssertTrue(try fixture.store.hostedDeletionIntents().isEmpty)
        XCTAssertEqual(HostedDiagnosticsStubProtocol.requests().map(\.method), ["DELETE"])
        XCTAssertEqual(
            HostedDiagnosticsStubProtocol.requests().map(\.path),
            ["/v1/reports/\(fixture.report.id.uuidString.lowercased())"]
        )
    }

    func testReadyReceiptSurvivesRestartAndTurnOffErasesRemoteReport() async throws {
        let fixture = try makePendingHostedReport(label: "ready-restart-turn-off")
        let root = fixture.report.directoryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try fixture.store.recordHostedReadyAndDelete(fixture.report)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))
        XCTAssertEqual(
            try fixture.store.hostedReadyReceiptIDs(for: fixture.report.binding.binding),
            [fixture.report.id]
        )

        // Reconstruct the store to prove the erasure capability is durable,
        // rather than relying on the coordinator's process-local candidate.
        let restoredStore = PendingReportStore(rootDirectory: root)
        XCTAssertEqual(
            try restoredStore.hostedReadyReceiptIDs(for: fixture.report.binding.binding),
            [fixture.report.id]
        )
        HostedDiagnosticsStubProtocol.configureDelete(
            reportID: fixture.report.id,
            statusCode: 204
        )
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: HostedTestCredentialStore(
                credential: HostedDiagnosticsCredential(
                    installationID: "install-ready-restart",
                    installationToken: "ready-restart-token"
                )
            )
        )
        let coordinator = DiagnosticsCoordinator(hostedAPI: api, pendingStore: restoredStore)

        let erased = await coordinator.turnOffAndDelete(binding: fixture.report.binding.binding)

        XCTAssertTrue(erased)
        XCTAssertTrue(try restoredStore.hostedDeletionIntents().isEmpty)
        XCTAssertTrue(try restoredStore.hostedReadyReceiptIDs().isEmpty)
        XCTAssertEqual(HostedDiagnosticsStubProtocol.requests().map(\.method), ["DELETE"])
    }

    func testReadyReceiptHidesEvidenceAcrossInterruptedLocalRemoval() async throws {
        let fixture = try makePendingHostedReport(
            label: "ready-delete-crash",
            hostedDeletionRemover: { _ in throw DiagnosticsStoreError.invalidHostedEnvelope }
        )
        let root = fixture.report.directoryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        XCTAssertThrowsError(try fixture.store.recordHostedReadyAndDelete(fixture.report))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))
        XCTAssertEqual(try fixture.store.hostedReadyReceiptIDs(), [fixture.report.id])
        XCTAssertTrue(fixture.store.listReports(now: Date()).isEmpty)

        // A fresh process with a working filesystem remover finishes the local
        // half before the report can be listed or uploaded again.
        let restoredStore = PendingReportStore(rootDirectory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))
        XCTAssertTrue(restoredStore.listReports(now: Date()).isEmpty)
        XCTAssertEqual(try restoredStore.hostedReadyReceiptIDs(), [fixture.report.id])
    }

    func testHostedDeletionIntentIsNotClearedOrUploadableWhileLocalEvidenceCannotBeRemoved() async throws {
        let fixture = try makePendingHostedReport(
            label: "blocked-local-erasure",
            hostedDeletionRemover: { _ in throw DiagnosticsStoreError.invalidHostedEnvelope }
        )
        let bundle = try DiagnosticsBundleBuilder().build(
            report: fixture.report,
            logLines: [],
            droppedLogLines: 0
        )
        try fixture.store.saveHostedEnvelope(bundle, for: fixture.report)
        let root = fixture.report.directoryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let backup = root.appendingPathComponent("blocked-delete-backup", isDirectory: true)
        try FileManager.default.copyItem(at: fixture.report.directoryURL, to: backup)
        defer { try? FileManager.default.removeItem(at: backup) }

        try fixture.store.stageHostedDeletionAndDelete(fixture.report)
        try FileManager.default.copyItem(at: backup, to: fixture.report.directoryURL)

        let batch = fixture.store.prepareHostedDeletionRetries()
        XCTAssertTrue(batch.reportIDs.isEmpty)
        XCTAssertTrue(batch.hasBlockedLocalEvidence)
        XCTAssertFalse(fixture.store.completeHostedDeletion(reportID: fixture.report.id))
        XCTAssertEqual(try fixture.store.hostedDeletionIntents(), [fixture.report.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))

        HostedDiagnosticsStubProtocol.configureDelete(
            reportID: fixture.report.id,
            statusCode: 204
        )
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: HostedTestCredentialStore(
                credential: HostedDiagnosticsCredential(
                    installationID: "install-blocked-delete",
                    installationToken: "blocked-delete-token"
                )
            )
        )
        let coordinator = DiagnosticsCoordinator(hostedAPI: api, pendingStore: fixture.store)
        let visible = await coordinator.pendingReports(for: fixture.report.binding.binding)
        XCTAssertTrue(visible.isEmpty)
        let uploadDecision = await coordinator.upload(report: fixture.report)
        XCTAssertEqual(uploadDecision, .keptRetryable)
        XCTAssertTrue(HostedDiagnosticsStubProtocol.requests().isEmpty)
    }

    func testMalformedDeletionIntentLedgerQuarantinesSurvivingEvidence() async throws {
        try await assertMalformedHostedErasureLedgerQuarantinesEvidence(.deletionIntents)
    }

    func testMalformedReadyReceiptLedgerQuarantinesSurvivingEvidence() async throws {
        try await assertMalformedHostedErasureLedgerQuarantinesEvidence(.readyReceipts)
    }

    func testHostedErasureLedgersRejectUnreadableNonRegularAndOversizedFiles() throws {
        for kind in HostedErasureLedgerKind.allCases {
            let unreadable = try makePendingHostedReport(label: "unreadable-\(kind.fileName)")
            let unreadableURL = hostedErasureLedgerURL(for: unreadable.report, kind: kind)
            try Data("{}".utf8).write(to: unreadableURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0],
                ofItemAtPath: unreadableURL.path
            )
            assertHostedErasureLedgerLoadFails(
                store: unreadable.store,
                kind: kind,
                expectedError: kind.corruptionError
            )
            XCTAssertTrue(unreadable.store.listReports(now: Date()).isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: unreadable.report.directoryURL.path))

            let nonRegular = try makePendingHostedReport(label: "non-regular-\(kind.fileName)")
            let nonRegularURL = hostedErasureLedgerURL(for: nonRegular.report, kind: kind)
            try FileManager.default.createDirectory(
                at: nonRegularURL,
                withIntermediateDirectories: false
            )
            assertHostedErasureLedgerLoadFails(
                store: nonRegular.store,
                kind: kind,
                expectedError: kind.corruptionError
            )
            XCTAssertTrue(nonRegular.store.listReports(now: Date()).isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: nonRegular.report.directoryURL.path))

            let danglingLink = try makePendingHostedReport(label: "dangling-link-\(kind.fileName)")
            let danglingLinkURL = hostedErasureLedgerURL(for: danglingLink.report, kind: kind)
            try FileManager.default.createSymbolicLink(
                at: danglingLinkURL,
                withDestinationURL: danglingLinkURL.appendingPathExtension("missing")
            )
            assertHostedErasureLedgerLoadFails(
                store: danglingLink.store,
                kind: kind,
                expectedError: kind.corruptionError
            )
            XCTAssertTrue(danglingLink.store.listReports(now: Date()).isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: danglingLink.report.directoryURL.path))

            let oversized = try makePendingHostedReport(label: "oversized-\(kind.fileName)")
            let oversizedURL = hostedErasureLedgerURL(for: oversized.report, kind: kind)
            var oversizedJSON = Data(
                repeating: 0x20,
                count: PendingReportStore.maxHostedErasureLedgerBytes + 1
            )
            oversizedJSON.append(Data("{}".utf8))
            try oversizedJSON.write(to: oversizedURL, options: .atomic)
            assertHostedErasureLedgerLoadFails(
                store: oversized.store,
                kind: kind,
                expectedError: kind.corruptionError
            )
            XCTAssertTrue(oversized.store.listReports(now: Date()).isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: oversized.report.directoryURL.path))
        }
    }

    func testMissingHostedErasureLedgersAreTheOnlyEmptyState() throws {
        let fixture = try makePendingHostedReport(label: "missing-erasure-ledgers")

        XCTAssertTrue(try fixture.store.hostedDeletionIntents().isEmpty)
        XCTAssertTrue(try fixture.store.hostedReadyReceiptIDs().isEmpty)
        XCTAssertEqual(fixture.store.listReports(now: Date()).map(\.id), [fixture.report.id])

        for kind in HostedErasureLedgerKind.allCases {
            let existingEmpty = try makePendingHostedReport(label: "empty-\(kind.fileName)")
            let ledgerURL = hostedErasureLedgerURL(for: existingEmpty.report, kind: kind)
            try Data("{}".utf8).write(to: ledgerURL, options: .atomic)
            assertHostedErasureLedgerLoadFails(
                store: existingEmpty.store,
                kind: kind,
                expectedError: kind.corruptionError
            )
            XCTAssertTrue(existingEmpty.store.listReports(now: Date()).isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: existingEmpty.report.directoryURL.path))
        }
    }

    func testNoncanonicalLedgerKeysQuarantineEvidenceAfterRemovalFailure() async throws {
        let reportID = try XCTUnwrap(
            UUID(uuidString: "abcdef12-3456-4789-abcd-ef1234567890")
        )
        for kind in HostedErasureLedgerKind.allCases {
            var removalAttempts = 0
            let fixture = try makePendingHostedReport(
                label: "noncanonical-\(kind.fileName)",
                reportID: reportID,
                hostedDeletionRemover: { _ in
                    removalAttempts += 1
                    throw DiagnosticsStoreError.invalidHostedEnvelope
                }
            )
            let ledgerURL = hostedErasureLedgerURL(for: fixture.report, kind: kind)
            switch kind {
            case .deletionIntents:
                let canonicalLedger = [
                    reportID.uuidString.lowercased(): DiagnosticsTimestamp.string(from: Date()),
                ]
                let data = try DiagnosticsJSONCoding.makeEncoder().encode(canonicalLedger)
                try data.write(to: ledgerURL, options: .atomic)
                let retryBatch = fixture.store.prepareHostedDeletionRetries()
                XCTAssertTrue(retryBatch.reportIDs.isEmpty)
                XCTAssertTrue(retryBatch.hasBlockedLocalEvidence)
            case .readyReceipts:
                XCTAssertThrowsError(try fixture.store.recordHostedReadyAndDelete(fixture.report))
            }
            XCTAssertEqual(removalAttempts, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))

            let canonicalData = try Data(contentsOf: ledgerURL)
            var ledger = try XCTUnwrap(
                JSONSerialization.jsonObject(with: canonicalData) as? [String: Any]
            )
            let canonicalKey = reportID.uuidString.lowercased()
            let noncanonicalKey = reportID.uuidString.uppercased()
            XCTAssertNotEqual(canonicalKey, noncanonicalKey)
            let value = try XCTUnwrap(ledger.removeValue(forKey: canonicalKey))
            ledger[noncanonicalKey] = value
            let noncanonicalData = try JSONSerialization.data(
                withJSONObject: ledger,
                options: [.sortedKeys]
            )
            try noncanonicalData.write(to: ledgerURL, options: .atomic)

            let restoredStore = PendingReportStore(
                rootDirectory: fixture.report.directoryURL
                    .deletingLastPathComponent()
                    .deletingLastPathComponent(),
                hostedDeletionRemover: { _ in
                    removalAttempts += 1
                    throw DiagnosticsStoreError.invalidHostedEnvelope
                }
            )
            XCTAssertEqual(removalAttempts, 1, "corrupt state must not attempt destructive recovery")
            assertHostedErasureLedgerLoadFails(
                store: restoredStore,
                kind: kind,
                expectedError: kind.corruptionError
            )
            XCTAssertTrue(restoredStore.listReports(now: Date()).isEmpty)
            XCTAssertNil(restoredStore.report(id: reportID))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))
            guard case .quarantined = restoredStore.loadHostedEnvelope(for: fixture.report) else {
                return XCTFail("A noncanonical \(kind.fileName) key must quarantine evidence")
            }

            let retryBatch = restoredStore.prepareHostedDeletionRetries()
            XCTAssertTrue(retryBatch.reportIDs.isEmpty)
            XCTAssertTrue(retryBatch.hasBlockedLocalEvidence)
            XCTAssertTrue(retryBatch.hasCorruptLedger)
            let coordinator = DiagnosticsCoordinator(
                hostedAPI: try makeHostedUploadAPI(),
                pendingStore: restoredStore
            )
            let uploadDecision = await coordinator.upload(report: fixture.report)
            let drained = await coordinator.retryHostedDeletions()
            let turnedOff = await coordinator.turnOffAndDelete(
                binding: fixture.report.binding.binding
            )
            XCTAssertEqual(uploadDecision, .keptRetryable)
            XCTAssertFalse(drained)
            XCTAssertFalse(turnedOff)
            XCTAssertTrue(HostedDiagnosticsStubProtocol.requests().isEmpty)
            XCTAssertEqual(try Data(contentsOf: ledgerURL), noncanonicalData)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))
        }
    }

    func testCorruptHostedLedgerDoesNotGovernSelfHostedLifecycle() async throws {
        try await withTemporaryActiveSelfHostedServer { serverRegistryID in
            for kind in HostedErasureLedgerKind.allCases {
                let fixture = try makePendingSelfHostedReports(
                    label: "self-hosted-\(kind.fileName)",
                    count: 3
                )
                let ledgerURL = hostedErasureLedgerURL(for: fixture.reports[0], kind: kind)
                let corruptBytes = Data(#"{"truncated": "hosted ledger""#.utf8)
                try corruptBytes.write(to: ledgerURL, options: .atomic)
                let restoredStore = PendingReportStore(rootDirectory: fixture.root)
                let coordinator = try await makeSelfHostedCoordinator(
                    pendingStore: restoredStore,
                    serverRegistryID: serverRegistryID
                )

                let listed = await coordinator.pendingReports(for: fixture.binding)
                XCTAssertEqual(listed.map(\.id), fixture.reports.map(\.id))

                SelfHostedDiagnosticsStubProtocol.configure(
                    serverInstanceID: fixture.binding.serverInstanceID,
                    reportID: fixture.reports[0].id
                )
                let uploadDecision = await coordinator.upload(report: fixture.reports[0])
                XCTAssertEqual(
                    uploadDecision,
                    .uploaded(DiagnosticsUploadResponse(
                        reportId: fixture.reports[0].id.uuidString.lowercased(),
                        shortId: "SILO-SELFHOSTED",
                        state: .ready
                    ))
                )
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: fixture.reports[0].directoryURL.path
                ))
                XCTAssertEqual(SelfHostedDiagnosticsStubProtocol.requestedPaths(), [
                    "/api/v1/diagnostics/status",
                    "/api/v1/auth/me",
                    "/api/v1/diagnostics/reports",
                ])

                let deleted = await coordinator.delete(report: fixture.reports[1])
                XCTAssertTrue(deleted)
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: fixture.reports[1].directoryURL.path
                ))

                let turnedOff = await coordinator.turnOffAndDelete(binding: fixture.binding)
                XCTAssertTrue(turnedOff)
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: fixture.reports[2].directoryURL.path
                ))
                let remaining = await coordinator.pendingReports(for: fixture.binding)
                XCTAssertTrue(remaining.isEmpty)
                XCTAssertEqual(try Data(contentsOf: ledgerURL), corruptBytes)
                XCTAssertTrue(HostedDiagnosticsStubProtocol.requests().isEmpty)
            }
        }
    }

    func testHostedCapacityEvictionStagesRemoteDeletionBeforeRemovingEvidence() throws {
        let fixture = try makePendingHostedReport(label: "capacity-erasure")
        fixture.store.markHostedProcessing(fixture.report, shortID: "SILO-CAPACITY")
        let capturedAt = fixture.report.binding.capturedAtDate

        for index in 1...3 {
            _ = try saveAdditionalHostedReport(
                in: fixture.store,
                binding: fixture.report.binding.binding,
                label: "capacity-erasure-\(index)",
                capturedAt: capturedAt.addingTimeInterval(TimeInterval(index))
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))
        XCTAssertEqual(try fixture.store.hostedDeletionIntents(), [fixture.report.id])
    }

    func testHostedExpiryStagesRemoteDeletionBeforeRemovingEvidence() throws {
        let fixture = try makePendingHostedReport(label: "expiry-erasure")
        fixture.store.markHostedProcessing(fixture.report, shortID: "SILO-EXPIRY")
        let afterExpiry = fixture.report.binding.capturedAtDate
            .addingTimeInterval(PendingReportStore.expiryInterval + 1)

        let reports = fixture.store.listReports(
            for: fixture.report.binding.binding,
            now: afterExpiry
        )

        XCTAssertTrue(reports.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))
        XCTAssertEqual(try fixture.store.hostedDeletionIntents(), [fixture.report.id])
    }

    func testBackgroundReadyPollRecordsSentHistory() async throws {
        let fixture = try makePendingHostedReport(label: "ready-history")
        let shortID = "SILO-HISTORY"
        fixture.store.markHostedProcessing(fixture.report, shortID: shortID)
        HostedDiagnosticsStubProtocol.configureReportStatus(
            reportID: fixture.report.id,
            shortID: shortID,
            state: .ready,
            errorCode: nil
        )
        let suiteName = "HostedDiagnosticsAPITests.history.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        let consentStore = DiagnosticsConsentStore(
            defaults: SharedDefaults(suite: suite, standard: suite),
            onNeverSelected: { _ in }
        )
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: HostedTestCredentialStore(
                credential: HostedDiagnosticsCredential(
                    installationID: "install-ready-history",
                    installationToken: "ready-history-token"
                )
            )
        )
        let coordinator = DiagnosticsCoordinator(
            hostedAPI: api,
            consentStore: consentStore,
            pendingStore: fixture.store
        )

        let pending = await coordinator.pendingReports(for: fixture.report.binding.binding)

        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(
            consentStore.sentHistory(for: fixture.report.binding.binding).map(\.shortID),
            [shortID]
        )
    }

    func testBackgroundReadyRemainsUploadedWhenLocalRemovalFails() async throws {
        let fixture = try makePendingHostedReport(
            label: "ready-local-removal-failure",
            hostedDeletionRemover: { _ in
                throw DiagnosticsStoreError.invalidHostedEnvelope
            }
        )
        let shortID = "SILO-READY-LOCAL-FAILURE"
        fixture.store.markHostedProcessing(fixture.report, shortID: shortID)
        HostedDiagnosticsStubProtocol.configureReportStatus(
            reportID: fixture.report.id,
            shortID: shortID,
            state: .ready,
            errorCode: nil
        )
        let suiteName = "HostedDiagnosticsAPITests.ready.failure.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        let consentStore = DiagnosticsConsentStore(
            defaults: SharedDefaults(suite: suite, standard: suite),
            onNeverSelected: { _ in }
        )
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: HostedTestCredentialStore(
                credential: HostedDiagnosticsCredential(
                    installationID: "install-ready-local-failure",
                    installationToken: "ready-local-failure-token"
                )
            )
        )
        let coordinator = DiagnosticsCoordinator(
            hostedAPI: api,
            consentStore: consentStore,
            pendingStore: fixture.store
        )

        let pending = await coordinator.pendingReports(for: fixture.report.binding.binding)

        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(
            consentStore.sentHistory(for: fixture.report.binding.binding).map(\.shortID),
            [shortID]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))
        XCTAssertEqual(try fixture.store.hostedReadyReceiptIDs(), [fixture.report.id])
    }

    func testHostedProcessingStateIsAwaitingStatusInsteadOfAnotherPrompt() throws {
        let fixture = try makePendingHostedReport(label: "processing-prompt")
        fixture.store.markHostedProcessing(fixture.report, shortID: "SILO-PROCESSING")

        let report = try XCTUnwrap(fixture.store.report(id: fixture.report.id))

        XCTAssertTrue(report.state.isAwaitingHostedStatus)
        XCTAssertFalse(report.state.isPermanentFailure)
    }

    func testHostedRemoteLifecycleKeepsEvidenceUntilReportIsReady() async throws {
        for state in [DiagnosticsRemoteReportState.processing, .rejected, .ready] {
            let fixture = try makePendingHostedReport(label: "remote-\(state.rawValue)")
            let shortID = "SILO-\(state.rawValue.uppercased())"
            fixture.store.markHostedProcessing(fixture.report, shortID: shortID)
            HostedDiagnosticsStubProtocol.configureReportStatus(
                reportID: fixture.report.id,
                shortID: shortID,
                state: state,
                errorCode: state == .rejected ? "privacy_artifact_rejected" : nil
            )
            let api = HostedDiagnosticsAPI(
                baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
                session: makeSession(),
                credentialStore: HostedTestCredentialStore(
                    credential: HostedDiagnosticsCredential(
                        installationID: "install-lifecycle-test",
                        installationToken: "lifecycle-test-token"
                    )
                )
            )
            let coordinator = DiagnosticsCoordinator(hostedAPI: api, pendingStore: fixture.store)

            let pending = await coordinator.pendingReports(for: fixture.report.binding.binding)

            if state == .ready {
                XCTAssertTrue(pending.isEmpty)
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))
                XCTAssertEqual(try fixture.store.hostedReadyReceiptIDs(), [fixture.report.id])
            } else {
                let persisted = try XCTUnwrap(pending.first)
                XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))
                if state == .processing {
                    XCTAssertEqual(persisted.state.hostedRemoteShortID, shortID)
                    XCTAssertNil(persisted.state.hostedRejectionCode)
                } else {
                    XCTAssertNil(persisted.state.hostedRemoteShortID)
                    XCTAssertEqual(persisted.state.hostedRejectionCode, "privacy_artifact_rejected")
                }
            }
        }
    }

    func testHostedPermanentValidationFailureKeepsEvidenceForReview() async throws {
        let fixture = try makePendingHostedReport(label: "permanent-hosted-rejection")
        let coordinator = DiagnosticsCoordinator(pendingStore: fixture.store)

        let decision = await coordinator.handleHostedUploadError(
            .http(statusCode: 422, code: "privacy_artifact_rejected"),
            report: fixture.report
        )

        XCTAssertEqual(decision, .keptRejected(code: "privacy_artifact_rejected"))
        let persisted = try XCTUnwrap(
            fixture.store.listReports(for: fixture.report.binding.binding, now: Date()).first
        )
        XCTAssertEqual(persisted.state.hostedRejectionCode, "privacy_artifact_rejected")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))
    }

    func testCapabilitiesArePublicAndMapCollectorIdentity() async throws {
        HostedDiagnosticsStubProtocol.configureCapabilities()
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: HostedTestCredentialStore(credential: nil)
        )

        let capabilities = try await api.capabilities()

        XCTAssertEqual(capabilities.collectorId, HostedDiagnosticsCapabilities.pinnedCollectorID)
        XCTAssertEqual(
            capabilities.statusResponse.serverInstanceID,
            HostedDiagnosticsCapabilities.pinnedCollectorID
        )
        XCTAssertEqual(capabilities.acceptedSchemaVersions, [1])
        let request = try XCTUnwrap(HostedDiagnosticsStubProtocol.requests().first)
        XCTAssertNil(request.authorization, "capability discovery must be anonymous")
        XCTAssertNil(request.cookieHeader)
        XCTAssertNil(request.profileHeader)
        XCTAssertNil(request.profileTokenHeader)
        XCTAssertNil(request.siloDeviceIDHeader)
    }

    func testCapabilitiesRejectUnexpectedCollectorIdentityBeforeSend() async throws {
        HostedDiagnosticsStubProtocol.configureCapabilities(
            collectorID: "unexpected-collector"
        )
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: HostedTestCredentialStore(credential: nil)
        )

        do {
            _ = try await api.capabilities()
            XCTFail("Unexpected collector identity must fail closed")
        } catch let error as HostedDiagnosticsAPIError {
            XCTAssertEqual(error, .collectorIdentityMismatch)
        }
    }

    func testCapabilitiesRejectCollectorWithoutSchemaV1BeforeSend() async throws {
        HostedDiagnosticsStubProtocol.configureCapabilities(acceptedSchemaVersions: [2])
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: HostedTestCredentialStore(credential: nil)
        )

        do {
            _ = try await api.capabilities()
            XCTFail("A collector that cannot accept schema v1 must fail closed")
        } catch let error as HostedDiagnosticsAPIError {
            XCTAssertEqual(error, .collectorIdentityMismatch)
        }
    }

    func testCapabilitiesPreserveValidDisabledAndStorageUnavailableStatuses() async throws {
        for status in [DiagnosticsAvailabilityStatus.disabled, .storageUnavailable] {
            HostedDiagnosticsStubProtocol.configureCapabilities(status: status)
            let api = HostedDiagnosticsAPI(
                baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
                session: makeSession(),
                credentialStore: HostedTestCredentialStore(credential: nil)
            )

            let capabilities = try await api.capabilities()

            XCTAssertEqual(capabilities.status, status)
            XCTAssertFalse(DiagnosticsCoordinator.canBeginUpload(status: capabilities.status))
        }
        XCTAssertTrue(DiagnosticsCoordinator.canBeginUpload(status: .available))
    }

    func testHostedCredentialGateRejectsSameServerAccountReplacementButAllowsTokenRefresh() {
        let serverID = "same-server"
        let generation = UUID()
        let captured = RefreshAccountIdentity(
            serverId: serverID,
            serverURL: "https://silo.example",
            credentialGenerationID: generation
        )

        // Ordinary access-token rotation does not replace the credential
        // owner, so TokenStore preserves this identity and an in-flight hosted
        // upload may continue.
        XCTAssertTrue(DiagnosticsCoordinator.hostedCredentialIdentityMatches(
            expected: captured,
            current: captured,
            serverRegistryID: serverID
        ))

        // A complete A -> B login on the same server changes only the owner
        // generation. That must invalidate both an in-flight /currentUser
        // response and a bundle waiting to POST.
        let replacement = RefreshAccountIdentity(
            serverId: serverID,
            serverURL: captured.serverURL,
            credentialGenerationID: UUID()
        )
        XCTAssertFalse(DiagnosticsCoordinator.hostedCredentialIdentityMatches(
            expected: captured,
            current: replacement,
            serverRegistryID: serverID
        ))
        XCTAssertFalse(DiagnosticsCoordinator.hostedCredentialIdentityMatches(
            expected: captured,
            current: nil,
            serverRegistryID: serverID
        ))
        XCTAssertFalse(DiagnosticsCoordinator.hostedCredentialIdentityMatches(
            expected: captured,
            current: captured,
            serverRegistryID: "different-server"
        ))
    }

    func testOfflinePersistentCaptureUsesPinnedConservativeV1Contract() throws {
        let snapshot = DiagnosticsCoordinator.hostedPersistentCaptureFallbackSnapshot(
            serverRegistryID: "local-server-registry-id",
            accountUserID: "local-account-id",
            previous: nil
        )
        let status = snapshot.status
        let context = DiagnosticsCaptureContext(
            binding: snapshot.binding,
            profileID: "profile-must-not-escape",
            consentMode: .prompt,
            noticeVersion: status.consentNoticeVersion,
            appVersion: "1.0",
            appBuild: "7",
            platform: .ios,
            osVersion: "26.0",
            destinationServerInstanceID: status.serverInstanceID
        )

        let draft = context.makeManifestDraft(
            type: .nativeCrash,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            crash: nil,
            deviceSummary: DiagnosticsManifest.DeviceSummary(
                manufacturer: "Apple",
                model: "iPhone",
                os: "26.0",
                formFactor: "phone"
            ),
            playbackSessionIDs: ["private-playback-session"]
        )

        XCTAssertTrue(DiagnosticsCoordinator.isTransientCaptureFallbackFailure(
            HostedDiagnosticsAPIError.underlying("collector offline")
        ))
        XCTAssertEqual(status.acceptedSchemaVersions, [1])
        XCTAssertEqual(status.maxBundleBytes, 10 * 1024 * 1024)
        XCTAssertEqual(status.maxManifestBytes, 64 * 1024)
        XCTAssertEqual(status.consentNoticeVersion, 1)
        XCTAssertEqual(draft.destination.serverInstanceID, HostedDiagnosticsCapabilities.pinnedCollectorID)
        XCTAssertEqual(draft.consent.mode, .prompt)
        XCTAssertNil(draft.report.profileID)
        XCTAssertEqual(draft.playbackSessionIds, [])
    }

    func testHostedEnvelopeHonorsBothAdvertisedSizeLimits() {
        XCTAssertTrue(DiagnosticsCoordinator.hostedEnvelopeFitsAdvertisedLimits(
            bundleBytes: 1_000,
            manifestBytes: 500,
            maximumBundleBytes: 1_000,
            maximumManifestBytes: 500
        ))
        XCTAssertFalse(DiagnosticsCoordinator.hostedEnvelopeFitsAdvertisedLimits(
            bundleBytes: 1_000,
            manifestBytes: 501,
            maximumBundleBytes: 1_000,
            maximumManifestBytes: 500
        ))
        XCTAssertFalse(DiagnosticsCoordinator.hostedEnvelopeFitsAdvertisedLimits(
            bundleBytes: 1_001,
            manifestBytes: 500,
            maximumBundleBytes: 1_000,
            maximumManifestBytes: 500
        ))
    }

    func testCollectorHTTPErrorDispositionDoesNotRetryPermanentValidationFailures() {
        let permanentCodes = [
            "invalid_request",
            "unexpected_field",
            "invalid_report_id",
            "invalid_bundle_size",
            "invalid_bundle_sha256",
            "invalid_manifest",
            "privacy_field_rejected",
            "privacy_value_rejected",
            "wrong_destination",
            "archive_metadata_mismatch",
            "report_conflict",
            "unsupported_media_type",
            "size_mismatch",
            "sensitive_header_rejected",
            "content_length_required",
            "invalid_content_length",
            "invalid_json",
            "invalid_platform",
            "hosted_consent_required",
            "privacy_artifact_rejected",
            "upload_attempt_limit_exceeded",
        ]
        for code in permanentCodes {
            XCTAssertEqual(
                DiagnosticsCoordinator.hostedHTTPFailureDisposition(
                    statusCode: 400,
                    code: code
                ),
                .invalidLocalBundle,
                code
            )
        }
        XCTAssertEqual(
            DiagnosticsCoordinator.hostedHTTPFailureDisposition(
                statusCode: 413,
                code: "bundle_too_large"
            ),
            .tooLarge
        )
        XCTAssertEqual(
            DiagnosticsCoordinator.hostedHTTPFailureDisposition(
                statusCode: 400,
                code: "compression_ratio_exceeded"
            ),
            .tooLarge
        )
        XCTAssertEqual(
            DiagnosticsCoordinator.hostedHTTPFailureDisposition(
                statusCode: 400,
                code: "stale_consent"
            ),
            .staleConsent
        )
        XCTAssertEqual(
            DiagnosticsCoordinator.hostedHTTPFailureDisposition(
                statusCode: 429,
                code: "invalid_request"
            ),
            .retryable
        )
        XCTAssertEqual(
            DiagnosticsCoordinator.hostedHTTPFailureDisposition(
                statusCode: 503,
                code: "invalid_manifest"
            ),
            .retryable
        )
        XCTAssertEqual(
            DiagnosticsCoordinator.hostedHTTPFailureDisposition(
                statusCode: 401,
                code: "invalid_installation_token"
            ),
            .retryable
        )
    }

    private func makeDeviceSnapshot(capturedAt: Date) -> DeviceSnapshotPayload {
        DeviceSnapshotPayload(
            capturedAt: DiagnosticsTimestamp.string(from: capturedAt),
            provenance: .preFailure,
            identity: .object([
                "manufacturer": .string("Apple"),
                "model": .string("iPhone"),
                "device": .string("Unit Test"),
                "form_factor": .string("phone"),
            ]),
            display: .object(["mode": .string("not_collected")]),
            audio: .object([
                "outputs": .array([
                    .object([
                        "type": .string("HDMI"),
                        "uid_hash": .string("stable-route-fingerprint"),
                    ]),
                ]),
                "route_hashes": .array([.string("legacy-stable-route-fingerprint")]),
                "passthrough": .string("unknown"),
            ]),
            videoCodecs: .string("not_collected"),
            network: .object([
                "transport": .string("not_collected"),
                "host": .string("127.0.0.1"),
                "server_url": .string("http://127.0.0.1:49152/items/42"),
            ])
        )
    }

    private enum HostedErasureLedgerKind: CaseIterable {
        case deletionIntents
        case readyReceipts

        var fileName: String {
            switch self {
            case .deletionIntents:
                return "hosted-deletion-intents.json"
            case .readyReceipts:
                return "hosted-ready-receipts.json"
            }
        }

        var corruptionError: DiagnosticsStoreError {
            switch self {
            case .deletionIntents:
                return .corruptHostedDeletionIntents
            case .readyReceipts:
                return .corruptHostedReadyReceipts
            }
        }
    }

    private func assertMalformedHostedErasureLedgerQuarantinesEvidence(
        _ kind: HostedErasureLedgerKind
    ) async throws {
        let fixture = try makePendingHostedReport(label: "corrupt-\(kind.fileName)")
        fixture.store.markHostedProcessing(fixture.report, shortID: "SILO-QUARANTINED")
        let processingReport = try XCTUnwrap(
            fixture.store.listReports(now: Date()).first(where: { $0.id == fixture.report.id })
        )
        let ledgerURL = hostedErasureLedgerURL(for: fixture.report, kind: kind)
        let corruptBytes = Data(#"{"truncated": "ledger""#.utf8)
        try corruptBytes.write(to: ledgerURL, options: .atomic)
        let restoredStore = PendingReportStore(
            rootDirectory: fixture.report.directoryURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        )

        assertHostedErasureLedgerLoadFails(
            store: restoredStore,
            kind: kind,
            expectedError: kind.corruptionError
        )
        guard case .quarantined = restoredStore.loadHostedEnvelope(for: processingReport) else {
            return XCTFail("A corrupt \(kind.fileName) must quarantine hosted envelope loading")
        }
        XCTAssertTrue(restoredStore.listReports(now: Date()).isEmpty)
        XCTAssertNil(restoredStore.report(id: fixture.report.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))

        HostedDiagnosticsStubProtocol.configureReportStatus(
            reportID: fixture.report.id,
            shortID: "SILO-QUARANTINED",
            state: .ready,
            errorCode: nil
        )
        let api = HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: HostedTestCredentialStore(
                credential: HostedDiagnosticsCredential(
                    installationID: "install-corrupt-ledger",
                    installationToken: "corrupt-ledger-token"
                )
            )
        )
        let coordinator = DiagnosticsCoordinator(hostedAPI: api, pendingStore: restoredStore)

        let uploadDecision = await coordinator.upload(report: processingReport)
        XCTAssertEqual(uploadDecision, .keptRetryable)
        XCTAssertTrue(HostedDiagnosticsStubProtocol.requests().isEmpty)

        let retryBatch = restoredStore.prepareHostedDeletionRetries()
        XCTAssertTrue(retryBatch.reportIDs.isEmpty)
        XCTAssertTrue(retryBatch.hasBlockedLocalEvidence)
        XCTAssertTrue(retryBatch.hasCorruptLedger)
        let drained = await coordinator.retryHostedDeletions()
        XCTAssertFalse(drained)
        XCTAssertTrue(HostedDiagnosticsStubProtocol.requests().isEmpty)

        let turnedOff = await coordinator.turnOffAndDelete(
            binding: fixture.report.binding.binding
        )
        XCTAssertFalse(turnedOff)
        XCTAssertEqual(try Data(contentsOf: ledgerURL), corruptBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.report.directoryURL.path))
        XCTAssertTrue(restoredStore.listReports(now: Date()).isEmpty)
        XCTAssertTrue(HostedDiagnosticsStubProtocol.requests().isEmpty)
    }

    private func assertHostedErasureLedgerLoadFails(
        store: PendingReportStore,
        kind: HostedErasureLedgerKind,
        expectedError: DiagnosticsStoreError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            switch kind {
            case .deletionIntents:
                _ = try store.hostedDeletionIntents()
            case .readyReceipts:
                _ = try store.hostedReadyReceiptIDs()
            }
            XCTFail("Expected \(kind.fileName) load to fail closed", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? DiagnosticsStoreError, expectedError, file: file, line: line)
        }
    }

    private func hostedErasureLedgerURL(
        for report: PendingReport,
        kind: HostedErasureLedgerKind
    ) -> URL {
        report.directoryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(kind.fileName)
    }

    private func makePendingHostedReport(
        label: String,
        reportID: UUID = UUID(),
        hostedDeletionRemover: ((URL) throws -> Void)? = nil
    ) throws -> (store: PendingReportStore, report: PendingReport) {
        let capturedAt = Date()
        let binding = DiagnosticsBinding.hosted(
            serverRegistryID: "collector-acknowledgement-test-server",
            accountUserID: "collector-acknowledgement-test-account"
        )
        let context = DiagnosticsCaptureContext(
            binding: binding,
            profileID: nil,
            consentMode: .manual,
            noticeVersion: 1,
            appVersion: "1.0",
            appBuild: "7",
            platform: .ios,
            osVersion: "26.0",
            destinationServerInstanceID: HostedDiagnosticsCapabilities.pinnedCollectorID
        )
        let manifest = context.makeManifestDraft(
            type: .manual,
            capturedAt: capturedAt,
            crash: nil,
            deviceSummary: DiagnosticsManifest.DeviceSummary(
                manufacturer: "Apple",
                model: "iPhone",
                os: "26.0",
                formFactor: "phone"
            ),
            playbackSessionIDs: [],
            consentMode: .manual
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HostedAcknowledgement-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = PendingReportStore(
            rootDirectory: root,
            hostedDeletionRemover: hostedDeletionRemover
        )
        let report = try store.save(PendingReportCapture(
            id: reportID,
            binding: binding,
            profileID: nil,
            type: .manual,
            fingerprint: label,
            capturedAt: capturedAt,
            manifest: manifest,
            deviceSnapshot: makeDeviceSnapshot(capturedAt: capturedAt),
            artifacts: [
                PendingReportArtifact(
                    relativePath: "logs.jsonl",
                    data: Data("local evidence must survive".utf8)
                ),
            ]
        ))
        return (store, report)
    }

    private func saveAdditionalHostedReport(
        in store: PendingReportStore,
        binding: DiagnosticsBinding,
        label: String,
        capturedAt: Date
    ) throws -> PendingReport {
        let context = DiagnosticsCaptureContext(
            binding: binding,
            profileID: nil,
            consentMode: .manual,
            noticeVersion: 1,
            appVersion: "1.0",
            appBuild: "7",
            platform: .ios,
            osVersion: "26.0",
            destinationServerInstanceID: HostedDiagnosticsCapabilities.pinnedCollectorID
        )
        let manifest = context.makeManifestDraft(
            type: .manual,
            capturedAt: capturedAt,
            crash: nil,
            deviceSummary: DiagnosticsManifest.DeviceSummary(
                manufacturer: "Apple",
                model: "iPhone",
                os: "26.0",
                formFactor: "phone"
            ),
            playbackSessionIDs: [],
            consentMode: .manual
        )
        return try store.save(PendingReportCapture(
            binding: binding,
            profileID: nil,
            type: .manual,
            fingerprint: label,
            capturedAt: capturedAt,
            manifest: manifest,
            deviceSnapshot: makeDeviceSnapshot(capturedAt: capturedAt),
            artifacts: [
                PendingReportArtifact(
                    relativePath: "logs.jsonl",
                    data: Data("additional hosted evidence".utf8)
                ),
            ]
        ))
    }

    private func makePendingSelfHostedReports(
        label: String,
        count: Int
    ) throws -> (
        root: URL,
        store: PendingReportStore,
        binding: DiagnosticsBinding,
        reports: [PendingReport]
    ) {
        let binding = DiagnosticsBinding(
            serverInstanceID: "self-hosted-diagnostics-instance",
            accountUserID: "42"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SelfHostedLedgerIsolation-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = PendingReportStore(rootDirectory: root)
        let reports = try (0..<count).map { index in
            let capturedAt = Date().addingTimeInterval(TimeInterval(index))
            let context = DiagnosticsCaptureContext(
                binding: binding,
                profileID: nil,
                consentMode: .manual,
                noticeVersion: 1,
                appVersion: "1.0",
                appBuild: "7",
                platform: .ios,
                osVersion: "26.0",
                destinationServerInstanceID: binding.serverInstanceID
            )
            return try store.save(PendingReportCapture(
                binding: binding,
                profileID: nil,
                type: .manual,
                fingerprint: "\(label)-\(index)",
                capturedAt: capturedAt,
                manifest: context.makeManifestDraft(
                    type: .manual,
                    capturedAt: capturedAt,
                    crash: nil,
                    deviceSummary: DiagnosticsManifest.DeviceSummary(
                        manufacturer: "Apple",
                        model: "iPhone",
                        os: "26.0",
                        formFactor: "phone"
                    ),
                    playbackSessionIDs: [],
                    consentMode: .manual
                ),
                deviceSnapshot: makeDeviceSnapshot(capturedAt: capturedAt),
                artifacts: [
                    PendingReportArtifact(relativePath: "logs.jsonl", data: Data()),
                ]
            ))
        }
        return (root, store, binding, reports)
    }

    private func makeSelfHostedCoordinator(
        pendingStore: PendingReportStore,
        serverRegistryID: String
    ) async throws -> DiagnosticsCoordinator {
        let suiteName = "HostedDiagnosticsAPITests.selfHosted.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        let tokenStore = TokenStore(
            keychain: SharedKeychain(service: suiteName, accessGroup: nil),
            defaults: defaults
        )
        await tokenStore.switchActiveServer(serverId: serverRegistryID)
        await tokenStore.setServerUrl("https://selfhost.test")
        await tokenStore.saveTokens(
            accessToken: "self-hosted-access-token",
            refreshToken: "self-hosted-refresh-token"
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SelfHostedDiagnosticsStubProtocol.self]
        let http = HTTPClient(
            session: URLSession(configuration: configuration),
            tokenStore: tokenStore
        )
        let destinationStore = DiagnosticsDestinationStore(defaults: defaults)
        destinationStore.select(.selfHosted)
        return DiagnosticsCoordinator(
            api: DiagnosticsAPI(http: http),
            hostedAPI: try makeHostedUploadAPI(),
            continuumAPI: ContinuumAPI(http: http, tokenStore: tokenStore),
            consentStore: DiagnosticsConsentStore(defaults: defaults),
            destinationStore: destinationStore,
            pendingStore: pendingStore
        )
    }

    private func withTemporaryActiveSelfHostedServer<T>(
        _ operation: (String) async throws -> T
    ) async throws -> T {
        let registry = ServerRegistry.shared
        let previousActiveServerID = registry.activeServerId
        let serverURL = "https://selfhost.test/\(UUID().uuidString.lowercased())"
        let serverRegistryID = ServerRegistry.serverId(for: serverURL)
        registry.addOrUpdate(ServerEntry(
            id: serverRegistryID,
            url: serverURL,
            fetchedName: "Self-hosted diagnostics test",
            profileId: nil,
            lastUsedAt: Date()
        ))
        await registry.switchTo(serverId: serverRegistryID)
        await TokenStore.shared.saveTokens(
            accessToken: "global-self-hosted-access-token",
            refreshToken: "global-self-hosted-refresh-token"
        )
        await TokenStore.shared.setProfileId(nil)

        func cleanUp() async {
            if let previousActiveServerID,
               registry.entry(with: previousActiveServerID) != nil {
                await registry.switchTo(serverId: previousActiveServerID)
            }
            await registry.remove(serverId: serverRegistryID)
        }

        do {
            let result = try await operation(serverRegistryID)
            await cleanUp()
            return result
        } catch {
            await cleanUp()
            throw error
        }
    }

    private func makeHostedUploadAPI() throws -> HostedDiagnosticsAPI {
        HostedDiagnosticsAPI(
            baseURL: try XCTUnwrap(URL(string: "https://collector.example")),
            session: makeSession(),
            credentialStore: HostedTestCredentialStore(
                credential: HostedDiagnosticsCredential(
                    installationID: "install-acknowledgement-test",
                    installationToken: "acknowledgement-test-token"
                )
            )
        )
    }

    private func captureHostedUploadError(
        reportID: UUID,
        bundle: Data
    ) async -> HostedDiagnosticsAPIError {
        do {
            _ = try await makeHostedUploadAPI().upload(
                reportID: reportID,
                manifest: makeManifest(),
                bundleData: bundle
            )
            XCTFail("Expected hosted PUT acknowledgement to be rejected")
            return .underlying("unexpected test success")
        } catch let error as HostedDiagnosticsAPIError {
            return error
        } catch {
            XCTFail("Unexpected error type: \(error)")
            return .underlying(String(describing: error))
        }
    }

    private func assertRetryRetains(
        _ error: HostedDiagnosticsAPIError,
        fixture: (store: PendingReportStore, report: PendingReport),
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let coordinator = DiagnosticsCoordinator(pendingStore: fixture.store)
        let decision = await coordinator.handleHostedUploadError(error, report: fixture.report)
        XCTAssertEqual(decision, .keptRetryable, message, file: file, line: line)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.report.directoryURL.path),
            message,
            file: file,
            line: line
        )
    }

    private func decodeLogLines(_ data: Data) -> [DiagnosticsLogLine] {
        let decoder = DiagnosticsJSONCoding.makeDecoder()
        return data
            .split(separator: 10, omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(DiagnosticsLogLine.self, from: Data($0)) }
    }

    private func assertPassesCanonicalHostedV1Registry(
        _ line: DiagnosticsLogLine,
        file: StaticString = #filePath,
        line sourceLine: UInt = #line
    ) {
        let stringAttributes: [DiagnosticsLogCategory: Set<String>] = [
            .playback: ["sink", "fmt", "decoder", "hdr_mode"],
            .focus: ["target", "action"],
            .network: ["method", "path"],
            .lifecycle: ["state"],
            .crash: ["fingerprint", "source"],
        ]
        let integerAttributes: [DiagnosticsLogCategory: Set<String>] = [
            .playback: [
                "width", "height", "bitrate_kbps", "dropped_frames", "audio_underruns",
            ],
            .network: ["status", "duration_ms"],
        ]
        for (key, value) in line.attrs ?? [:] {
            if stringAttributes[line.cat]?.contains(key) == true {
                guard case .string = value else {
                    XCTFail("\(line.cat.rawValue).\(key) must be a string", file: file, line: sourceLine)
                    continue
                }
            } else if integerAttributes[line.cat]?.contains(key) == true {
                guard case .int = value else {
                    XCTFail("\(line.cat.rawValue).\(key) must be an integer", file: file, line: sourceLine)
                    continue
                }
            } else {
                XCTFail("Unregistered hosted attribute \(line.cat.rawValue).\(key)", file: file, line: sourceLine)
            }
        }
    }

    private func gunzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initialization = inflateInit2_(
            &stream,
            MAX_WBITS + 16,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialization == Z_OK else {
            throw HostedDiagnosticsTestError.gunzip(initialization)
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        var status = Int32(Z_OK)
        try data.withUnsafeBytes { input in
            guard let baseAddress = input.bindMemory(to: Bytef.self).baseAddress else {
                throw HostedDiagnosticsTestError.missingGzipInput
            }
            stream.next_in = UnsafeMutablePointer(mutating: baseAddress)
            stream.avail_in = uInt(data.count)
            repeat {
                var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                let capacity = buffer.count
                var produced = 0
                try buffer.withUnsafeMutableBytes { destination in
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(capacity)
                    status = inflate(&stream, Z_NO_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END else {
                        throw HostedDiagnosticsTestError.gunzip(status)
                    }
                    produced = capacity - Int(stream.avail_out)
                }
                if produced > 0 {
                    output.append(buffer, count: produced)
                }
            } while status != Z_STREAM_END
        }
        return output
    }

    private func tarEntry(named targetName: String, in tar: Data) throws -> Data {
        var offset = 0
        while offset + 512 <= tar.count {
            let header = tar.subdata(in: offset..<(offset + 512))
            if header.allSatisfy({ $0 == 0 }) {
                break
            }
            let rawName = header.subdata(in: 0..<100)
            let nameEnd = rawName.firstIndex(of: 0) ?? rawName.endIndex
            let name = String(decoding: rawName[..<nameEnd], as: UTF8.self)
            let rawSize = header.subdata(in: 124..<136)
            let sizeText = String(decoding: rawSize, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
            guard let size = Int(sizeText, radix: 8) else {
                throw HostedDiagnosticsTestError.invalidTar
            }
            let contentStart = offset + 512
            let contentEnd = contentStart + size
            guard contentEnd <= tar.count else {
                throw HostedDiagnosticsTestError.invalidTar
            }
            if name == targetName {
                return tar.subdata(in: contentStart..<contentEnd)
            }
            offset = contentStart + ((size + 511) / 512) * 512
        }
        throw HostedDiagnosticsTestError.missingTarEntry(targetName)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HostedDiagnosticsStubProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }

    private func makeManifest() -> DiagnosticsManifest {
        DiagnosticsManifest(
            schemaVersion: 1,
            report: DiagnosticsManifest.Report(
                type: .manual,
                capturedAt: "2026-08-11T12:00:00Z",
                captureSessionID: "capture-hosted-test",
                appVersion: "1.0",
                appBuild: "7",
                platform: .ios,
                osVersion: "26.0",
                profileID: nil
            ),
            destination: DiagnosticsManifest.Destination(
                serverInstanceID: HostedDiagnosticsCapabilities.pinnedCollectorID
            ),
            consent: DiagnosticsManifest.Consent(mode: .manual, noticeVersion: 3),
            crash: nil,
            deviceSummary: DiagnosticsManifest.DeviceSummary(
                manufacturer: "Apple",
                model: "iPhone",
                os: "26.0",
                formFactor: "phone"
            ),
            playbackSessionIds: [],
            logSummary: DiagnosticsManifest.LogSummary(
                lines: 0,
                bytesGz: 0,
                droppedLines: 0,
                categories: [],
                debugLogging: false
            ),
            archive: DiagnosticsManifest.Archive(
                entries: ["manifest.json"],
                bytes: 19,
                uncompressedBytes: 19,
                sha256: String(repeating: "a", count: 64)
            )
        )
    }
}

private enum HostedDiagnosticsTestError: Error {
    case gunzip(Int32)
    case missingGzipInput
    case invalidTar
    case missingTarEntry(String)
}

private final class HostedTestCredentialStore: HostedDiagnosticsCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: HostedDiagnosticsCredential?
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    init(credential: HostedDiagnosticsCredential?) {
        self.credential = credential
    }

    func load() -> HostedDiagnosticsCredential? {
        lock.withLock { credential }
    }

    func save(_ credential: HostedDiagnosticsCredential) -> Bool {
        lock.withLock {
            self.credential = credential
            saveCount += 1
        }
        return true
    }

    func clear() {
        lock.withLock {
            credential = nil
            clearCount += 1
        }
    }
}

private final class HostedDiagnosticsStubProtocol: URLProtocol {
    struct CapturedRequest {
        let method: String
        let path: String
        let host: String?
        let authorization: String?
        let profileHeader: String?
        let profileTokenHeader: String?
        let siloDeviceIDHeader: String?
        let cookieHeader: String?
        let uploadToken: String?
        let contentType: String?
        let contentLength: String?
        let timeoutInterval: TimeInterval
        let body: Data
    }

    private enum Mode {
        case upload(reportID: UUID, bundle: Data)
        case invalidTokenRecovery(reportID: UUID, bundle: Data)
        case statusFailureAfterAccepted(reportID: UUID, bundle: Data)
        case putAcceptance(reportID: UUID, bundle: Data, body: String)
        case delete(reportID: UUID, statusCode: Int)
        case reportStatus(
            reportID: UUID,
            shortID: String,
            state: DiagnosticsRemoteReportState,
            errorCode: String?
        )
        case capabilities(
            status: DiagnosticsAvailabilityStatus,
            collectorID: String,
            acceptedSchemaVersions: [Int]
        )
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode: Mode = .capabilities(
        status: .available,
        collectorID: HostedDiagnosticsCapabilities.pinnedCollectorID,
        acceptedSchemaVersions: [1]
    )
    nonisolated(unsafe) private static var captured: [CapturedRequest] = []
    nonisolated(unsafe) private static var rejectedRevokedToken = false

    static func configure(reportID: UUID, bundle: Data) {
        lock.withLock {
            mode = .upload(reportID: reportID, bundle: bundle)
            captured = []
            rejectedRevokedToken = false
        }
    }

    static func configureInvalidTokenRecovery(reportID: UUID, bundle: Data) {
        lock.withLock {
            mode = .invalidTokenRecovery(reportID: reportID, bundle: bundle)
            captured = []
            rejectedRevokedToken = false
        }
    }

    static func configureStatusFailureAfterAccepted(reportID: UUID, bundle: Data) {
        lock.withLock {
            mode = .statusFailureAfterAccepted(reportID: reportID, bundle: bundle)
            captured = []
            rejectedRevokedToken = false
        }
    }

    static func configurePutAcceptance(reportID: UUID, bundle: Data, body: String) {
        lock.withLock {
            mode = .putAcceptance(reportID: reportID, bundle: bundle, body: body)
            captured = []
            rejectedRevokedToken = false
        }
    }

    static func configureReportStatus(
        reportID: UUID,
        shortID: String,
        state: DiagnosticsRemoteReportState,
        errorCode: String?
    ) {
        lock.withLock {
            mode = .reportStatus(
                reportID: reportID,
                shortID: shortID,
                state: state,
                errorCode: errorCode
            )
            captured = []
            rejectedRevokedToken = false
        }
    }

    static func configureDelete(reportID: UUID, statusCode: Int) {
        lock.withLock {
            mode = .delete(reportID: reportID, statusCode: statusCode)
            captured = []
            rejectedRevokedToken = false
        }
    }

    static func configureCapabilities(
        status: DiagnosticsAvailabilityStatus = .available,
        collectorID: String = HostedDiagnosticsCapabilities.pinnedCollectorID,
        acceptedSchemaVersions: [Int] = [1]
    ) {
        lock.withLock {
            mode = .capabilities(
                status: status,
                collectorID: collectorID,
                acceptedSchemaVersions: acceptedSchemaVersions
            )
            captured = []
            rejectedRevokedToken = false
        }
    }

    static func requests() -> [CapturedRequest] {
        lock.withLock { captured }
    }

    static func reset() {
        configureCapabilities()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "collector.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Self.requestBody(of: request)
        Self.lock.withLock {
            Self.captured.append(CapturedRequest(
                method: request.httpMethod ?? "",
                path: url.path,
                host: url.host,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                profileHeader: request.value(forHTTPHeaderField: "X-Profile-Id"),
                profileTokenHeader: request.value(forHTTPHeaderField: "X-Profile-Token"),
                siloDeviceIDHeader: request.value(forHTTPHeaderField: "X-Silo-Device-Id"),
                cookieHeader: request.value(forHTTPHeaderField: "Cookie"),
                uploadToken: request.value(forHTTPHeaderField: "X-Upload-Token"),
                contentType: request.value(forHTTPHeaderField: "Content-Type"),
                contentLength: request.value(forHTTPHeaderField: "Content-Length"),
                timeoutInterval: request.timeoutInterval,
                body: body
            ))
        }

        let response = Self.lock.withLock { () -> (Int, String) in
            switch Self.mode {
            case .capabilities(let status, let collectorID, let acceptedSchemaVersions):
                let versions = acceptedSchemaVersions.map(String.init).joined(separator: ",")
                return (200, #"{"status":"\#(status.rawValue)","collector_id":"\#(collectorID)","accepted_schema_versions":[\#(versions)],"max_bundle_bytes":10485760,"max_manifest_bytes":65536,"retention_days":30,"consent_notice_version":1}"#)
            case .reportStatus(let reportID, let shortID, let state, let errorCode):
                let error = errorCode.map { #","error_code":"\#($0)""# } ?? ""
                return (
                    200,
                    #"{"report_id":"\#(reportID.uuidString.lowercased())","short_id":"\#(shortID)","state":"\#(state.rawValue)"\#(error)}"#
                )
            case .upload(let reportID, let expectedBundle):
                return Self.uploadResponse(
                    request: request,
                    url: url,
                    body: body,
                    reportID: reportID,
                    expectedBundle: expectedBundle
                )
            case .invalidTokenRecovery(let reportID, let expectedBundle):
                if request.httpMethod == "POST",
                   url.path == "/v1/reports",
                   request.value(forHTTPHeaderField: "Authorization") == "Bearer revoked-installation-token",
                   !Self.rejectedRevokedToken {
                    Self.rejectedRevokedToken = true
                    return (401, #"{"error":"invalid_installation_token","message":"Installation token is invalid"}"#)
                }
                return Self.uploadResponse(
                    request: request,
                    url: url,
                    body: body,
                    reportID: reportID,
                    expectedBundle: expectedBundle
                )
            case .statusFailureAfterAccepted(let reportID, let expectedBundle):
                if request.httpMethod == "GET",
                   url.path == "/v1/reports/\(reportID.uuidString.lowercased())" {
                    return (503, #"{"error":"unavailable","message":"Try again"}"#)
                }
                return Self.uploadResponse(
                    request: request,
                    url: url,
                    body: body,
                    reportID: reportID,
                    expectedBundle: expectedBundle
                )
            case .putAcceptance(let reportID, let expectedBundle, let responseBody):
                return Self.uploadResponse(
                    request: request,
                    url: url,
                    body: body,
                    reportID: reportID,
                    expectedBundle: expectedBundle,
                    putResponseBody: responseBody
                )
            case .delete(let reportID, let statusCode):
                guard request.httpMethod == "DELETE",
                      url.path == "/v1/reports/\(reportID.uuidString.lowercased())" else {
                    return (404, #"{"error":"report_not_found"}"#)
                }
                if statusCode == 204 {
                    return (204, "")
                }
                if statusCode == 404 {
                    return (404, #"{"error":"report_not_found"}"#)
                }
                return (statusCode, #"{"error":"unavailable"}"#)
            }
        }
        respond(statusCode: response.0, body: response.1)
    }

    override func stopLoading() {}

    private static func uploadResponse(
        request: URLRequest,
        url: URL,
        body: Data,
        reportID: UUID,
        expectedBundle: Data,
        putResponseBody: String? = nil
    ) -> (Int, String) {
        let id = reportID.uuidString.lowercased()
        switch (request.httpMethod, url.path) {
        case ("POST", "/v1/installations"):
            return (201, #"{"installation_id":"install_apple_generated","installation_token":"generated-installation-token"}"#)
        case ("POST", "/v1/reports"):
            return (201, #"{"report_id":"\#(id)","short_id":"SILO-APPLE1234","upload_token":"one-time-upload-token","expires_at":"2026-08-12T12:00:00Z"}"#)
        case ("PUT", "/v1/reports/\(id)/bundle"):
            guard body == expectedBundle else {
                return (400, #"{"error":"archive_mismatch"}"#)
            }
            return (
                202,
                putResponseBody
                    ?? #"{"report_id":"\#(id)","short_id":"SILO-APPLE1234","state":"processing"}"#
            )
        case ("GET", "/v1/reports/\(id)"):
            return (200, #"{"report_id":"\#(id)","short_id":"SILO-APPLE1234","state":"processing"}"#)
        default:
            return (404, #"{"error":"not_found"}"#)
        }
    }

    private static func requestBody(of request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private func respond(statusCode: Int, body: String) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty {
            client?.urlProtocol(self, didLoad: Data(body.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class SelfHostedDiagnosticsStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var serverInstanceID = "self-hosted-diagnostics-instance"
    nonisolated(unsafe) private static var reportID = UUID()
    nonisolated(unsafe) private static var paths: [String] = []

    static func configure(serverInstanceID: String, reportID: UUID) {
        lock.withLock {
            self.serverInstanceID = serverInstanceID
            self.reportID = reportID
            paths = []
        }
    }

    static func requestedPaths() -> [String] {
        lock.withLock { paths }
    }

    static func reset() {
        lock.withLock {
            serverInstanceID = "self-hosted-diagnostics-instance"
            reportID = UUID()
            paths = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "selfhost.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = Self.lock.withLock { () -> (Int, String) in
            Self.paths.append(url.path)
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/v1/diagnostics/status"):
                return (
                    200,
                    #"{"status":"available","server_instance_id":"\#(Self.serverInstanceID)","accepted_schema_versions":[1],"max_bundle_bytes":10485760,"max_manifest_bytes":65536,"retention_days":30,"consent_notice_version":1}"#
                )
            case ("GET", "/api/v1/auth/me"):
                return (
                    200,
                    #"{"id":42,"username":"diagnostics-test","email":"diagnostics@example.invalid","role":"user","download_allowed":true,"impersonation":null}"#
                )
            case ("POST", "/api/v1/diagnostics/reports"):
                return (
                    201,
                    #"{"report_id":"\#(Self.reportID.uuidString.lowercased())","short_id":"SILO-SELFHOSTED","state":"ready"}"#
                )
            default:
                return (404, #"{"error":"not_found"}"#)
            }
        }
        respond(statusCode: response.0, body: response.1)
    }

    override func stopLoading() {}

    private func respond(statusCode: Int, body: String) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
