import Foundation
import XCTest
@testable import Silo

/// Offline delivery on v2: the manifest read, the artwork and subtitle routes
/// it names, the file URL the background session requests, and what a failed
/// file transfer does next.
final class DownloadDeliveryV2Tests: XCTestCase {
    private var stub = APIv2TestStub()
    private let device = AppleDeviceIdentity.current.id

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func client() async throws -> (APIv2Client, CapturedOrdinaryRequestAuth) {
        let name = "DownloadDeliveryV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://downloads.example")
        await tokens.setProfileId("profile-one")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), try XCTUnwrap(captured))
    }

    private func manifestFixture(_ mutate: ((inout [String: Any]) -> Void)? = nil) throws -> String {
        let data = try mutate.map {
            try APIv2FixtureTestSupport.mutatedBody(named: "download_manifest", bundleClass: Self.self, mutate: $0)
        } ?? APIv2FixtureTestSupport.data(named: "download_manifest", bundleClass: Self.self)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    // MARK: Manifest

    func testManifestDecodesTheContractFixture() async throws {
        let (api, auth) = try await client()
        stub.reply(200, try manifestFixture())

        let manifest = try await api.downloadManifest(id: "entry", auth: auth)

        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/v2/downloads/entry/manifest")
        XCTAssertEqual(request.header("x-silo-device-id"), device)
        XCTAssertEqual(request.header("x-profile-id"), "profile-one")
        XCTAssertEqual(manifest.mediaFileId, "42")
        XCTAssertEqual(manifest.revision, 2)
        XCTAssertEqual(manifest.artworkUrls?.poster, "/api/v2/downloads/entry/artwork/poster")
        XCTAssertEqual(manifest.subtitles?.first?.fetchUrl, "/api/v2/downloads/entry/subtitles/external:0")
    }

    /// Offline playback re-reads `manifest.json` with the store's bare coder
    /// and finds subtitle files by the manifest's `fetch_url`.
    func testStoredManifestKeepsItsFileIdAndSubtitleKeys() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadDeliveryV2Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let manifest = try HTTPClient.makeJSONDecoder()
            .decode(OfflineManifest.self, from: Data(try manifestFixture().utf8))
        let store = DownloadStore(rootDirectory: { root })
        let url = root.appendingPathComponent("manifest.json")

        await store.saveManifest(manifest, to: url)
        let stored = await store.loadManifest(at: url)

        XCTAssertEqual(stored, manifest)
        XCTAssertEqual(stored?.mediaFileId, "42")
        XCTAssertEqual(stored?.subtitles?.first?.fetchUrl, "/api/v2/downloads/entry/subtitles/external:0")
    }

    func testManifestThatDoesNotDescribeTheEntryIsRefused() async throws {
        let (api, auth) = try await client()
        let cases: [(String, (inout [String: Any]) -> Void)] = [
            ("another entry", { $0["download_id"] = "other" }),
            ("no revision", { $0.removeValue(forKey: "revision") }),
            ("numeric file id", { $0["media_file_id"] = 42 }),
            ("empty file id", { $0["media_file_id"] = "" }),
        ]
        for (label, mutate) in cases {
            stub.reply(200, try manifestFixture(mutate))
            do {
                _ = try await api.downloadManifest(id: "entry", auth: auth)
                XCTFail("accepted a manifest with \(label)")
            } catch {
                XCTAssertEqual(error as? DownloadRegistryError, .unusableManifest, label)
            }
        }
    }

    func testManifestFailureKeepsItsStatus() async throws {
        let (api, auth) = try await client()
        for status in [404, 409, 410] {
            stub.reply(status, #"{"type":"https://silo.example/problems/p","title":"P","status":\#(status),"detail":"P."}"#)
            do {
                _ = try await api.downloadManifest(id: "entry", auth: auth)
                XCTFail("accepted a \(status)")
            } catch APIv2Error.problem(let problem) {
                XCTAssertEqual(problem.status, status)
            }
        }
    }

    // MARK: Assets

    func testAssetFetchUsesTheManifestRoute() async throws {
        let (api, auth) = try await client()
        stub.reply(.text(200, "WEBVTT", contentType: "text/vtt"))

        let data = try await api.downloadAsset(path: "/api/v2/downloads/entry/subtitles/external:0",
            downloadId: "entry", auth: auth)

        XCTAssertEqual(String(data: data, encoding: .utf8), "WEBVTT")
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/v2/downloads/entry/subtitles/external:0")
        XCTAssertEqual(request.header("x-silo-device-id"), device)
    }

    func testAssetPathOutsideTheEntryIsNeverSent() async throws {
        let (api, auth) = try await client()
        let refused = [
            "/api/v2/downloads/other/artwork/poster",
            "https://elsewhere.example/api/v2/downloads/entry/artwork/poster",
            "/api/v2/downloads/entry/artwork/poster?sig=1",
            "/api/v2/downloads/entry/file",
            "/api/v2/downloads/entry/subtitles/..",
            "/api/v2/downloads/entry/subtitles/a/b",
            "/api/v2/catalog/items/entry",
        ]
        for path in refused {
            do {
                _ = try await api.downloadAsset(path: path, downloadId: "entry", auth: auth)
                XCTFail("fetched \(path)")
            } catch {
                XCTAssertEqual(error as? DownloadRegistryError, .invalidRequest, path)
            }
        }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testAssetFailureStatusIsThrown() async throws {
        let (api, auth) = try await client()
        stub.reply(404, #"{"type":"https://silo.example/problems/not_found","title":"Not found","status":404,"detail":"Gone."}"#)
        do {
            _ = try await api.downloadAsset(path: "/api/v2/downloads/entry/artwork/logo", downloadId: "entry", auth: auth)
            XCTFail("returned bytes for a 404")
        } catch APIv2Error.problem(let problem) {
            XCTAssertEqual(problem.status, 404)
        }
    }

    // MARK: File

    func testFileURLKeepsTheServerMountAndEncodesTheId() throws {
        let url = try XCTUnwrap(APIv2Client.downloadFileURL(id: "a b", serverURL: "https://host.example/mount/"))
        XCTAssertEqual(url.absoluteString, "https://host.example/mount/api/v2/downloads/a%20b/file")
        XCTAssertTrue(APIv2Client.isDownloadFileURL(url))
        XCTAssertNil(APIv2Client.downloadFileURL(id: "..", serverURL: "https://host.example"))
        XCTAssertNil(APIv2Client.downloadFileURL(id: "d1", serverURL: ""))
    }

    func testOnlyTheV2FileRouteCountsAsACurrentTransfer() {
        XCTAssertTrue(APIv2Client.isDownloadFileURL(URL(string: "https://host.example/api/v2/downloads/d1/file")))
        XCTAssertFalse(APIv2Client.isDownloadFileURL(URL(string: "https://host.example/api/v2/downloads/d1/manifest")))
        XCTAssertFalse(APIv2Client.isDownloadFileURL(URL(string: "https://host.example/api/v2/downloads//file")))
        XCTAssertFalse(APIv2Client.isDownloadFileURL(URL(string: "https://host.example/downloads/d1/file")))
        XCTAssertFalse(APIv2Client.isDownloadFileURL(nil))
    }

    func testGoneOrMismatchedFileRestartsTheDownload() {
        for status in [410, 412, 416] {
            XCTAssertEqual(DownloadManager.mediaFailureAction(statusCode: status, retryCount: 0, message: "HTTP"),
                .retry(keepResumeData: false, refreshToken: false), "\(status)")
        }
        XCTAssertEqual(DownloadManager.mediaFailureAction(statusCode: 410, retryCount: 4, message: "HTTP"),
            .fail("http_410"))
        // A dropped connection resumes where it stopped.
        XCTAssertEqual(DownloadManager.mediaFailureAction(statusCode: nil, retryCount: 0, message: "offline"),
            .retry(keepResumeData: true, refreshToken: false))
        XCTAssertEqual(DownloadManager.mediaFailureAction(statusCode: nil, retryCount: 4, message: "offline"),
            .fail("offline"))
        XCTAssertEqual(DownloadManager.mediaFailureAction(statusCode: 401, retryCount: 0, message: "HTTP"),
            .retry(keepResumeData: false, refreshToken: true))
        XCTAssertEqual(DownloadManager.mediaFailureAction(statusCode: 409, retryCount: 0, message: "HTTP"), .revoke)
    }
}
