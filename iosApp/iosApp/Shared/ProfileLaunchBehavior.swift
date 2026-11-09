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

    var title: LocalizedStringResource {
        switch self {
        case .automatic:
            return .settingsProfileLaunchAutomatic
        case .askEveryLaunch:
            return .settingsProfileLaunchAskEveryLaunch
        case .afterOneHour:
            return .settingsProfileLaunchAfterOneHour
        case .afterTwelveHours:
            return .settingsProfileLaunchAfterTwelveHours
        }
    }

    var standardDescription: LocalizedStringResource {
        switch self {
        case .automatic:
            return .settingsProfileLaunchAutomaticDetailPhone
        case .askEveryLaunch:
            return .settingsProfileLaunchAskEveryLaunchDetail
        case .afterOneHour:
            return .settingsProfileLaunchAfterOneHourDetail
        case .afterTwelveHours:
            return .settingsProfileLaunchAfterTwelveHoursDetail
        }
    }

    var tvDescription: LocalizedStringResource {
        switch self {
        case .automatic:
            return .settingsProfileLaunchAutomaticDetailAppleTv
        case .askEveryLaunch, .afterOneHour, .afterTwelveHours:
            return standardDescription
        }
    }
}
