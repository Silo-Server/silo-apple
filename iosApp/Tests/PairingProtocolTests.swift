import XCTest
import Foundation
#if os(iOS)
import Network
#endif
@testable import Silo

final class PairingProtocolTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func roundTrip(_ message: PairingMessage) -> PairingMessage {
        let data = try! encoder.encode(message)
        return try! decoder.decode(PairingMessage.self, from: data)
    }

    func testRoundTripsEveryCase() {
        let cases: [PairingMessage] = [
            .hello(tvName: "Living Room", tvDeviceId: "ABC-123", state: .setup, supportedVersions: [1]),
            .pushServer(serverURL: "https://media.example.com", serverName: "Home"),
            .pushServer(serverURL: "https://media.example.com", serverName: nil),
            .pushServer(
                serverURL: "https://media.example.com", serverName: "Home",
                serverIdentity: "96c1bd08-b839-4d47-980e-57d4e7a44cfa",
                endpoints: [
                    ServerEndpoint(url: "https://media.example.com", kind: .public),
                    ServerEndpoint(url: "https://media.overlay.example", kind: .provider, provider: "tailscale", displayName: "Tailscale"),
                ]
            ),
            .serverResult(serverURL: "https://media.example.com", status: .failed, error: PairingFailureCode.unreachable.rawValue),
            .deviceStarted(serverURL: "https://media.example.com", userCode: "WXYZ-12", matchCode: "brave-otter"),
            .serverResult(serverURL: "https://media.example.com", status: .signedIn, error: nil),
            .serverResult(serverURL: "https://media.example.com", status: .failed, error: "timeout"),
            .done,
            .cancel(reason: "user_declined")
        ]
        for message in cases {
            XCTAssertTrue(roundTrip(message) == message, "round-trip mismatch for \(message)")
        }
    }

    func testTypeDiscriminatorAndVersionArePresent() {
        let data = try! encoder.encode(PairingMessage.done)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertTrue(json["type"] as? String == "done", "missing/incorrect type discriminator")
        XCTAssertTrue(json["v"] as? Int == PairingProtocol.version, "missing/incorrect version")
    }

    /// Every frame as a peer puts it on the wire; silo-android's
    /// `PairingMessageCodec` writes the same keys. A round trip passes even
    /// when a key is renamed on both sides of this codec, which would strand
    /// older phones and TVs; these literals fail instead.
    func testLiteralWireFramesDecodeAndEncodeExactly() throws {
        let url = "https://media.example.com"
        let frames: [(String, PairingMessage)] = [
            (#"{"type":"hello","v":1,"tvName":"Living Room","tvDeviceId":"ABC-123","state":"setup","supportedVersions":[1]}"#,
             .hello(tvName: "Living Room", tvDeviceId: "ABC-123", state: .setup, supportedVersions: [1])),
            (#"{"type":"pushServer","v":1,"serverURL":"https://media.example.com","serverName":"Home"}"#,
             .pushServer(serverURL: url, serverName: "Home")),
            (#"{"type":"deviceStarted","v":1,"serverURL":"https://media.example.com","userCode":"WXYZ-12","matchCode":"brave-otter"}"#,
             .deviceStarted(serverURL: url, userCode: "WXYZ-12", matchCode: "brave-otter")),
            (#"{"type":"serverResult","v":1,"serverURL":"https://media.example.com","status":"signedIn"}"#,
             .serverResult(serverURL: url, status: .signedIn, error: nil)),
            (#"{"type":"serverResult","v":1,"serverURL":"https://media.example.com","status":"failed","error":"unreachable"}"#,
             .serverResult(serverURL: url, status: .failed, error: PairingFailureCode.unreachable.rawValue)),
            (#"{"type":"done","v":1}"#, .done),
            (#"{"type":"cancel","v":1,"reason":"user_declined"}"#, .cancel(reason: "user_declined")),
            // Copied verbatim from silo-android's PairingProtocolGoldenFramesTest
            // (`androidFrames`): a signed-out TV's hello, a push carrying the
            // server identity and endpoints, and an identity mismatch.
            (#"{"type":"hello","v":1,"tvName":"Den","tvDeviceId":"id-9","state":"login","supportedVersions":[1]}"#,
             .hello(tvName: "Den", tvDeviceId: "id-9", state: .login, supportedVersions: [1])),
            (#"{"type":"pushServer","v":1,"serverURL":"https://media.example.com","serverName":"Home","#
                + #""serverIdentity":"96c1bd08-b839-4d47-980e-57d4e7a44cfa","endpoints":["#
                + #"{"url":"https://media.example.com","kind":"public"},"#
                + #"{"url":"https://media.overlay.example","kind":"provider","provider":"tailscale","displayName":"Tailscale"}]}"#,
             .pushServer(
                serverURL: url, serverName: "Home",
                serverIdentity: "96c1bd08-b839-4d47-980e-57d4e7a44cfa",
                endpoints: [
                    ServerEndpoint(url: url, kind: .public),
                    ServerEndpoint(url: "https://media.overlay.example", kind: .provider, provider: "tailscale", displayName: "Tailscale"),
                ])),
            (#"{"type":"serverResult","v":1,"serverURL":"https://media.example.com","status":"failed","error":"identity_mismatch"}"#,
             .serverResult(serverURL: url, status: .failed, error: PairingFailureCode.identityMismatch.rawValue)),
        ]
        for (frame, message) in frames {
            XCTAssertEqual(try decoder.decode(PairingMessage.self, from: Data(frame.utf8)), message, frame)
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(message)) as? NSDictionary)
            let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? NSDictionary)
            XCTAssertEqual(encoded, expected, frame)
        }
    }

    /// Protocol stays v1: the identity fields are additive and optional, so a
    /// legacy push decodes and a legacy peer sees no new required key.
    func testPushServerIdentityFieldsAreOptionalOnTheWire() throws {
        let legacy = Data(#"{"type":"pushServer","v":1,"serverURL":"https://media.example.com","serverName":"Home"}"#.utf8)
        guard case let .pushServer(url, name, identity, endpoints, accountName) = try decoder.decode(PairingMessage.self, from: legacy) else {
            return XCTFail("expected pushServer")
        }
        XCTAssertEqual(url, "https://media.example.com")
        XCTAssertEqual(name, "Home")
        XCTAssertNil(identity)
        XCTAssertNil(endpoints)
        XCTAssertNil(accountName)

        let data = try encoder.encode(PairingMessage.pushServer(serverURL: "https://media.example.com", serverName: nil))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["serverIdentity"])
        XCTAssertNil(json["endpoints"])
        XCTAssertNil(json["accountName"])
        XCTAssertEqual(json["v"] as? Int, 1)

        let full = try encoder.encode(PairingMessage.pushServer(
            serverURL: "https://media.example.com", serverName: "Home", serverIdentity: "S",
            endpoints: [ServerEndpoint(url: "https://media.overlay.example/", kind: .provider, provider: "tailscale", displayName: "Tailscale")]
        ))
        let fullJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: full) as? [String: Any])
        let endpoint = try XCTUnwrap((fullJSON["endpoints"] as? [[String: Any]])?.first)
        XCTAssertEqual(endpoint["url"] as? String, "https://media.overlay.example")
        XCTAssertEqual(endpoint["kind"] as? String, "provider")
        XCTAssertEqual(endpoint["displayName"] as? String, "Tailscale")
    }

    /// Contract §D: the golden frames Apple and Android must both decode and
    /// re-encode exactly, with the display-only `accountName` and the
    /// `limit_reached` failure code.
    func testMultiAccountGoldenFramesDecodeAndEncodeExactly() throws {
        let url = "https://home.example.org"
        let frames: [(String, PairingMessage)] = [
            (#"{"type":"pushServer","v":1,"serverURL":"https://home.example.org","serverName":"Home","serverIdentity":"5f0c8a1e-2d4b-4c3a-9e7f-1a2b3c4d5e6f","accountName":"sam"}"#,
             .pushServer(serverURL: url, serverName: "Home", serverIdentity: "5f0c8a1e-2d4b-4c3a-9e7f-1a2b3c4d5e6f",
                         accountName: "sam")),
            (#"{"type":"serverResult","v":1,"serverURL":"https://home.example.org","status":"failed","error":"limit_reached"}"#,
             .serverResult(serverURL: url, status: .failed, error: PairingFailureCode.limitReached.rawValue)),
        ]
        for (frame, message) in frames {
            XCTAssertEqual(try decoder.decode(PairingMessage.self, from: Data(frame.utf8)), message, frame)
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(message)) as? NSDictionary)
            let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? NSDictionary)
            XCTAssertEqual(encoded, expected, frame)
        }
        XCTAssertEqual(PairingFailureCode(wire: "limit_reached"), .limitReached)
        XCTAssertEqual(PairingFailureCode.limitReached.wireValue, "limit_reached")
    }

    /// The TXT record: `acct=1` takes several accounts, `lim` caps them, and
    /// a `lim` that isn't a positive count reads as no limit.
    func testTXTRecordReadsAccountsAndLimit() {
        #if os(iOS)
        let endpoint = NWEndpoint.hostPort(host: "tv.local", port: 9)
        func tv(_ txt: [String: String]) -> DiscoveredTV? {
            TVPairingBrowser.makeTV(txt: txt, endpoint: endpoint, serviceType: PairingProtocol.rokuServiceType)
        }
        XCTAssertEqual(tv(["acct": "1", "lim": "3"])?.acceptsSeveralAccounts, true)
        XCTAssertEqual(tv(["acct": "1", "lim": "3"])?.accountLimit, 3)
        XCTAssertNil(tv(["acct": "1", "lim": "0"])?.accountLimit)
        XCTAssertNil(tv(["acct": "1", "lim": "many"])?.accountLimit)
        XCTAssertEqual(tv([:])?.acceptsSeveralAccounts, false)
        XCTAssertNil(tv([:])?.accountLimit)
        #endif
    }

    /// The session binding is base64url without padding: the 32-byte secret
    /// and its SHA-256, 43 characters each, as the server checks them.
    func testSessionBindingEncodesTheSecretAndItsHash() throws {
        let fixed = PairingSessionBinding(secretBytes: Data(0..<32))
        XCTAssertEqual(fixed.secret, "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        XCTAssertEqual(fixed.binding, "Yw3NKWbEM2aRElRIu7JbT_QSpJxzLbLIq8G4WBvXEN0")
        let a = try XCTUnwrap(PairingSessionBinding.random())
        let b = try XCTUnwrap(PairingSessionBinding.random())
        XCTAssertNotEqual(a, b)
        for value in [a.secret, a.binding] {
            XCTAssertEqual(value.count, 43)
            XCTAssertTrue(value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }, value)
        }
    }

    /// Contract §C.5: the phone compares until a compared request supplies
    /// a binding, then approves that binding alone and refuses any other.
    func testApprovalDecisionFollowsTheTrustedBinding() {
        XCTAssertEqual(PairingApprovalDecision.decide(trusted: nil, lookupBinding: nil), .compare(trustOnConfirm: nil))
        XCTAssertEqual(PairingApprovalDecision.decide(trusted: nil, lookupBinding: "B1"), .compare(trustOnConfirm: "B1"))
        XCTAssertEqual(PairingApprovalDecision.decide(trusted: "B1", lookupBinding: nil), .compare(trustOnConfirm: nil))
        XCTAssertEqual(PairingApprovalDecision.decide(trusted: "B1", lookupBinding: "B1"), .approve)
        XCTAssertEqual(PairingApprovalDecision.decide(trusted: "B1", lookupBinding: "B2"), .refuse)
    }

    func testFailureCodesReadUnknownAsGenericFailure() {
        XCTAssertEqual(PairingFailureCode(wire: "unreachable"), .unreachable)
        XCTAssertEqual(PairingFailureCode(wire: "identity_mismatch"), .identityMismatch)
        XCTAssertEqual(PairingFailureCode(wire: nil), .authFailed)
        XCTAssertEqual(PairingFailureCode(wire: "something_new"), .authFailed)
    }

    func testUnknownTypeFailsToDecode() {
        let data = #"{"type":"bogus","v":1}"#.data(using: .utf8)!
        var threw = false
        do { _ = try decoder.decode(PairingMessage.self, from: data) } catch { threw = true }
        XCTAssertTrue(threw, "decoding an unknown type should throw")
    }
}
