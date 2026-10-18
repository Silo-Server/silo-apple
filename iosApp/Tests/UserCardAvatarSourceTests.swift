#if !os(tvOS)
import XCTest
@testable import Silo

/// User cards draw the profiles of each user's last server, which is often
/// not the active one, so an avatar stored as a path must load from that
/// server.
final class UserCardAvatarSourceTests: XCTestCase {
    private func profile(image: String? = nil, emoji: String? = nil) -> SavedSignInProfile {
        SavedSignInProfile(id: "p1", name: "Jamie", avatarEmoji: emoji, avatarImageUrl: image,
                           hasPin: false, isChild: false)
    }

    func testPathLoadsFromTheCardsServer() {
        XCTAssertEqual(
            UserCardAvatarSource.imageURL(for: profile(image: "/api/v2/profiles/p1/avatar"),
                                          serverAddress: "https://friend.example/"),
            "https://friend.example/api/v2/profiles/p1/avatar"
        )
        XCTAssertEqual(
            UserCardAvatarSource.imageURL(for: profile(emoji: "avatars/cat.png"), serverAddress: "https://friend.example"),
            "https://friend.example/avatars/cat.png"
        )
    }

    func testPathWithoutAKnownServerDrawsTheInitial() {
        XCTAssertNil(UserCardAvatarSource.imageURL(for: profile(image: "/api/v2/profiles/p1/avatar"), serverAddress: nil))
    }

    func testAbsoluteURLAndPresetLoadAsTheyAre() {
        XCTAssertEqual(
            UserCardAvatarSource.imageURL(for: profile(image: "https://cdn.example/a.webp"), serverAddress: "https://home.example"),
            "https://cdn.example/a.webp"
        )
        let preset = UserCardAvatarSource.imageURL(for: profile(emoji: "preset:dicebear:adventurer:jamie"),
                                                   serverAddress: "https://home.example")
        XCTAssertEqual(preset.flatMap(URL.init(string:))?.host, "api.dicebear.com")
    }

    func testVectorAvatarFallsBackToTheProfilesPreset() {
        let url = UserCardAvatarSource.imageURL(
            for: profile(image: "/avatars/jamie.svg", emoji: "preset:dicebear:adventurer:jamie"),
            serverAddress: "https://home.example"
        )
        XCTAssertEqual(url.flatMap(URL.init(string:))?.host, "api.dicebear.com")
    }

    func testEmojiAndUploadRefsDrawWithoutAnImage() {
        XCTAssertNil(UserCardAvatarSource.imageURL(for: profile(emoji: "🦊"), serverAddress: "https://home.example"))
        XCTAssertEqual(UserCardAvatarSource.displayEmoji("🦊"), "🦊")
        // An upload ref only loads through the server's avatar_url.
        XCTAssertNil(UserCardAvatarSource.imageURL(for: profile(emoji: "upload:abc"), serverAddress: "https://home.example"))
        XCTAssertNil(UserCardAvatarSource.displayEmoji("upload:abc"))
        XCTAssertEqual(UserCardAvatarSource.initial(of: "  jamie"), "J")
        XCTAssertEqual(UserCardAvatarSource.initial(of: " "), "?")
    }
}
#endif
