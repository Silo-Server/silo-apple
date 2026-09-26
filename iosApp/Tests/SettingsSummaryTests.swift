import Foundation
import XCTest
@testable import Silo

/// The iOS overview and the macOS settings list both label the account row,
/// the Subtitles row and the Version row from `SettingsSummary`.
final class SettingsSummaryTests: XCTestCase {
    func testDisplayNamePrefersProfileThenUsernameThenPrompt() {
        XCTAssertEqual(summary(profile: "Kids", user: "alice").displayName, "Kids")
        XCTAssertEqual(summary(profile: "", user: "alice").displayName, "alice")
        XCTAssertEqual(summary(profile: nil, user: "alice").displayName, "alice")
        XCTAssertEqual(summary(profile: "", user: "").displayName, "Switch Profile")
        XCTAssertEqual(summary(profile: nil, user: nil).displayName, "Switch Profile")
    }

    func testSubtitleLineCombinesUsernameAndHostOnlyWhenDistinct() {
        XCTAssertEqual(
            summary(profile: "Kids", user: "alice", server: "https://silo.example:8443").subtitleLine,
            "alice · silo.example"
        )
        XCTAssertEqual(
            summary(profile: nil, user: "alice", server: "https://silo.example").subtitleLine,
            "silo.example",
            "a username that is already the display name is not repeated"
        )
        XCTAssertEqual(summary(profile: "Kids", user: "alice", server: "").subtitleLine, "alice")
        XCTAssertEqual(summary(profile: nil, user: nil, server: "").subtitleLine, "Tap to switch profile")
    }

    func testServerHostFallsBackToRawStringWhenUnparseable() {
        XCTAssertEqual(summary(server: "https://silo.example:8443/base").serverHost, "silo.example")
        XCTAssertEqual(summary(server: "silo.local").serverHost, "silo.local")
        XCTAssertNil(summary(server: "").serverHost)
    }

    func testVersionStringOmitsEmptyOrDuplicateBuild() {
        XCTAssertEqual(
            SettingsSummary.versionString(infoDictionary: ["CFBundleShortVersionString": "2.1", "CFBundleVersion": "48"]),
            "2.1 (48)"
        )
        XCTAssertEqual(
            SettingsSummary.versionString(infoDictionary: ["CFBundleShortVersionString": "2.1", "CFBundleVersion": "2.1"]),
            "2.1"
        )
        XCTAssertEqual(
            SettingsSummary.versionString(infoDictionary: ["CFBundleShortVersionString": "2.1", "CFBundleVersion": ""]),
            "2.1"
        )
        XCTAssertEqual(SettingsSummary.versionString(infoDictionary: nil), "1.0")
    }

    func testSubtitleLanguageNameShowsNoneForTheOffSentinel() {
        XCTAssertEqual(SettingsSummary.subtitleLanguageName(PlaybackPrefSentinel.none), "None")
        XCTAssertEqual(SettingsSummary.subtitleLanguageName(""), "None")
    }

    private func summary(
        profile: String? = nil,
        user: String? = nil,
        server: String = "https://silo.example"
    ) -> SettingsSummary {
        SettingsSummary(profileName: profile, username: user, serverURL: server)
    }
}
