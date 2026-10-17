import Foundation

/// What Silo asks for when Profile Selection requires a selection and the
/// device has more than one Silo user.
enum ProfileLaunchAskFor: String, Codable, CaseIterable, Identifiable, Sendable {
    case profileOnly
    case userAndProfile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profileOnly:
            return "Profile Only"
        case .userAndProfile:
            return "User + Profile"
        }
    }

    var description: String {
        switch self {
        case .profileOnly:
            return "Show Who's Watching for this Apple TV user's Silo user."
        case .userAndProfile:
            return "Choose a user first when this Apple TV has more than one."
        }
    }

    /// Shown with the dimmed setting under Automatic, which never asks.
    static let inactiveUnderAutomaticFooter = "Applies when Silo asks who's watching."
}
