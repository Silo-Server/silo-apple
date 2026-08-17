import Foundation

/// Record of a remote-trailer handoff to the YouTube app on tvOS, persisted
/// so a cold launch can put the user back on the detail page they left from.
///
/// tvOS has no way to programmatically return from the YouTube app, so the
/// warm path relies on the system keeping Silo suspended. This record exists
/// solely to survive the one case that breaks: Silo is jetsammed while the
/// trailer plays, and the user relaunches into Home with the detail page gone.
struct TrailerReturnRecord: Codable, Equatable {
    let contentId: String
    /// Identity at handoff time. A record from another server or profile is
    /// never honored — restoring it would surface one profile's browsing to
    /// another on a shared living-room device.
    let serverId: String
    let profileId: String
    let savedAt: Date
}

/// Pure decision rule for honoring a persisted handoff record, kept free of
/// SwiftUI and platform conditionals (like `TrailerRail`) so it is testable
/// headless from the iOS test bundle.
enum TrailerReturnPolicy {
    /// How long a handoff record stays eligible for cold-launch restore.
    ///
    /// The record covers exactly one story: "I was watching a trailer and
    /// came back." Thirty minutes comfortably exceeds a trailer plus some
    /// YouTube drift while staying well inside the same sitting — an older
    /// record restored the next day reads as a bug, and on a shared device
    /// quietly reveals what someone else was browsing. Erring short is
    /// cheap: the user just lands on Home, which is today's behavior.
    static let maxRecordAge: TimeInterval = 30 * 60

    /// Whether a persisted record should restore its detail page now.
    ///
    /// Age is the last line of defense, not the primary guard: identity must
    /// match exactly, and a clock that has gone backwards (negative age)
    /// invalidates rather than extends the record.
    static func shouldRestore(
        record: TrailerReturnRecord,
        now: Date,
        activeServerId: String?,
        activeProfileId: String?
    ) -> Bool {
        guard record.serverId == activeServerId,
              record.profileId == activeProfileId else {
            return false
        }
        let age = now.timeIntervalSince(record.savedAt)
        return age >= 0 && age <= maxRecordAge
    }
}
