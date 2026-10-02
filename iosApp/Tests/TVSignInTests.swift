import Foundation
import XCTest
@testable import Silo

#if canImport(Network)
import Network
#endif

/// TV sign-in pieces that are pure rules: how codes read, what the TV's
/// status line says, which saved server a link or a signed-out TV means,
/// and the phone's approval card flow.
final class TVSignInTests: XCTestCase {

    // MARK: Codes

    func testCodesDisplayGroupedAndReadOneCharacterAtATime() {
        XCTAssertEqual(DeviceUserCode.display("4821-7730"), "4821 7730")
        XCTAssertEqual(DeviceUserCode.display("48217730"), "4821 7730")
        XCTAssertEqual(DeviceUserCode.display("abcd-efgh"), "ABCD EFGH", "older servers send eight letters")
        XCTAssertEqual(DeviceUserCode.display("WARM"), "WARM", "anything else shows as sent")
        XCTAssertEqual(DeviceUserCode.normalized(" 4821 - 7730 "), "48217730")
        XCTAssertEqual(DeviceUserCode.spokenCharacters("4821-7730"), "4 8 2 1 7 7 3 0")
        XCTAssertTrue(DeviceUserCode.isComplete("4821 7730"))
        XCTAssertFalse(DeviceUserCode.isComplete("4821 773"))
        XCTAssertTrue(DeviceUserCode.isComplete("ABCD-EFGH"), "older servers issue letter codes")
        XCTAssertFalse(DeviceUserCode.isComplete("ÉBCD-EFGH"))
    }

    func testSignInTVFieldKeepsLetterAndDigitCodes() throws {
        XCTAssertEqual(DeviceUserCode.entryText("48217730"), "4821 7730")
        XCTAssertEqual(DeviceUserCode.entryText("abcd-efgh"), "ABCD EFGH")
        XCTAssertEqual(DeviceUserCode.entryText("ABCD EFGH J"), "ABCD EFGH", "at most eight characters")
        XCTAssertEqual(DeviceUserCode.entryText("ab"), "AB")
        XCTAssertEqual(DeviceUserCode.entryText("é4821·7730"), "4821 7730", "non-ASCII is dropped")
        XCTAssertTrue(DeviceUserCode.isComplete(DeviceUserCode.entryText("abcd-efgh")))

        // A web approval link from an older server reaches the field as its
        // `initialCode` and still enables Continue.
        let link = try XCTUnwrap(DeviceApprovalLink(url: XCTUnwrap(URL(string:
            "silo://device?url=http://10.0.0.2:8090&code=ABCD-EFGH"))))
        XCTAssertEqual(link.code, "ABCDEFGH")
        let field = DeviceUserCode.entryText(link.code)
        XCTAssertEqual(field, "ABCD EFGH")
        XCTAssertTrue(DeviceUserCode.isComplete(field))
    }

    // MARK: TV screen copy

