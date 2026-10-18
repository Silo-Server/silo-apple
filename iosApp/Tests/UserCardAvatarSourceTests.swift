import XCTest
@testable import Silo

/// User cards draw the profiles of each user's last server, which is often
/// not the active one, so an avatar stored as a path must load from that
/// server (`ProfileAvatar`, shared with Who's Watching).
final class UserCardAvatarSourceTests: XCTestCase {
    private func profile(name: String = "Jamie", image: String? = nil, emoji: String? = nil) -> SavedSignInProfile {
        SavedSignInProfile(id: "p1", name: name, avatarEmoji: emoji, avatarImageUrl: image,
                           hasPin: false, isChild: false)
    }

    private func imageURL(_ profile: SavedSignInProfile, on serverURL: String?) -> String? {
        ProfileAvatarResolver.imageURL(avatarImageUrl: profile.avatarImageUrl, avatarEmoji: profile.avatarEmoji,
                                       serverURL: serverURL)
    }

    func testPathLoadsFromTheCardsServer() {
        XCTAssertEqual(
            imageURL(profile(image: "/api/v2/profiles/p1/avatar"), on: "https://friend.example/"),
            "https://friend.example/api/v2/profiles/p1/avatar"
        )
        XCTAssertEqual(
            imageURL(profile(emoji: "avatars/cat.png"), on: "https://friend.example"),
            "https://friend.example/avatars/cat.png"
        )
    }

    func testPathWithoutAKnownServerDrawsTheInitial() {
        XCTAssertNil(imageURL(profile(image: "/api/v2/profiles/p1/avatar"), on: nil), "no server, no guess")
        XCTAssertNil(imageURL(profile(emoji: "avatars/cat.png"), on: nil), "never the active server")
    }

    func testAbsoluteURLAndPresetLoadAsTheyAre() {
        XCTAssertEqual(imageURL(profile(image: "https://cdn.example/a.webp?sig=1"), on: "https://home.example"),
                       "https://cdn.example/a.webp?sig=1")
        let preset = imageURL(profile(emoji: "preset:dicebear:adventurer:jamie"), on: "https://home.example")
        XCTAssertEqual(preset.flatMap(URL.init(string:))?.host, "api.dicebear.com")
    }

    func testVectorAvatarFallsBackToThePresetOrEmoji() {
        let url = imageURL(profile(image: "/avatars/jamie.svg", emoji: "preset:dicebear:adventurer:jamie"),
                           on: "https://home.example")
        XCTAssertEqual(url.flatMap(URL.init(string:))?.host, "api.dicebear.com")
        let fox = profile(image: "/avatars/fox.svg", emoji: "🦊")
        XCTAssertNil(imageURL(fox, on: "https://home.example"))
        XCTAssertEqual(ProfileAvatarResolver.emoji(fox.avatarEmoji), "🦊")
    }

    func testEmojiAndUploadRefsDrawWithoutAnImage() {
        XCTAssertNil(imageURL(profile(emoji: "🦊"), on: "https://home.example"))
        XCTAssertEqual(ProfileAvatarResolver.emoji("🦊"), "🦊")
        // An upload ref only loads through the server's avatar_url.
        XCTAssertNil(imageURL(profile(emoji: "upload:abc"), on: "https://home.example"))
        XCTAssertNil(ProfileAvatarResolver.emoji("upload:abc"))
        XCTAssertEqual(ProfileAvatarResolver.initial(of: "  jamie"), "J")
        XCTAssertEqual(ProfileAvatarResolver.initial(of: " "), "?")
    }
}
