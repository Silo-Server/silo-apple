import XCTest
@testable import Silo

/// Several controllers on one TV: the receiver's pure rules and the wire
/// additions that carry them. Every addition is optional, so older peers
/// must keep decoding and never receive a payload they would misread.
final class SiloControlMultiControllerTests: XCTestCase {
    private typealias Policy = SiloControlReceiverPolicy

    // MARK: - Admission

    func testAdmitsBelowTheCap() {
        let existing = (0..<Policy.maxControllers - 1).map { summary(sequence: $0) }
        XCTAssertEqual(Policy.admission(existing: existing), .admit)
    }

    func testAtTheCapEvictsTheOldestConnectionThatNeverSaidHello() {
        var existing = (0..<Policy.maxControllers).map { summary(sequence: $0, passive: true) }
        let silentOld = summary(sequence: -2, hello: false)
        let silentNew = summary(sequence: 99, hello: false)
        existing[3] = silentNew
        existing[5] = silentOld
        XCTAssertEqual(Policy.admission(existing: existing), .admitEvicting(silentOld.id))
    }

    func testAtTheCapEvictsTheOldestPassiveControllerNext() {
        var existing = (0..<Policy.maxControllers).map { summary(sequence: $0) }
        let passiveNew = summary(sequence: 50, passive: true)
        let passiveOld = summary(sequence: 20, passive: true)
        existing[1] = passiveNew
        existing[6] = passiveOld
        XCTAssertEqual(Policy.admission(existing: existing), .admitEvicting(passiveOld.id))
    }

    /// A cross-server controller that isn't handing off can do nothing
    /// else, and nothing times it out, so it goes before passive ones.
    func testAtTheCapEvictsAnIdleCrossServerControllerBeforeAPassiveOne() {
        var existing = (0..<Policy.maxControllers).map { summary(sequence: $0, passive: true) }
        let idle = summary(sequence: 40, authorized: false)
        let handingOff = summary(sequence: 10, authorized: false, handingOff: true)
        existing[2] = idle
        existing[4] = handingOff
        XCTAssertEqual(Policy.admission(existing: existing), .admitEvicting(idle.id))
    }

    func testAtTheCapNeverEvictsAControllerMidHandoff() {
        var existing = (0..<Policy.maxControllers).map { summary(sequence: $0) }
        existing[0] = summary(sequence: 0, authorized: false, handingOff: true)
        existing[1] = summary(sequence: 1, passive: true, handingOff: true)
        XCTAssertEqual(Policy.admission(existing: existing), .refuse)
    }

    /// A stranger never pushes off someone actively using the remote.
    func testAtTheCapRefusesWhenEveryControllerIsActive() {
        let existing = (0..<Policy.maxControllers).map { summary(sequence: $0) }
        XCTAssertEqual(Policy.admission(existing: existing), .refuse)
    }

    // MARK: - Same-device replacement

    func testHelloReplacesOnlyTheSameDevicesOtherConnections() {
        let mine = UUID(), oldMine = UUID(), other = UUID(), preHello = UUID()
        let replaced = Policy.connectionsReplaced(
            byHelloFrom: "phone-a",
            on: mine,
            existing: [(mine, "phone-a"), (oldMine, "phone-a"), (other, "phone-b"), (preHello, nil)]
        )
        XCTAssertEqual(replaced, [oldMine])
    }

    func testAnEmptyDeviceIdReplacesNothing() {
        let mine = UUID(), blank = UUID()
        XCTAssertEqual(
            Policy.connectionsReplaced(byHelloFrom: "", on: mine, existing: [(mine, ""), (blank, "")]),
            []
        )
    }

    // MARK: - Launch readiness

    /// Controller A's readiness must not survive controller B's handoff, or
    /// A's next launch would play under B's profile.
    func testLaunchNeedsReadinessForTheIdentityNowActive() {
        let a = UUID(), b = UUID()
        XCTAssertTrue(Policy.canLaunch(readyGeneration: a, activeGeneration: a))
        XCTAssertFalse(Policy.canLaunch(readyGeneration: a, activeGeneration: b))
        XCTAssertFalse(Policy.canLaunch(readyGeneration: a, activeGeneration: nil))
        XCTAssertFalse(Policy.canLaunch(readyGeneration: nil, activeGeneration: b))
        XCTAssertFalse(Policy.canLaunch(readyGeneration: nil, activeGeneration: nil))
    }