    func testTheTVShowsTheTypedURLAndSaysWhatIsHappening() {
        // Android's DeviceCodeFormat.activateText rule: only https:// is
        // dropped, because browsers try https for a bare host.
        XCTAssertEqual(TVSignInPresentation.typedURL("https://silo.example.com/activate"), "silo.example.com/activate")
        XCTAssertEqual(TVSignInPresentation.typedURL("HTTPS://silo.example.com/activate/"), "silo.example.com/activate")
        XCTAssertEqual(TVSignInPresentation.typedURL("http://192.168.1.4:8090/activate/"), "http://192.168.1.4:8090/activate")
        XCTAssertEqual(TVSignInPresentation.typedURL("", complete: "https://media.example.com/silo/activate?code=48217730"),
            "media.example.com/silo/activate", "a blank verification_uri falls back to the QR URL without its query")
        // Android's DeviceCodeFormat.host rule: the port stays, with or
        // without a scheme.
        XCTAssertEqual(TVSignInPresentation.host(of: "http://192.168.1.4:8090/"), "192.168.1.4:8090")
        XCTAssertEqual(TVSignInPresentation.host(of: " 192.168.1.4:8090/silo?x=1"), "192.168.1.4:8090")
        XCTAssertEqual(TVSignInPresentation.host(of: "https://silo.example.com"), "silo.example.com")
        XCTAssertEqual(TVSignInPresentation.qrAccessibilityPrefix(typedURL: "silo.example.com/activate"),
            "Sign-in QR code. Or go to silo.example.com slash activate and enter ")

        func line(_ status: QRLoginViewModel.Status, renewed: Bool = false) -> String? {
            TVSignInPresentation.statusLine(for: status, codeWasRenewed: renewed, serverHost: "silo.example.com")
        }
        // Every state says something, a renewal is announced differently
        // from the first code, the unreachable line names the host, and a
        // sign-in names the account.
        let statuses: [QRLoginViewModel.Status] = [.gettingCode, .waiting, .opened, .approved(account: nil),
            .couldNotFinish, .denied, .paused, .unreachable, .rateLimited, .noDeviceSignIn,
            .updateRequired(message: "u"), .failed(message: "f")]
        for status in statuses {
            XCTAssertFalse(line(status)?.isEmpty ?? true, "\(status) has a status line")
        }
        XCTAssertNotEqual(line(.waiting), line(.waiting, renewed: true))
        XCTAssertTrue(line(.unreachable)?.contains("silo.example.com") == true)
        XCTAssertTrue(line(.approved(account: "laura"))?.contains("laura") == true)
        XCTAssertEqual(line(.updateRequired(message: "Update the server")), "Update the server")

        XCTAssertEqual(TVSignInPresentation.stateAction(for: .couldNotFinish), .tryAgain)
        XCTAssertEqual(TVSignInPresentation.stateAction(for: .unreachable), .tryAgain)
        XCTAssertEqual(TVSignInPresentation.stateAction(for: .denied), .showNewCode)
        XCTAssertEqual(TVSignInPresentation.stateAction(for: .paused), .showNewCode)
        XCTAssertNil(TVSignInPresentation.stateAction(for: .waiting))
        XCTAssertFalse(TVSignInPresentation.actionTakesFocus(.unreachable), "background retries don't steal focus")
        XCTAssertTrue(TVSignInPresentation.actionTakesFocus(.denied))
    }

    // MARK: App link

    func testDeviceLinksCarryTheServerIdentityAddressAndCode() throws {
        let link = try XCTUnwrap(DeviceApprovalLink(url: XCTUnwrap(URL(string:
            "silo://device?server=3f2a9d5e&url=https%3A%2F%2Fsilo.example.com%2F&code=4821-7730"))))
        XCTAssertEqual(link.serverId, "3f2a9d5e")
        XCTAssertEqual(link.serverURL, "https://silo.example.com")
        XCTAssertEqual(link.code, "48217730")
        XCTAssertNil(DeviceApprovalLink(url: try XCTUnwrap(URL(string: "silo://device?code=48217730"))),
            "a bare code means nothing without its server")
        XCTAssertNil(DeviceApprovalLink(url: try XCTUnwrap(URL(string: "silo://device?server=x&url=javascript:alert(1)&code="))))
        XCTAssertNil(DeviceApprovalLink(url: try XCTUnwrap(URL(string: "silo://item/abc?code=1"))))
        let urlOnly = try XCTUnwrap(DeviceApprovalLink(url: XCTUnwrap(URL(string: "silo://device?url=http://10.0.0.2:8090&code=11112222"))))
        XCTAssertNil(urlOnly.serverId)
        XCTAssertEqual(urlOnly.serverURL, "http://10.0.0.2:8090")
    }

