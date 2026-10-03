import XCTest
@testable import Silo

final class ServerDiscoveryTests: XCTestCase {
    func testBareNameAcceptsOnlyOneDNSLabel() {
        for name in ["silo", "media-box", "NAS2", " silo "] {
            XCTAssertTrue(OverlayNameResolver.isBareName(name), name)
        }
        for name in ["", "localhost", "silo.example.com", "silo:8080", "http://silo", "silo/path", "-silo", "silo-", "192.168.1.5"] {
            XCTAssertFalse(OverlayNameResolver.isBareName(name), name)
        }
    }

    func testRedirectOriginIsHTTPSOnly() {
        XCTAssertEqual(
            OverlayNameResolver.origin(of: URL(string: "https://silo.tail1234.ts.net/api/v2/system/identity")!),
            "https://silo.tail1234.ts.net")
        XCTAssertEqual(
            OverlayNameResolver.origin(of: URL(string: "https://silo.tail1234.ts.net:443/x")!),
            "https://silo.tail1234.ts.net")
        XCTAssertEqual(
            OverlayNameResolver.origin(of: URL(string: "https://silo.tail1234.ts.net:8443/x")!),
            "https://silo.tail1234.ts.net:8443")
        XCTAssertNil(OverlayNameResolver.origin(of: URL(string: "http://silo/api/v2/system/identity")!))
    }

    func testRedirectMustExpandTheProbedName() {
        XCTAssertTrue(OverlayNameResolver.isExpansion(of: "silo", host: "silo.tail1234.ts.net"))
        XCTAssertTrue(OverlayNameResolver.isExpansion(of: "Media-Box", host: "media-box.tail1234.ts.net"))
        XCTAssertFalse(OverlayNameResolver.isExpansion(of: "silo", host: "evil.example"))
        XCTAssertFalse(OverlayNameResolver.isExpansion(of: "silo", host: "silo-1.tail1234.ts.net"))
        XCTAssertFalse(OverlayNameResolver.isExpansion(of: "silo", host: "silo."))
        XCTAssertFalse(OverlayNameResolver.isExpansion(of: "silo", host: nil))
    }

    func testOnlyOverlayAddressesAnswerBareNames() {
        for address in ["100.64.0.1", "100.100.1.2", "100.127.255.254", "fd7a:115c:a1e0::1", "fd7a:115c:a1e0::abcd%utun5"] {
            XCTAssertTrue(OverlayNameResolver.isOverlayAddress(address), address)
        }
        for address in ["100.63.255.255", "100.128.0.1", "192.168.1.10", "10.0.0.5", "fd00::1", "fe80::1", "not-an-ip"] {
            XCTAssertFalse(OverlayNameResolver.isOverlayAddress(address), address)
        }
    }

    @MainActor
    func testBareNameTriesTheRedirectedOriginFirst() async {
        let attempts = AttemptLog()
        let viewModel = ServerSetupViewModel(
            checkServer: { url in
                await attempts.append(url)
                throw URLError(.cannotConnectToHost)
            },
            resolveBareName: { name in name == "media-box" ? "https://media-box.tail1234.ts.net" : nil }
        )
        viewModel.host = "media-box"
        await viewModel.connect(router: AppRouter())
        let tried = await attempts.urls
        XCTAssertEqual(tried.first, "https://media-box.tail1234.ts.net")
        XCTAssertTrue(tried.contains("http://media-box"), "unresolved fallbacks stay after the origin")
    }

    @MainActor
    func testQualifiedHostNeverProbesTheOverlay() async {
        let resolved = AttemptLog()
        let viewModel = ServerSetupViewModel(
            checkServer: { _ in throw URLError(.cannotConnectToHost) },
            resolveBareName: { name in
                await resolved.append(name)
                return nil
            }
        )
        viewModel.host = "silo.example.com"
        await viewModel.connect(router: AppRouter())
        let names = await resolved.urls
        XCTAssertTrue(names.isEmpty)
    }
}

private actor AttemptLog {
    private(set) var urls: [String] = []
    func append(_ url: String) { urls.append(url) }
}
