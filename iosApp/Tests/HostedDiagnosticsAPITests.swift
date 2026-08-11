import XCTest
@testable import Silo
import zlib

final class HostedDiagnosticsAPITests: XCTestCase {
    override func tearDown() {
        HostedDiagnosticsStubProtocol.reset()
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
        XCTAssertEqual(upload.contentType, "application/gzip")
        XCTAssertEqual(upload.contentLength, String(bundle.count))
        XCTAssertEqual(upload.uploadToken, "one-time-upload-token")
        XCTAssertEqual(upload.body, bundle)

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
        let logLine = try XCTUnwrap(DiagLog.renderedLine(
            level: .info,
            category: .playback,
            tag: "CMP playback_session_id=\(privateLogSessionID)",
            message: "[CMP-ROUTE] playbackSessionId=\(privateLogSessionID) fileId=private-file-log planId=private-plan-log route selected",
            attrs: [
                "sink": .string("HDMI"),
                "width": .int(3840),
                "session_id": .string(privateLogSessionID),
                "play_method": .string("transcode"),
                "position_seconds": .double(42.5),
                "reason": .string("private-route-reason"),
            ],
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            captureSessionID: "failed-run"
        ))
        let breadcrumbLine = try XCTUnwrap(DiagLog.renderedLine(
            level: .info,
            category: .playback,
            tag: "PlaybackSessionBridge session_id=\(privateBreadcrumbSessionID)",
            message: "playback_session_id=\(privateBreadcrumbSessionID) itemId=private-item-breadcrumb mediaId=private-media-breadcrumb playback stopped",
            attrs: [
                "decoder": .string("VideoToolbox"),
                "dropped_frames": .int(2),
                "session_id": .string(privateBreadcrumbSessionID),
                "play_method": .string("direct_play"),
                "position_seconds": .double(84.25),
                "reason": .string("private-stop-reason"),
            ],
            timestamp: Date(timeIntervalSince1970: 1_700_000_001),
            captureSessionID: "failed-run"
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
            captureSessionID: "failed-run"
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
            ]
        ))
        let localBindingSidecar = try Data(contentsOf: report.directoryURL.appendingPathComponent(
            "binding.json"
        ))
        let renderedLocalBinding = String(decoding: localBindingSidecar, as: UTF8.self)
        XCTAssertFalse(renderedLocalBinding.contains("private-local-server-registry-id"))
        XCTAssertFalse(renderedLocalBinding.contains("private-local-account-id"))
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
        let hostedLog = try XCTUnwrap(decodeLogLines(logsData).first)
        let hostedBreadcrumb = try XCTUnwrap(decodeLogLines(breadcrumbsData).first)

        XCTAssertEqual(hostedLog.attrs, [
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
            "position_seconds",
            "reason",
            privateLogSessionID,
            privateBreadcrumbSessionID,
            "private-route-reason",
            "private-stop-reason",
            "private-file-log",
            "private-plan-log",
            "private-item-breadcrumb",
            "private-media-breadcrumb",
            binding.serverInstanceID,
            "private-local-account-id",
        ] {
            XCTAssertFalse(renderedEvidence.contains(forbidden), forbidden)
        }
        XCTAssertTrue(hostedLog.msg.contains("[redacted_private_id]"))
        XCTAssertTrue(hostedBreadcrumb.tag.contains("[redacted_private_id]"))
        XCTAssertEqual(bundle.manifest.playbackSessionIds, [])
        XCTAssertEqual(
            bundle.manifest.destination.serverInstanceID,
            HostedDiagnosticsCapabilities.pinnedCollectorID
        )
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
            audio: .object(["passthrough": .string("unknown")]),
            videoCodecs: .string("not_collected"),
            network: .object(["transport": .string("not_collected")])
        )
    }

    private func makePendingHostedReport(
        label: String
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
        let store = PendingReportStore(rootDirectory: root)
        let report = try store.save(PendingReportCapture(
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
        let body: Data
    }

    private enum Mode {
        case upload(reportID: UUID, bundle: Data)
        case invalidTokenRecovery(reportID: UUID, bundle: Data)
        case statusFailureAfterAccepted(reportID: UUID, bundle: Data)
        case putAcceptance(reportID: UUID, bundle: Data, body: String)
        case capabilities(collectorID: String)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode: Mode = .capabilities(
        collectorID: HostedDiagnosticsCapabilities.pinnedCollectorID
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

    static func configureCapabilities(
        collectorID: String = HostedDiagnosticsCapabilities.pinnedCollectorID
    ) {
        lock.withLock {
            mode = .capabilities(collectorID: collectorID)
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
                body: body
            ))
        }

        let response = Self.lock.withLock { () -> (Int, String) in
            switch Self.mode {
            case .capabilities(let collectorID):
                return (200, #"{"status":"available","collector_id":"\#(collectorID)","accepted_schema_versions":[1],"max_bundle_bytes":10485760,"max_manifest_bytes":65536,"retention_days":30,"consent_notice_version":1}"#)
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
