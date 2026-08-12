import Foundation

enum ProfileLaunchBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    // Raw value predates the timed options; kept for persisted-state compatibility.
    case askEveryLaunch
    case afterOneHour
    case afterTwelveHours

    var id: String { rawValue }

    /// How long Silo can be away before Who's Watching is shown again.
    /// `nil` for the untimed behaviors.
    var awayTimeout: TimeInterval? {
        switch self {
        case .automatic, .askEveryLaunch:
            return nil
        case .afterOneHour:
            return 3600
        case .afterTwelveHours:
            return 43200
        }
    }

    var title: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .askEveryLaunch:
            return "Every Time"
        case .afterOneHour:
            return "After 1 Hour"
        case .afterTwelveHours:
            return "After 12 Hours"
        }
    }

    var standardDescription: String {
        switch self {
        case .automatic:
            return "Use the last profile selected on this device. A protected profile can reopen without asking for its PIN."
        case .askEveryLaunch:
            return "Show Who's Watching whenever you return to Silo."
        case .afterOneHour:
            return "Show Who's Watching when you've been away from Silo for 1 hour."
        case .afterTwelveHours:
            return "Show Who's Watching when you've been away from Silo for 12 hours."
        }
    }

    var tvDescription: String {
        switch self {
        case .automatic:
            return "Use the profile selected for the current Apple TV user. A protected profile can reopen without asking for its PIN."
        case .askEveryLaunch, .afterOneHour, .afterTwelveHours:
            return standardDescription
        }
    }
}
