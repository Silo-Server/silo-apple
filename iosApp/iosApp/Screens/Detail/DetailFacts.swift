import Foundation

/// One row of the "Details" key/value block.
struct DetailFact {
    let label: String
    let value: String
}

/// Shared assembly of the "Details" rows (crew, studios, networks,
/// countries, dates) used by both `PhoneDetailFactsSection` and
/// `TVDetailFactsSection`. Only the visual layout differs between the
/// two; the data and its ordering are identical.
enum DetailFacts {
    static let maxCreditNames = 3

    static func assemble(from detail: ItemDetail) -> [DetailFact] {
        var facts: [DetailFact] = []

        if let directors = creditNames(from: detail, forJobs: ["Director"]), !directors.isEmpty {
            facts.append(DetailFact(label: "Director", value: directors))
        }
        if let writers = creditNames(from: detail, forJobs: ["Writer", "Screenplay", "Story"]), !writers.isEmpty {
            facts.append(DetailFact(label: writerLabel(for: detail), value: writers))
        }
        if let studios = detail.studios, !studios.isEmpty {
            facts.append(DetailFact(label: "Studio", value: studios.prefix(3).joined(separator: ", ")))
        }
        if let networks = detail.networks, !networks.isEmpty {
            facts.append(DetailFact(label: "Network", value: networks.prefix(3).joined(separator: ", ")))
        }
        if let countries = detail.countries, !countries.isEmpty {
            facts.append(DetailFact(label: "Country", value: countries.prefix(3).joined(separator: ", ")))
        }
        if let airDate = DetailDateFormatting.longDate(detail.airDate) {
            facts.append(DetailFact(label: "Aired", value: airDate))
        }
        if let releaseDate = DetailDateFormatting.longDate(detail.releaseDate) {
            facts.append(DetailFact(label: "Released", value: releaseDate))
        }
        if let firstAired = DetailDateFormatting.longDate(detail.firstAirDate) {
            facts.append(DetailFact(label: "First Aired", value: firstAired))
        }
        if let lastAired = DetailDateFormatting.longDate(detail.lastAirDate) {
            facts.append(DetailFact(label: "Last Aired", value: lastAired))
        }
        return facts
    }

    static func writerLabel(for detail: ItemDetail) -> String {
        let hasScreenplay = detail.crew?.contains { $0.job?.lowercased() == "screenplay" } ?? false
        return hasScreenplay ? "Writer" : "Written by"
    }

    /// Runtime label used by the episode rails/rows on phone and tvOS
    /// ("1h 4m" / "42m").
    static func episodeRuntime(minutes: Int) -> String {
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }

    static func creditNames(from detail: ItemDetail, forJobs jobs: [String]) -> String? {
        guard let crew = detail.crew else { return nil }
        let lowered = jobs.map { $0.lowercased() }
        let names = crew
            .filter { member in
                guard let job = member.job?.lowercased() else { return false }
                return lowered.contains(job)
            }
            .map(\.name)
        if names.isEmpty { return nil }
        let trimmed = Array(Set(names)).sorted()
        let joined = trimmed.prefix(maxCreditNames).joined(separator: ", ")
        return trimmed.count > maxCreditNames ? "\(joined), …" : joined
    }
}
