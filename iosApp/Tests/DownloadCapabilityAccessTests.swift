import Foundation
import XCTest
@testable import Silo

/// What the app offers for each downloads capability the server can send:
/// usable, unavailable with a reason, or nothing.
final class DownloadCapabilityAccessTests: XCTestCase {
    private func access(
        state: String,
        enabled: Bool,
        downloadAllowed: Bool,
        allowed: Bool
    ) throws -> DownloadCapability.Access {
        let json: [String: Any] = [
            "state": state,
            "allowed": allowed,
            "enabled": enabled,
            "downloadAllowed": downloadAllowed,
            "qualityPresets": [String](),
            "transcodeEnabled": false,
            "transcodeUserAllowed": false,
            "seasonDownload": false,
            "seriesMonitoring": false,
            "monitoringModes": [String](),
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(DownloadCapability.self, from: data).access
    }

    func testAnAllowedAccountOnAServerWithDownloadsCanDownload() throws {
        XCTAssertEqual(try access(state: "available", enabled: true, downloadAllowed: true, allowed: true), .usable)
    }

    func testAnAccountWhosePolicyDeniesDownloadsSeesThemAsUnavailable() throws {
        XCTAssertEqual(try access(state: "available", enabled: true, downloadAllowed: false, allowed: false), .restricted)
    }

    /// Demo mode refuses downloads to an account whose policy allows them.
    /// The account's admin can't lift that, so nothing is offered.
    func testARefusalTheAccountPolicyDoesNotExplainStaysHidden() throws {
        XCTAssertEqual(try access(state: "available", enabled: true, downloadAllowed: true, allowed: false), .hidden)
    }

    /// A server with downloads switched off sends each account's policy all
    /// the same; neither value brings Download back.
    func testAServerWithDownloadsSwitchedOffShowsNothing() throws {
        XCTAssertEqual(try access(state: "disabled", enabled: false, downloadAllowed: true, allowed: false), .hidden)
        XCTAssertEqual(try access(state: "disabled", enabled: false, downloadAllowed: false, allowed: false), .hidden)
    }

    func testAServerWithoutDownloadsShowsNothing() throws {
        XCTAssertEqual(try access(state: "not_configured", enabled: false, downloadAllowed: false, allowed: false), .hidden)
        XCTAssertEqual(try access(state: "unsupported", enabled: false, downloadAllowed: false, allowed: false), .hidden)
    }

    /// A copy cached before `state` and `allowed` were stored can't say the
    /// server offers downloads, so it shows nothing until the next read.
    func testACopyCachedWithoutStateShowsNothing() throws {
        let cached = #"{"enabled":true,"downloadAllowed":false,"qualityPresets":[],"transcodeEnabled":false,"transcodeUserAllowed":false,"seasonDownload":false,"seriesMonitoring":false,"monitoringModes":[]}"#
        let capability = try JSONDecoder().decode(DownloadCapability.self, from: Data(cached.utf8))
        XCTAssertEqual(capability.access, .hidden)
    }
}
