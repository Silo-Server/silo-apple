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
        XCTAssertEqual(
            OverlayNameResolver.origin(of: URL(string: "https://[2001:db8::1]/api/v2/system/identity")!),
            "https://[2001:db8::1]")
        XCTAssertEqual(
            OverlayNameResolver.origin(of: URL(string: "https://[2001:db8::1]:8443/x")!),
            "https://[2001:db8::1]:8443")
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

    func testOverlayProbeNeedsOverlayAddressesOnBothEnds() {
        let tunnel = { (address: String) in address == "100.100.1.9" }
        XCTAssertTrue(OverlayNameResolver.ranOverOverlay([
            (local: "100.100.1.9", remote: "100.100.1.2"), (local: "100.100.1.9", remote: "100.100.1.2"),
        ], isTunnelAddress: tunnel))
        // A local network that resolves the name to a CGNAT address and routes it to itself.
        XCTAssertFalse(OverlayNameResolver.ranOverOverlay([(local: "192.168.1.20", remote: "100.100.1.2")], isTunnelAddress: tunnel))
        // An overlay first hop redirected to a host outside the overlay.
        XCTAssertFalse(OverlayNameResolver.ranOverOverlay([
            (local: "100.100.1.9", remote: "100.100.1.2"), (local: "192.168.1.20", remote: "203.0.113.5"),
        ], isTunnelAddress: tunnel))
        // A LAN that numbers its clients from the CGNAT range, with no tunnel.
        XCTAssertFalse(OverlayNameResolver.ranOverOverlay([(local: "100.70.0.20", remote: "100.70.0.1")], isTunnelAddress: tunnel))
        XCTAssertFalse(OverlayNameResolver.ranOverOverlay([], isTunnelAddress: tunnel))
    }

    func testOnlyPointToPointInterfacesAreTunnels() {
        // The loopback address is on a loopback interface, not a tunnel.
        XCTAssertFalse(OverlayNameResolver.isTunnelAddress("127.0.0.1"))
        XCTAssertFalse(OverlayNameResolver.isTunnelAddress("not-an-ip"))
    }

    @MainActor
    func testBareNameTriesHTTPSThenTheRedirectedOriginBeforeHTTP() async {
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
        // A LAN host serving HTTPS on its bare name is not held up by the lookup.
        XCTAssertEqual(tried, ["https://media-box", "https://media-box.tail1234.ts.net"])
        // Plain HTTP still waits for the person to agree, as for any address.
        XCTAssertNotNil(viewModel.insecurePrompt)
    }

    @MainActor
    func testFoundServerFailureStaysOffTheAddressField() async {
        let viewModel = ServerSetupViewModel(checkServer: { _ in throw URLError(.cannotConnectToHost) })
        let found = DiscoveredServer(serverId: "id", name: "Den", url: "https://silo.tail1234.ts.net", route: .overlay)
        await viewModel.connect(to: found, router: AppRouter())
        XCTAssertNil(viewModel.error)
        XCTAssertNotNil(viewModel.discoveryError)
        XCTAssertNil(viewModel.connectingServerID)
    }

    @MainActor
    func testDecliningHTTPForAFoundServerIsNotAnError() async {
        let viewModel = ServerSetupViewModel(checkServer: { _ in APIv2SetupStatus(needsSetup: false) })
        let found = DiscoveredServer(serverId: "id", name: "Den", url: "http://192.168.1.5:8090", route: .localNetwork)
        await viewModel.connect(to: found, router: AppRouter())
        let prompt = viewModel.insecurePrompt
        XCTAssertEqual(prompt?.address, "192.168.1.5:8090")
        viewModel.dismissInsecurePrompt()
        viewModel.cancelInsecure(prompt)
        XCTAssertNil(viewModel.error)
        XCTAssertNil(viewModel.discoveryError)
    }

    func testFoundServerDetailKeepsThePort() {
        let server = DiscoveredServer(serverId: "id", name: "Den", url: "http://192.168.1.5:8091", route: .localNetwork)
        XCTAssertEqual(server.detail, "On this network · 192.168.1.5:8091")
    }

    @MainActor
    func testInputsStayLockedWhileABareNameResolves() async {
        let box = ViewModelBox()
        let viewModel = ServerSetupViewModel(
            checkServer: { _ in throw URLError(.cannotConnectToHost) },
            resolveBareName: { _ in
                await MainActor.run {
                    // An edit made while the name resolves is put back, as the
                    // screen does through `keepsSubmittedServerInputs`.
                    box.viewModel?.host = "edited.example.com"
                    box.viewModel?.restoreSubmittedInputs()
                }
                return nil
            }
        )
        box.viewModel = viewModel
        viewModel.host = "media-box"
        await viewModel.connect(router: AppRouter())
        XCTAssertEqual(viewModel.host, "media-box")
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

@MainActor
private final class ViewModelBox {
    var viewModel: ServerSetupViewModel?
}

private actor AttemptLog {
    private(set) var urls: [String] = []
    func append(_ url: String) { urls.append(url) }
}
