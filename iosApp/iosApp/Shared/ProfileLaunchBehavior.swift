import Foundation

enum ProfileLaunchBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case askEveryLaunch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .askEveryLaunch:
            return "Ask Every Time"
        }
    }

    var standardDescription: String {
        switch self {
        case .automatic:
            return "Use the last profile selected on this device. A protected profile can reopen without asking for its PIN."
        case .askEveryLaunch:
            return "Show Who's Watching when Silo starts."
        }
    }

    var tvDescription: String {
        switch self {
        case .automatic:
            return "Use the profile selected for the current Apple TV user. A protected profile can reopen without asking for its PIN."
        case .askEveryLaunch:
            return "Show Who's Watching when Silo starts."
        }
    }
}