    func testReplacementKeepsOnlyThePlayerThatOwnsTheActiveHandoff() {
        let current = UUID()
        func canReplace(_ player: UUID?, _ active: UUID?, disposed: Bool = false, party: Bool = false) -> Bool {
            Policy.canReplaceInPlayer(
                playerGeneration: player, activeGeneration: active,
                playerIsDisposed: disposed, playerIsWatchParty: party
            )
        }
        XCTAssertTrue(canReplace(current, current))
        XCTAssertFalse(canReplace(current, UUID()), "another profile requires a fresh player")
        XCTAssertFalse(canReplace(nil, current), "a local player does not own the phone's profile")
        XCTAssertFalse(canReplace(current, nil))
        XCTAssertFalse(canReplace(nil, nil))
        XCTAssertFalse(canReplace(current, current, disposed: true))
        XCTAssertFalse(canReplace(current, current, party: true))
    }

    // MARK: - Identity reuse

    func testReuseOnTheConnectionThatCompletedTheHandoff() {
        let connection = UUID()
        XCTAssertTrue(Policy.mayReuseIdentity(
            offerMatchesIdentity: true, identityConnection: connection, connection: connection,
            issuedResumeToken: nil, offeredResumeToken: nil
        ))
    }

    func testReuseFromAnotherConnectionNeedsTheIssuedToken() {
        XCTAssertTrue(Policy.mayReuseIdentity(
            offerMatchesIdentity: true, identityConnection: UUID(), connection: UUID(),
            issuedResumeToken: "abc123", offeredResumeToken: "abc123"
        ))
        XCTAssertFalse(Policy.mayReuseIdentity(
            offerMatchesIdentity: true, identityConnection: UUID(), connection: UUID(),
            issuedResumeToken: "abc123", offeredResumeToken: "abc124"
        ))
        XCTAssertFalse(Policy.mayReuseIdentity(
            offerMatchesIdentity: true, identityConnection: nil, connection: UUID(),
            issuedResumeToken: "abc123", offeredResumeToken: nil
        ))
    }

    /// A peer that copies a phone's self-reported device ID, without its
    /// connection or token, gets a fresh approval instead of the profile.
    func testCopiedDeviceIdAloneNeverReuses() {
        XCTAssertFalse(Policy.mayReuseIdentity(
            offerMatchesIdentity: true, identityConnection: UUID(), connection: UUID(),
            issuedResumeToken: nil, offeredResumeToken: nil
        ))
    }

    func testAnOfferForAnotherIdentityNeverReuses() {
        let connection = UUID()
        XCTAssertFalse(Policy.mayReuseIdentity(
            offerMatchesIdentity: false, identityConnection: connection, connection: connection,
            issuedResumeToken: "abc", offeredResumeToken: "abc"
        ))
    }