    func testDeviceLinksMatchSavedServersByIdentityNotAddress() async throws {
        let home = ServerEntry(id: "home", url: "https://home.example", fetchedName: "Home", profileId: nil,
            lastUsedAt: Date(), verifiedServerId: "srv-home")
        let unverified = ServerEntry(id: "lan", url: "http://192.168.1.4:8090", fetchedName: "Lan", profileId: nil, lastUsedAt: Date())
        func link(_ query: String) throws -> DeviceApprovalLink {
            try XCTUnwrap(DeviceApprovalLink(url: XCTUnwrap(URL(string: "silo://device?\(query)"))))
        }
        let probes: [String: ServerIdentityProbeResult] = [
            "http://192.168.1.4:8090": .identity("srv-lan"),
            "https://new.example": .identity("srv-new"),
            "https://spoof.example": .identity("someone-else"),
        ]
        let probe: (String) async -> ServerIdentityProbeResult = { probes[$0] ?? .unreachable }

        // Saved and verified: its identity wins even when the link's URL differs.
        var match = await DeviceLinkServerMatch.resolve(try link("server=srv-home&url=https://other.example&code=1"),
            signedIn: [unverified, home], probe: probe)
        XCTAssertEqual(match, .saved(home, learnedIdentity: nil))
        // Saved without a recorded identity: learned from its own address.
        match = await DeviceLinkServerMatch.resolve(try link("server=srv-lan&code=1"), signedIn: [home, unverified], probe: probe)
        XCTAssertEqual(match, .saved(unverified, learnedIdentity: "srv-lan"))
        // Unknown server that answers as itself: offer to add it.
        match = await DeviceLinkServerMatch.resolve(try link("server=srv-new&url=https://new.example&code=1"),
            signedIn: [home], probe: probe)
        XCTAssertEqual(match, .addServer(url: "https://new.example"))
        // An address that answers as a different server is refused.
        match = await DeviceLinkServerMatch.resolve(try link("server=srv-new&url=https://spoof.example&code=1"),
            signedIn: [home], probe: probe)
        XCTAssertEqual(match, .mismatch)
        match = await DeviceLinkServerMatch.resolve(try link("server=srv-new&url=https://down.example&code=1"),
            signedIn: [home], probe: probe)
        XCTAssertEqual(match, .unreachable(url: "https://down.example"))
    }

    /// A saved server this device is signed out of (session expired or an
    /// explicit sign-out keeps the entry) is matched, not offered for adding
    /// again from the link's address, which would save it twice.
    func testDeviceLinksMatchSignedOutSavedServers() async throws {
        let home = ServerEntry(id: "home", url: "http://192.168.1.4:8090", fetchedName: "Home", profileId: nil,
            lastUsedAt: Date(), verifiedServerId: "srv-home")
        let unverified = ServerEntry(id: "lan", url: "http://192.168.1.9:8090", fetchedName: "Lan", profileId: nil, lastUsedAt: Date())
        let other = ServerEntry(id: "other", url: "https://other.example", fetchedName: "Other", profileId: nil,
            lastUsedAt: Date(), verifiedServerId: "srv-other")
        func link(_ query: String) throws -> DeviceApprovalLink {
            try XCTUnwrap(DeviceApprovalLink(url: XCTUnwrap(URL(string: "silo://device?\(query)"))))
        }
        let probe: (String) async -> ServerIdentityProbeResult = { url in
            switch url {
            case "http://192.168.1.9:8090": return .identity("srv-lan")
            case "https://home.example": return .identity("srv-home")
            default: return .unreachable
            }
        }

        // Linked under its public URL, saved under a LAN address.
        var match = await DeviceLinkServerMatch.resolve(try link("server=srv-home&url=https://home.example&code=1"),
            signedIn: [other], signedOut: [home], probe: probe)
        XCTAssertEqual(match, .savedSignedOut(home, learnedIdentity: nil))
        // A signed-in entry for the same identity wins over a signed-out one.
        let homeAgain = ServerEntry(id: "home-2", url: "https://home.example", fetchedName: "Home", profileId: nil,
            lastUsedAt: Date(), verifiedServerId: "srv-home")
        match = await DeviceLinkServerMatch.resolve(try link("server=srv-home&url=https://home.example&code=1"),
            signedIn: [homeAgain], signedOut: [home], probe: probe)
        XCTAssertEqual(match, .saved(homeAgain, learnedIdentity: nil))
        // Signed out and without a recorded identity: learned from its address.
        match = await DeviceLinkServerMatch.resolve(try link("server=srv-lan&code=1"),
            signedIn: [other], signedOut: [unverified], probe: probe)
        XCTAssertEqual(match, .savedSignedOut(unverified, learnedIdentity: "srv-lan"))
        // A link without an identity matches a signed-out entry by address.
        match = await DeviceLinkServerMatch.resolve(try link("url=http://192.168.1.4:8090&code=1"),
            signedIn: [], signedOut: [home], probe: probe)
        XCTAssertEqual(match, .savedSignedOut(home, learnedIdentity: nil))
    }

    func testDeviceLinkRoundTripsForASavedServer() throws {
        let home = ServerEntry(id: "home", url: "https://home.example", fetchedName: "Home", profileId: nil,
            lastUsedAt: Date(), verifiedServerId: "srv-home")
        let link = DeviceApprovalLink(server: home, code: "4821 7730")
        let url = try XCTUnwrap(link.url)
        XCTAssertEqual(DeviceApprovalLink(url: url), link)
        XCTAssertEqual(link.code, "48217730")
    }

