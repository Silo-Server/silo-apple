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
}