    func testResumeTokensAreLongAndUnique() {
        let first = Policy.makeResumeToken(), second = Policy.makeResumeToken()
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(first.allSatisfy(\.isHexDigit))
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Replace confirmation

    func testAsksBeforeReplacingAnotherProfilesTitle() {
        XCTAssertTrue(Policy.needsReplaceConfirmation(
            titleOnScreen: true, playingUnderOfferedProfile: false,
            replaceConfirmed: false, controllerCanConfirm: true
        ))
    }

    func testNoQuestionWhenNothingPlaysTheSameProfilePlaysOrTheUserAgreed() {
        XCTAssertFalse(Policy.needsReplaceConfirmation(
            titleOnScreen: false, playingUnderOfferedProfile: false,
            replaceConfirmed: false, controllerCanConfirm: true
        ))
        XCTAssertFalse(Policy.needsReplaceConfirmation(
            titleOnScreen: true, playingUnderOfferedProfile: true,
            replaceConfirmed: false, controllerCanConfirm: true
        ))
        XCTAssertFalse(Policy.needsReplaceConfirmation(
            titleOnScreen: true, playingUnderOfferedProfile: false,
            replaceConfirmed: true, controllerCanConfirm: true
        ))
    }

    /// Consent names the title the user saw. If someone started another
    /// one while they decided, the TV asks again.
    func testConfirmationCoversOnlyTheTitleTheUserAgreedToReplace() {
        XCTAssertTrue(Policy.confirmationCovers(
            onScreenContentId: "oak", replaceConfirmed: true, replacingContentId: "oak"
        ))
        XCTAssertFalse(Policy.confirmationCovers(
            onScreenContentId: "bobs-film", replaceConfirmed: true, replacingContentId: "oak"
        ))
        XCTAssertFalse(Policy.confirmationCovers(
            onScreenContentId: "oak", replaceConfirmed: false, replacingContentId: "oak"
        ))
    }

    /// Older phones can't show the question, so they keep newest-launch-wins
    /// rather than being unable to launch at all.
    func testControllersThatCantAskKeepTheOlderBehavior() {
        XCTAssertFalse(Policy.needsReplaceConfirmation(
            titleOnScreen: true, playingUnderOfferedProfile: false,
            replaceConfirmed: false, controllerCanConfirm: false
        ))
    }

    // MARK: - Command budget

    func testCommandBudgetAllowsABurstThenRefills() {
        var budget = Policy.CommandBudget()
        let start = Date(timeIntervalSince1970: 1_000)
        for i in 0..<Int(Policy.CommandBudget.burst) {
            XCTAssertTrue(budget.allow(at: start), "command \(i) of the burst")
        }
        XCTAssertFalse(budget.allow(at: start))
        // Half a second refills ten commands at twenty per second.
        let later = start.addingTimeInterval(0.5)
        for _ in 0..<10 { XCTAssertTrue(budget.allow(at: later)) }
        XCTAssertFalse(budget.allow(at: later))
    }

    // MARK: - Wire: hello

    func testHelloCarriesFeaturesPassiveAndClientKind() throws {
        let hello = SiloControlHello(
            role: .phone, deviceName: "Home Assistant", deviceId: "ha-1",
            serverId: "srv", serverName: nil, supportedVersions: [2],
            features: [SiloControlFeature.closeReason, "something_newer"],
            passive: true, clientKind: SiloControlClientKind.integration
        )
        let decoded = try roundTrip(.hello(hello))
        XCTAssertEqual(decoded, .hello(hello))
        XCTAssertTrue(hello.supports(SiloControlFeature.closeReason))
        XCTAssertFalse(hello.supports(SiloControlFeature.multiController))
    }

    /// The hello an older phone sends (Android has no `serverIdentity` either).
    func testOldHelloDecodesWithNoFeatures() throws {
        let json = """
        {"type":"hello","v":2,"hello":{"role":"phone","deviceName":"Pixel","deviceId":"p1",
        "serverId":"srv","serverName":"Home","supportedVersions":[2]}}
        """
        guard case .hello(let hello) = try decode(json) else { return XCTFail("expected hello") }
        XCTAssertNil(hello.features)
        XCTAssertNil(hello.passive)
        XCTAssertFalse(hello.supports(SiloControlFeature.closeReason))
    }

    // MARK: - Wire: close

    /// Older peers get exactly the frame they always got.
    func testBareCloseHasNoPayload() throws {
        let object = try jsonObject(.close(reason: nil))
        XCTAssertEqual(object["type"] as? String, "close")
        XCTAssertNil(object["close"])
    }

    func testCloseReasonRoundTrips() throws {
        let object = try jsonObject(.close(reason: SiloControlCloseReason.replaced))
        XCTAssertEqual((object["close"] as? [String: Any])?["reason"] as? String, "replaced")
        XCTAssertEqual(try roundTrip(.close(reason: "replaced")), .close(reason: "replaced"))
    }

    func testCloseFromAnOlderPeerDecodes() throws {
        XCTAssertEqual(try decode(#"{"type":"close","v":2}"#), .close(reason: nil))
    }

    /// A malformed optional payload must not tear the session down: the
    /// close itself is what matters.
    func testCloseWithAnUnexpectedPayloadStillDecodes() throws {
        XCTAssertEqual(try decode(#"{"type":"close","v":2,"close":{"why":1}}"#), .close(reason: nil))
    }

    // MARK: - Wire: presence

    func testPresenceRoundTrips() throws {
        let object = try jsonObject(.presence(SiloControlPresence(passive: false)))
        XCTAssertEqual(object["type"] as? String, "presence")
        XCTAssertEqual((object["presence"] as? [String: Any])?["passive"] as? Bool, false)
        XCTAssertEqual(try roundTrip(.presence(SiloControlPresence(passive: true))),
                       .presence(SiloControlPresence(passive: true)))
    }

    // MARK: - Wire: handoff

    func testReplaceConfirmationCancelCarriesWhatIsPlaying() throws {
        let cancel = SiloControlHandoffCancel(
            requestId: "r1",
            reason: SiloControlHandoffCancelReason.replaceConfirmationRequired,
            message: "Alex is watching Dune on this TV.",
            nowPlaying: SiloControlNowPlayingSummary(
                contentId: "c1", title: "Dune", subtitle: nil,
                profileName: "Alex", controllerName: "Nathan's iPhone"
            )
        )
        XCTAssertEqual(try roundTrip(.handoffCancel(cancel)), .handoffCancel(cancel))
    }

    func testOldHandoffFramesDecodeWithoutTheNewFields() throws {
        let ready = """
        {"type":"handoff_ready","v":2,"handoffReady":{"requestId":"r1","serverId":"s",
        "profileId":"p","sessionExpiresAt":"2026-10-19T00:00:00Z","reused":false}}
        """
        guard case .handoffReady(let decodedReady) = try decode(ready) else { return XCTFail("expected ready") }
        XCTAssertNil(decodedReady.resumeToken)

        let cancel = """
        {"type":"handoff_cancel","v":2,"handoffCancel":{"requestId":"r1","reason":"handoff_failed"}}
        """
        guard case .handoffCancel(let decodedCancel) = try decode(cancel) else { return XCTFail("expected cancel") }
        XCTAssertNil(decodedCancel.nowPlaying)
    }

    func testOfferCarriesResumeTokenAndConfirmation() throws {
        let offer = SiloControlHandoffOffer(
            requestId: "r2", serverId: "s", serverURL: "https://silo.example", serverName: nil,
            profileId: "p", profileName: "Alex",
            resumeToken: "tok", replaceConfirmed: true, replacingContentId: "oak"
        )
        XCTAssertEqual(try roundTrip(.handoffOffer(offer)), .handoffOffer(offer))
    }

    #if os(tvOS)
    // MARK: - Standby screen

    func testStandbyLabelCountsOtherWaitingControllers() {
        XCTAssertEqual(TVControlStandbyState(controllerName: "Sam's Pixel").controllerLabel, "Sam's Pixel")
        XCTAssertEqual(
            TVControlStandbyState(controllerName: "Sam's Pixel", otherControllerCount: 1).controllerLabel,
            "Sam's Pixel and 1 other device"
        )
        XCTAssertEqual(
            TVControlStandbyState(controllerName: nil, otherControllerCount: 2).controllerLabel,
            "iPhone and 2 other devices"
        )
    }
    #endif

    // MARK: - Helpers

    private func summary(
        sequence: Int, hello: Bool = true, passive: Bool = false,
        authorized: Bool = true, handingOff: Bool = false
    ) -> Policy.ControllerSummary {
        Policy.ControllerSummary(id: UUID(), sequence: sequence, didReceiveHello: hello, passive: passive,
                                 isAuthorized: authorized, isHandingOff: handingOff)
    }

    private func roundTrip(_ message: SiloControlMessage) throws -> SiloControlMessage {
        try JSONDecoder().decode(SiloControlMessage.self, from: JSONEncoder().encode(message))
    }

    private func decode(_ json: String) throws -> SiloControlMessage {
        try JSONDecoder().decode(SiloControlMessage.self, from: Data(json.utf8))
    }

    private func jsonObject(_ message: SiloControlMessage) throws -> [String: Any] {
        let data = try JSONEncoder().encode(message)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