    // MARK: Nearby sign-in offer

    #if os(iOS)
    func testSignInTVsAreOfferedOnlyForTheirOwnSavedServer() throws {
        let endpoint = NWEndpoint.hostPort(host: "tv.local", port: 7000)
        let loginTV = try XCTUnwrap(TVPairingBrowser.makeTV(
            txt: ["v": "1", "name": "Living Room", "id": "tv-1", "sid": "s1", "st": "login", "srv": "srv-home"],
            endpoint: endpoint))
        XCTAssertEqual(loginTV.state, .login)
        XCTAssertEqual(loginTV.serverIdentity, "srv-home")
        let legacyTV = try XCTUnwrap(TVPairingBrowser.makeTV(txt: ["id": "tv-2"], endpoint: endpoint))
        XCTAssertEqual(legacyTV.state, .setup, "a TV that names no state is a first-run TV")
        XCTAssertEqual(legacyTV.name, "TV", "never assume an Apple TV")
        XCTAssertNil(TVPairingBrowser.makeTV(txt: ["st": "reboot"], endpoint: endpoint), "unknown states are not offered")

        let home = ServerEntry(id: "home", url: "https://home.example", fetchedName: "Home", profileId: nil,
            lastUsedAt: Date(), verifiedServerId: "srv-home")
        let other = ServerEntry(id: "other", url: "https://other.example", fetchedName: "Other", profileId: nil,
            lastUsedAt: Date(), verifiedServerId: "srv-other")
        XCTAssertEqual(CompanionPairingOffer.server(for: loginTV, among: [other, home]), home)
        XCTAssertNil(CompanionPairingOffer.server(for: loginTV, among: [other]), "a phone without the TV's server stays quiet")
        XCTAssertNil(CompanionPairingOffer.server(for: legacyTV, among: [home]), "setup TVs use the chooser")

        // The offer is decided from the signed-in servers alone, so a
        // sign-in TV whose server is saved but signed out is no candidate
        // and never blocks a setup TV behind it.
        XCTAssertNil(CompanionPairingOffer.make(for: loginTV, signedIn: [other]))
        XCTAssertEqual(CompanionPairingOffer.make(for: legacyTV, signedIn: [other]), CompanionPairingOffer(tv: legacyTV, server: nil))
        XCTAssertEqual(CompanionPairingOffer.make(for: loginTV, signedIn: [other, home])?.server, home)
        XCTAssertNil(CompanionPairingOffer.make(for: legacyTV, signedIn: []), "a signed-out phone offers nothing")
    }
    #endif

    // MARK: Approval card

