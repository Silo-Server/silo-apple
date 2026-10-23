import Foundation

// App-only: `UserProfile` isn't compiled into the Top Shelf extension,
// which shares `SavedSignInProfile`.
extension SavedSignInProfile {
    /// The parts of a server profile a user card draws.
    init(_ profile: UserProfile) {
        self.init(
            id: profile.id,
            name: profile.name,
            avatarEmoji: profile.avatarEmoji,
            avatarImageUrl: profile.avatarImageUrl,
            hasPin: profile.hasPin,
            isChild: profile.isChild
        )
    }
}
