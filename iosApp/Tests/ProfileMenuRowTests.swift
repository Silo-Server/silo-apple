import XCTest
@testable import Silo

final class ProfileMenuRowTests: XCTestCase {
    /// The avatar menu's profile row by the open account's profile count and
    /// profile limit.
    func testRowFollowsProfileCountAndLimit() {
        typealias Row = (profiles: Int, limit: Int?, handoff: Bool, expected: ProfileMenuRow?)
        let rows: [Row] = [
            // Several profiles: there is someone to switch to, even at the limit.
            (2, 5, false, .switchProfile),
            (2, 2, false, .switchProfile),
            (5, nil, false, .switchProfile),
            // One profile and room for another.
            (1, 5, false, .addProfile),
            (1, 2, false, .addProfile),
            // One profile and a server that didn't send the limit: creating
            // a profile stays the server's check.
            (1, nil, false, .addProfile),
            // One profile and no room: nothing to switch to or add.
            (1, 1, false, nil),
            (1, 0, false, nil),
            // No profile list read yet: the picker, as before.
            (0, nil, false, .switchProfile),
            (0, 1, false, .switchProfile),
            // A remote-playback handoff can neither switch nor add.
            (1, nil, true, nil),
            (2, 5, true, nil),
        ]

        for row in rows {
            XCTAssertEqual(
                ProfileMenuRow.row(profileCount: row.profiles, profileLimit: row.limit, isHandoffSession: row.handoff),
                row.expected,
                "\(row.profiles) profiles, limit \(row.limit.map(String.init) ?? "unknown"), handoff \(row.handoff)"
            )
        }
    }

    /// Add Profile opens its form only for the open profile, so it can never
    /// change who is watching.
    func testAddProfileStartsOnlyForTheOpenProfile() {
        let open = UserProfile(id: "p-open", name: "Open", avatarEmoji: nil, hasPin: true, isChild: false)
        let other = UserProfile(id: "p-other", name: "Other", avatarEmoji: nil, hasPin: false, isChild: false)

        XCTAssertEqual(
            AddProfileRequest.start(profiles: [open], openProfileID: "p-open"),
            .form(AddProfileRequest(primary: open))
        )
        // The row was drawn from an older list: several profiles means the
        // picker, as Switch Profile opens it.
        XCTAssertEqual(AddProfileRequest.start(profiles: [open, other], openProfileID: "p-open"), .picker)
        // The only listed profile isn't the open one, or nothing is open.
        XCTAssertEqual(AddProfileRequest.start(profiles: [other], openProfileID: "p-open"), .unavailable)
        XCTAssertEqual(AddProfileRequest.start(profiles: [open], openProfileID: nil), .unavailable)
        // No list could be read.
        XCTAssertEqual(AddProfileRequest.start(profiles: [], openProfileID: "p-open"), .unavailable)
    }

    /// The PIN prompt and the form belong to the profile that was open when
    /// Add Profile was chosen. A route change closes them, including Home
    /// committed again under another account or profile.
    @MainActor
    func testAddProfileFormClosesOnAnyRouteChange() {
        let open = UserProfile(id: "p-open", name: "Open", avatarEmoji: nil, hasPin: true, isChild: false)
        let router = AppRouter()
        router.sessionOwner = { nil }
        router.setAuthState(.authenticated, reason: "test")

        router.addProfileRequest = AddProfileRequest(primary: open)
        router.setAuthState(.authenticated, reason: "test")
        XCTAssertNil(router.addProfileRequest)

        router.addProfileRequest = AddProfileRequest(primary: open)
        router.setAuthState(.needsLogin, reason: "test")
        XCTAssertNil(router.addProfileRequest)
    }

    /// After a create, the picker shows unless a fresh list positively shows
    /// that nothing was added.
    func testPickerShowsAfterACreateUnlessAFreshListHoldsOneProfile() {
        XCTAssertTrue(AddProfileRequest.showsPicker(afterCreateWith: 2))
        XCTAssertTrue(AddProfileRequest.showsPicker(afterCreateWith: 5))
        // The list could not be read: the profile was, or may have been, created.
        XCTAssertTrue(AddProfileRequest.showsPicker(afterCreateWith: nil))
        XCTAssertFalse(AddProfileRequest.showsPicker(afterCreateWith: 1))
    }
}