    @MainActor
    func testApprovalCardShowsTheRequestAndFollowsItUntilTheTVSignsIn() async throws {
        let api = FakeTVApprovalAPI()
        let requestedAt = Date(timeIntervalSince1970: 1_767_323_045)
        api.lookups = [
            DeviceLookupResponse(matchCode: "warm pony", deviceName: "Living Room", devicePlatform: "tvos", status: "pending",
                clientPurpose: "device_login", temporary: false, userCode: "4821-7730", ipAddressHint: "192.168.1.x",
                requestedAt: requestedAt, serverId: "srv-home", serverName: "Silo Home"),
            DeviceLookupResponse(matchCode: "warm pony", deviceName: "Living Room", devicePlatform: "tvos", status: "approved"),
            DeviceLookupResponse(matchCode: "warm pony", deviceName: "Living Room", devicePlatform: "tvos", status: "consumed"),
        ]
        let model = TVApprovalModel(server: Self.home, code: "4821 7730", api: api, watchInterval: .milliseconds(10))
        await model.lookUp()
        guard case .review(let request) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(request, TVApprovalRequest(code: "4821 7730", deviceName: "Living Room", platformLabel: "Apple TV",
            serverName: "Silo Home", serverHost: "home.example", accountName: "laura", networkHint: "192.168.1.x",
            requestedAt: requestedAt))
        XCTAssertEqual(api.lookedUpCodes.first, "48217730")

        await model.approve()
        XCTAssertEqual(api.approved, ["48217730"])
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, model.phase != .approved(request, tvSignedIn: true) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.phase, .approved(request, tvSignedIn: true))
        XCTAssertEqual(api.bearerRequests, ["home", "home"], "a fresh bearer before looking up and before approving")
    }

    @MainActor
    func testApprovalCardExplainsEveryWayALookupEnds() async {
        func phase(for result: Result<DeviceLookupResponse, Error>, bearer: ApproverBearer = .token("token")) async -> TVApprovalModel.Phase {
            let api = FakeTVApprovalAPI()
            api.bearerValue = bearer
            if case .success(let lookup) = result { api.lookups = [lookup] }
            if case .failure(let error) = result { api.lookupError = error }
            let model = TVApprovalModel(server: Self.home, code: "48217730", api: api)
            await model.lookUp()
            return model.phase
        }
        func lookup(_ status: String) -> DeviceLookupResponse {
            DeviceLookupResponse(matchCode: "w", deviceName: "TV", devicePlatform: "tvos", status: status)
        }
        let notFound = APIv2Error.problem(APIv2Problem(type: "t", title: "t", status: 404, detail: "", instance: nil, errors: nil))
        var result = await phase(for: .failure(notFound))
        XCTAssertEqual(result, .notFound(serverName: "Home"))
        result = await phase(for: .success(lookup("expired")))
        XCTAssertEqual(result, .expired)
        result = await phase(for: .success(lookup("canceled")))
        XCTAssertEqual(result, .canceled, "the TV stopped waiting; it did not expire")
        result = await phase(for: .success(lookup("denied")))
        XCTAssertEqual(result, .declinedElsewhere)
        result = await phase(for: .success(lookup("consumed")))
        XCTAssertEqual(result, .alreadyUsed)
        result = await phase(for: .success(lookup("pending")), bearer: .rejected)
        XCTAssertEqual(result, .needsSignIn(serverName: "Home"))
        // An outage keeps the session: the card says so and never asks to sign in again.
        result = await phase(for: .success(lookup("pending")), bearer: .providerUnavailable)
        XCTAssertEqual(result, .failed(ExternalSignInError.reasonText("provider_unavailable")))
        result = await phase(for: .success(lookup("pending")), bearer: .unreachable)
        XCTAssertEqual(result, .failed("Couldn't reach Home. Check this device's connection."))
        let outage = APIv2Error.problem(APIv2Problem(type: "https://siloserver.org/docs/api/v2/problems/provider_unavailable",
            title: "t", status: 503, detail: "", instance: nil, errors: nil))
        result = await phase(for: .failure(outage))
        XCTAssertEqual(result, .failed(ExternalSignInError.reasonText("provider_unavailable")))
        var handoff = lookup("pending")
        handoff.temporary = true
        result = await phase(for: .success(handoff))
        XCTAssertEqual(result, .failed("This code isn't for signing in a TV."))
    }

    /// After approving, the card follows the request: a TV that withdraws
    /// it (password sign-in, leaving the screen) reads as stopped waiting,
    /// not as an expired code.
    @MainActor
    func testApprovalCardReportsATVThatStoppedWaiting() async throws {
        let api = FakeTVApprovalAPI()
        api.lookups = [
            DeviceLookupResponse(matchCode: "w", deviceName: "TV", devicePlatform: "tvos", status: "pending"),
            DeviceLookupResponse(matchCode: "w", deviceName: "TV", devicePlatform: "tvos", status: "canceled"),
        ]
        let model = TVApprovalModel(server: Self.home, code: "48217730", api: api, watchInterval: .milliseconds(10))
        await model.lookUp()
        await model.approve()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, model.phase != .canceled {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.phase, .canceled)
    }

    /// The TV gets a session for whoever the approving bearer belongs to.
    /// When the saved session changed after the card was read, approving
    /// sends nothing and shows the card again for the account signed in now.
    @MainActor
    func testApprovalWaitsForAnotherReviewWhenTheAccountChanged() async {
        let api = FakeTVApprovalAPI()
        api.lookups = [DeviceLookupResponse(matchCode: "w", deviceName: "TV", devicePlatform: "tvos", status: "pending")]
        let model = TVApprovalModel(server: Self.home, code: "48217730", api: api)
        await model.lookUp()
        guard case .review(let reviewed) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(reviewed.accountName, "laura")

        api.bearerValue = .token("other-session")
        api.accountNameValue = "maria"
        await model.approve()
        XCTAssertTrue(api.approved.isEmpty)
        guard case .review(let again) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(again.accountName, "maria")

        await model.approve()
        XCTAssertEqual(api.approved, ["48217730"], "the second review was for the account that approves")
    }

    /// A renewed bearer for the same account approves without another review.
    @MainActor
    func testApprovalWithARenewedBearerForTheSameAccountGoesThrough() async {
        let api = FakeTVApprovalAPI()
        api.lookups = [DeviceLookupResponse(matchCode: "w", deviceName: "TV", devicePlatform: "tvos", status: "pending")]
        let model = TVApprovalModel(server: Self.home, code: "48217730", api: api)
        await model.lookUp()
        api.bearerValue = .token("renewed")
        await model.approve()
        XCTAssertEqual(api.approved, ["48217730"])
        guard case .approved = model.phase else { return XCTFail("\(model.phase)") }
    }

    /// An approval whose answer was lost is never reported as failed: the
    /// server may have taken it or still be applying it. The card follows
    /// the request until the server says, and nothing reopens the review
    /// meanwhile.
    @MainActor
    func testLostApprovalAnswerIsFollowedUntilTheServerSays() async throws {
        func approve(after readBack: [String], waitingUpTo wait: TimeInterval = 5,
                     until done: (TVApprovalModel.Phase) -> Bool) async throws -> TVApprovalModel.Phase {
            let api = FakeTVApprovalAPI()
            api.lookups = (["pending"] + readBack).map {
                DeviceLookupResponse(matchCode: "w", deviceName: "TV", devicePlatform: "tvos", status: $0)
            }
            api.approveError = URLError(.networkConnectionLost)
            let model = TVApprovalModel(server: Self.home, code: "48217730", api: api,
                watchInterval: .milliseconds(5), watchLimit: 6)
            await model.lookUp()
            await model.approve()
            guard case .unconfirmed = model.phase else {
                XCTFail("a lost answer is not a failure: \(model.phase)")
                return model.phase
            }
            // A lookup while the outcome is unknown doesn't reopen the review.
            await model.lookUp()
            guard case .unconfirmed = model.phase else {
                XCTFail("the review reopened: \(model.phase)")
                return model.phase
            }
            let deadline = Date().addingTimeInterval(wait)
            while Date() < deadline, !done(model.phase) {
                try await Task.sleep(for: .milliseconds(5))
            }
            model.stop()
            XCTAssertEqual(api.approved.count, 1, "an approval is sent once")
            return model.phase
        }
        var phase = try await approve(after: ["pending", "pending", "approved"]) { Self.isApproved($0) }
        guard case .approved(_, tvSignedIn: false) = phase else { return XCTFail("a late approval lands: \(phase)") }
        phase = try await approve(after: ["consumed"]) { Self.isApproved($0) }
        guard case .approved(_, tvSignedIn: true) = phase else { return XCTFail("\(phase)") }
        phase = try await approve(after: ["expired"]) { $0 == .expired }
        XCTAssertEqual(phase, .expired)
        // Still pending or unreadable once following ends: unconfirmed, never failed.
        phase = try await approve(after: ["pending"], waitingUpTo: 0.3) { _ in false }
        guard case .unconfirmed = phase else { return XCTFail("\(phase)") }
    }

    private static func isApproved(_ phase: TVApprovalModel.Phase) -> Bool {
        if case .approved = phase { return true }
        return false
    }

    /// "Not now" reads as declined only once the server took the denial,
    /// and says so when it could not be sent.
    @MainActor
    func testNotNowDeniesTheRequest() async {
        func declined(bearer: ApproverBearer = .token("token"), denyError: Error? = nil) async -> (TVApprovalModel.Phase, FakeTVApprovalAPI) {
            let api = FakeTVApprovalAPI()
            api.lookups = [DeviceLookupResponse(matchCode: "w", deviceName: "TV", devicePlatform: "androidtv", status: "pending")]
            api.denyError = denyError
            let model = TVApprovalModel(server: Self.home, code: "48217730", api: api)
            await model.lookUp()
            guard case .review(let request) = model.phase else {
                XCTFail("\(model.phase)")
                return (model.phase, api)
            }
            XCTAssertEqual(request.platformLabel, "Android TV")
            api.bearerValue = bearer
            await model.decline()
            return (model.phase, api)
        }
        var (phase, api) = await declined()
        XCTAssertEqual(phase, .declined)
        XCTAssertEqual(api.denied, ["48217730"])
        XCTAssertTrue(api.approved.isEmpty)

        (phase, api) = await declined(bearer: .rejected)
        XCTAssertEqual(phase, .needsSignIn(serverName: "Home"))
        XCTAssertTrue(api.denied.isEmpty)

        (phase, api) = await declined(bearer: .providerUnavailable)
        XCTAssertEqual(phase, .failed(ExternalSignInError.reasonText("provider_unavailable")))
        XCTAssertTrue(api.denied.isEmpty)

        (phase, _) = await declined(denyError: URLError(.notConnectedToInternet))
        guard case .failed = phase else { return XCTFail("a lost denial is not a decline: \(phase)") }
    }

    /// "Not you?" promises an account choice only where the server
    /// advertises `select_account`. A password-only server still reads
    /// "Switch account" (the password form lets the person choose) with the
    /// plain sign-out confirmation; only a provider that could sign the same
    /// person straight back in reads "Sign out".
    @MainActor
    func testNotYouOffersAnAccountChoiceOnlyWhereTheServerAdvertisesIt() async {
        for accountSwitch in [TVApprovalAccountSwitch.chooseAccount, .switchAccount, .signOut] {
            let api = FakeTVApprovalAPI()
            api.accountSwitchValue = accountSwitch
            api.lookups = [DeviceLookupResponse(matchCode: "w", deviceName: "TV", devicePlatform: "tvos", status: "pending")]
            let model = TVApprovalModel(server: Self.home, code: "48217730", api: api)
            XCTAssertEqual(model.accountSwitch, .signOut)
            await model.lookUp()
            XCTAssertEqual(model.accountSwitch, accountSwitch)
            XCTAssertEqual(model.offersAccountChoice, accountSwitch == .chooseAccount)
            XCTAssertEqual(api.choiceQueries, ["https://home.example"])
        }

        let sso = APIv2AuthProvider(id: "plugin:3:oidc", displayName: "SSO", mode: "oauth", default: false,
            iconUrl: nil, installationId: "3", nativeStartPath: "/api/v2/auth/oauth/3/native/start")
        XCTAssertEqual(TVApprovalAccountSwitch(SignInOptions(browserProviders: [sso], acceptsPasswords: true,
            supportsSelectAccount: true)), .chooseAccount)
        XCTAssertEqual(TVApprovalAccountSwitch(SignInOptions(browserProviders: [sso], acceptsPasswords: true,
            supportsSelectAccount: false)), .signOut)
        XCTAssertEqual(TVApprovalAccountSwitch(.passwordOnly), .switchAccount, "password-only or directory-only")
        XCTAssertEqual(TVApprovalAccountSwitch(nil), .signOut, "unread discovery promises nothing")
        #if os(iOS)
        XCTAssertEqual(TVApprovalCard.switchAccountLink(.chooseAccount), "Not you? Switch account")
        XCTAssertEqual(TVApprovalCard.switchAccountLink(.switchAccount), "Not you? Switch account")
        XCTAssertEqual(TVApprovalCard.switchAccountLink(.signOut), "Not you? Sign out")
        XCTAssertTrue(TVApprovalCard.switchAccountMessage(serverName: "Home", choosingAccount: true)
            .contains("asked which account"))
        let plain = TVApprovalCard.switchAccountMessage(serverName: "Home", choosingAccount: false)
        XCTAssertFalse(plain.lowercased().contains("which account"), plain)
        XCTAssertFalse(plain.lowercased().contains("choose"), plain)
        #endif
    }

    /// The TV's password form on a server that lists an OAuth provider says
    /// that those accounts sign in with the phone, and a wrong password says
    /// it again. Android TV shows the same copy.
    func testTVPasswordFormPointsSingleSignOnAccountsToThePhone() {
        let keycloak = APIv2AuthProvider(id: "plugin:3:oidc", displayName: "Sign in with Keycloak", mode: "oauth",
            default: false, iconUrl: nil, installationId: "3")
        let ldap = APIv2AuthProvider(id: "plugin:6:ldap", displayName: "Directory", mode: "credentials", default: false,
            iconUrl: nil, installationId: "6")
        let local = APIv2AuthProvider(id: "local", displayName: "Local", mode: "credentials", default: true)
        func options(_ items: [APIv2AuthProvider]) -> SignInOptions {
            SignInOptions(providers: APIv2AuthProviders(items: items, passwordLogin: true),
                oauth: APIv2OAuthCapabilities(state: "available", native: true))
        }
        // Listed without a start URL the TV could open: still named.
        let hint = TVSignInPresentation.phoneHint(options([local, keycloak]))
        XCTAssertEqual(hint, "If you sign in with Keycloak, use your phone instead.")
        XCTAssertNil(TVSignInPresentation.phoneHint(options([local, ldap])))
        XCTAssertNil(TVSignInPresentation.phoneHint(nil))
        XCTAssertNil(TVSignInPresentation.phoneHint(.passwordOnly))

        let wrong = APIv2Error.problem(APIv2Problem(type: "https://siloserver.org/docs/api/v2/problems/invalid_token",
            title: "t", status: 401, detail: "d", instance: nil, errors: nil))
        XCTAssertEqual(LoginViewModel.message(for: wrong, phoneHint: hint),
            "Incorrect username or password. If you sign in with Keycloak, use your phone instead.")
        XCTAssertEqual(LoginViewModel.message(for: wrong), "Incorrect username or password.")
    }

    #if os(tvOS)
    /// The phone hint shows once: inside the wrong-password message, or as
    /// its own line, never both. On a server without device sign-in the
    /// screen offers no phone route, so neither mentions the phone.
    func testWrongPasswordPointsToThePhoneOnlyOnceAndOnlyWhereTheScreenOffersIt() {
        let keycloak = APIv2AuthProvider(id: "plugin:3:oidc", displayName: "Keycloak", mode: "oauth",
            default: false, iconUrl: nil, installationId: "3")
        let local = APIv2AuthProvider(id: "local", displayName: "Local", mode: "credentials", default: true)
        let wrong = APIv2Error.problem(APIv2Problem(type: "https://siloserver.org/docs/api/v2/problems/invalid_token",
            title: "t", status: 401, detail: "d", instance: nil, errors: nil))
        let hint = "If you sign in with Keycloak, use your phone instead."
        let login = LoginViewModel()
        login.discovery = .loaded(SignInOptions(providers: APIv2AuthProviders(items: [local, keycloak], passwordLogin: true),
            oauth: APIv2OAuthCapabilities(state: "available", native: true)))

        XCTAssertEqual(login.phoneHintLine, hint)
        login.error = FormError(LoginViewModel.message(for: wrong, phoneHint: login.phoneHint))
        XCTAssertEqual(login.error?.message, "Incorrect username or password. \(hint)")
        XCTAssertNil(login.phoneHintLine, "the message already says it")

        // `.noDeviceSignIn`: the screen hides "Use your phone instead".
        login.offersPhoneRoute = false
        login.error = FormError(LoginViewModel.message(for: wrong, phoneHint: login.phoneHint))
        XCTAssertEqual(login.error?.message, "Incorrect username or password.")
        XCTAssertNil(login.phoneHintLine)
    }
    #endif

    private static let home = ServerEntry(id: "home", url: "https://home.example", fetchedName: "Home", profileId: nil,
        lastUsedAt: Date(), verifiedServerId: "srv-home")
}

