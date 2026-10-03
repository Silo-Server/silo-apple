import Foundation

/// One person card in a detail page's "Cast & Crew" row. Cast and crew both
/// render through this shape so every card shares the same size and tap
/// behaviour.
struct CastCrewEntry: Identifiable, Hashable {
    /// Unique across the whole row, so a director who also acts gets two
    /// distinct cards and tvOS focus can tell them apart.
    let id: String
    let name: String
    /// Line under the name: the crew role, or the cast member's character.
    let caption: String?
    let personId: String?
    let photoUrl: String?
    let photoThumbhash: String?
}

/// A run of cards in the "Cast & Crew" row. Every group after the first is
/// preceded by a thin divider carrying `dividerLabel`.
struct CastCrewGroup: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case lead
        case writers
        case cast
    }

    let kind: Kind
    /// Label for the divider drawn before this group, or nil when the group
    /// is the first one shown and so has no divider.
    let dividerLabel: String?
    let entries: [CastCrewEntry]

    var id: Kind { kind }
}

/// Builds the movie and series "Cast & Crew" row: the director (or series
/// creator) first, then writers, then the main cast. Mirrors the web
/// client's `buildCrewGroups` so every Silo client shows the same people.
enum CastCrewGroups {
    /// Caption for the lead group. Silo stores series creators as Director
    /// credits, so series pages relabel them.
    enum LeadRole: String {
        case director = "Director"
        case creator = "Creator"
    }

    static let maxLeads = 2
    static let maxWriters = 3
    static let maxCast = 12
    /// Cap for the cast-only rail on season and episode pages, which keeps
    /// their original behaviour.
    static let maxCastOnlyEntries = 24

    static let writersLabel = "Writers"
    static let castLabel = "Cast"

    /// Lowercased job names. Matching is case-insensitive and keeps the same
    /// writer roles the Details list showed before credits moved into the row.
    private static let leadJobs: Set<String> = ["director"]
    private static let writerJobs: Set<String> = ["writer", "screenplay", "story"]

    /// Groups for a movie or series. Empty groups are dropped, and the first
    /// remaining group carries no divider label.
    static func build(
        cast: [CastMember]?,
        crew: [CrewMember]?,
        leadRole: LeadRole
    ) -> [CastCrewGroup] {
        let crew = crew ?? []

        let leads = uniqueCrew(crew.filter { hasJob($0, in: leadJobs) })
            .prefix(maxLeads)
        // A writer-director already has a card in the lead group. Exclude
        // against every director credit, not just the capped ones, to match
        // the web client.
        let leadKeys = Set(crew.filter { hasJob($0, in: leadJobs) }.map(personKey))
        let writers = uniqueCrew(
            crew.filter { hasJob($0, in: writerJobs) && !leadKeys.contains(personKey($0)) }
        )
        .prefix(maxWriters)
        let castMembers = sortedCast(cast ?? []).prefix(maxCast)

        let candidates: [(CastCrewGroup.Kind, String, [CastCrewEntry])] = [
            (.lead, leadRole.rawValue, leads.map { crewEntry($0, kind: .lead, caption: leadRole.rawValue) }),
            (.writers, writersLabel, writers.map { crewEntry($0, kind: .writers, caption: "Writer") }),
            (.cast, castLabel, castMembers.map { castEntry($0) }),
        ]
        return assemble(candidates)
    }

    /// A single cast group with no divider, in the order the server sent,
    /// for season and episode pages.
    static func castOnly(_ cast: [CastMember]) -> [CastCrewGroup] {
        let entries = cast.prefix(maxCastOnlyEntries).map { castEntry($0) }
        return entries.isEmpty ? [] : [CastCrewGroup(kind: .cast, dividerLabel: nil, entries: entries)]
    }

    // MARK: - Helpers

    private static func hasJob(_ member: CrewMember, in jobs: Set<String>) -> Bool {
        guard let job = member.job?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return jobs.contains(job)
    }

    private static func assemble(
        _ candidates: [(CastCrewGroup.Kind, String, [CastCrewEntry])]
    ) -> [CastCrewGroup] {
        var groups: [CastCrewGroup] = []
        for (kind, label, entries) in candidates where !entries.isEmpty {
            groups.append(CastCrewGroup(
                kind: kind,
                dividerLabel: groups.isEmpty ? nil : label,
                entries: entries
            ))
        }
        return groups
    }

    /// Person id when the server has one, otherwise the name.
    private static func personKey(_ member: CrewMember) -> String {
        if let personId = member.personId, !personId.isEmpty { return personId }
        return member.name
    }

    private static func uniqueCrew(_ crew: [CrewMember]) -> [CrewMember] {
        var seen = Set<String>()
        return crew.filter { seen.insert(personKey($0)).inserted }
    }

    /// Billing order ascending. Members without an order go last, and equal
    /// orders keep the sequence the server sent.
    private static func sortedCast(_ cast: [CastMember]) -> [CastMember] {
        cast.enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.order, rhs.element.order) {
                case let (left?, right?) where left != right:
                    return left < right
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                default:
                    return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    private static func crewEntry(
        _ member: CrewMember,
        kind: CastCrewGroup.Kind,
        caption: String
    ) -> CastCrewEntry {
        CastCrewEntry(
            id: "\(kind.rawValue)-\(personKey(member))",
            name: member.name,
            caption: caption,
            personId: member.personId,
            photoUrl: member.photoUrl,
            photoThumbhash: member.photoThumbhash
        )
    }

    private static func castEntry(_ member: CastMember) -> CastCrewEntry {
        CastCrewEntry(
            id: "\(CastCrewGroup.Kind.cast.rawValue)-\(member.id)",
            name: member.name,
            caption: member.character,
            personId: member.personId,
            photoUrl: member.photoUrl,
            photoThumbhash: member.photoThumbhash
        )
    }
}