private final class FakeTVApprovalAPI: TVApprovalAPI, @unchecked Sendable {
    var bearerValue: ApproverBearer = .token("token")
    var lookups: [DeviceLookupResponse] = []
    var lookupError: Error?
    var denyError: Error?
    var approveError: Error?
    var accountNameValue: String? = "laura"
    var accountSwitchValue = TVApprovalAccountSwitch.signOut
    private(set) var choiceQueries: [String] = []
    private(set) var bearerRequests: [String] = []
    private(set) var lookedUpCodes: [String] = []
    private(set) var approved: [String] = []
    private(set) var denied: [String] = []

    func bearer(serverId: String) async -> ApproverBearer {
        bearerRequests.append(serverId)
        return bearerValue
    }

    func lookup(serverURL: String, bearer: String, code: String) async throws -> DeviceLookupResponse {
        lookedUpCodes.append(code)
        if let lookupError { throw lookupError }
        return lookups.count > 1 ? lookups.removeFirst() : lookups[0]
    }

    func approve(serverURL: String, bearer: String, code: String) async throws {
        approved.append(code)
        if let approveError { throw approveError }
    }
    func deny(serverURL: String, bearer: String, code: String) async throws {
        if let denyError { throw denyError }
        denied.append(code)
    }
    func accountName(serverURL: String, bearer: String) async -> String? { accountNameValue }
    func accountSwitch(serverURL: String) async -> TVApprovalAccountSwitch {
        choiceQueries.append(serverURL)
        return accountSwitchValue
    }
}
