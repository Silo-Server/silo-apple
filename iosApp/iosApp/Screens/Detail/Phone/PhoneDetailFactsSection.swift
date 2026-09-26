import SwiftUI

#if !os(tvOS)

/// "Details" key/value list rendered below the hero. Mirrors
/// `TVDetailFactsSection` — same data sources (crew, studios, networks,
/// dates) — but laid out as a phone-friendly inset list with thin
/// dividers and tight rows.
struct PhoneDetailFactsSection: View {
    let detail: ItemDetail

    var body: some View {
        let facts = DetailFacts(detail: detail).assembleFacts()
        if !facts.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(facts.enumerated()), id: \.element.label) { index, fact in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 1)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        Text(fact.label.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.2)
                            .foregroundColor(.siloOnSurface.opacity(0.5))
                            .frame(width: 100, alignment: .leading)
                        Text(fact.value)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(.siloOnSurface)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif

struct DetailFacts {
    let detail: ItemDetail
    private let maxCreditNames = 3

    struct Fact {
        let label: String
        let value: String
    }

    func assembleFacts() -> [Fact] {
        if let audiobook = detail.audiobook {
            return audiobookFacts(audiobook)
        }
        var facts: [Fact] = []

        if let directors = creditNames(forJobs: ["Director"]), !directors.isEmpty {
            facts.append(Fact(label: "Director", value: directors))
        }
        if let writers = creditNames(forJobs: ["Writer", "Screenplay", "Story"]), !writers.isEmpty {
            facts.append(Fact(label: writerLabel, value: writers))
        }
        if let studios = detail.studios, !studios.isEmpty {
            facts.append(Fact(label: "Studio", value: studios.prefix(3).joined(separator: ", ")))
        }
        if let networks = detail.networks, !networks.isEmpty {
            facts.append(Fact(label: "Network", value: networks.prefix(3).joined(separator: ", ")))
        }
        if let countries = detail.countries, !countries.isEmpty {
            facts.append(Fact(label: "Country", value: countries.prefix(3).joined(separator: ", ")))
        }
        if let airDate = DetailDateFormatting.longDate(detail.airDate) {
            facts.append(Fact(label: "Aired", value: airDate))
        }
        if let releaseDate = DetailDateFormatting.longDate(detail.releaseDate) {
            facts.append(Fact(label: "Released", value: releaseDate))
        }
        if let firstAired = DetailDateFormatting.longDate(detail.firstAirDate) {
            facts.append(Fact(label: "First Aired", value: firstAired))
        }
        if let lastAired = DetailDateFormatting.longDate(detail.lastAirDate) {
            facts.append(Fact(label: "Last Aired", value: lastAired))
        }
        return facts
    }

    /// Book facts replace the film credits: who wrote and read it, who
    /// published it, how long it runs, and the file format.
    private func audiobookFacts(_ audiobook: AudiobookDetail) -> [Fact] {
        var facts: [Fact] = []
        let authors = audiobook.authors.map(\.name)
        if let names = AudiobookDetailFormatting.peopleSummary(authors, visible: maxCreditNames) {
            facts.append(Fact(label: personCount(authors) > 1 ? "Authors" : "Author", value: names))
        }
        let narrators = audiobook.narrators.map(\.name)
        if let names = AudiobookDetailFormatting.peopleSummary(narrators, visible: maxCreditNames) {
            facts.append(Fact(label: personCount(narrators) > 1 ? "Narrators" : "Narrator", value: names))
        }
        if let publisher = audiobook.publisher?.trimmingCharacters(in: .whitespaces), !publisher.isEmpty {
            facts.append(Fact(label: "Publisher", value: publisher))
        }
        if let releaseDate = DetailDateFormatting.longDate(detail.releaseDate) {
            facts.append(Fact(label: "Released", value: releaseDate))
        } else if let year = detail.year, year > 0 {
            facts.append(Fact(label: "Released", value: String(year)))
        }
        let length = PlayerTimeFormatter.formatRuntime(BookDetailPresentation.totalDurationSeconds(of: detail))
        if !length.isEmpty {
            facts.append(Fact(label: "Length", value: length))
        }
        if let format = audiobookFormat {
            facts.append(Fact(label: "Format", value: format))
        }
        return facts
    }

    /// Servers sometimes send several people as one comma-joined name, so
    /// count the names the way `peopleSummary` splits them.
    private func personCount(_ names: [String]) -> Int {
        names
            .flatMap { $0.components(separatedBy: ",") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    /// "AAC · M4B · 3 parts", from the first part's codec and container.
    private var audiobookFormat: String? {
        let parts = AudiobookPlaybackContext.audioParts(of: detail)
        guard let primary = parts.first else { return nil }
        var tokens: [String] = []
        if let codec = primary.codecAudio, !codec.isEmpty {
            tokens.append(codec.uppercased())
        }
        if let container = primary.container, !container.isEmpty {
            tokens.append(container.uppercased())
        }
        if parts.count > 1 {
            tokens.append("\(parts.count) parts")
        }
        return tokens.isEmpty ? nil : tokens.joined(separator: " · ")
    }

    private var writerLabel: String {
        let hasScreenplay = detail.crew?.contains { $0.job?.lowercased() == "screenplay" } ?? false
        return hasScreenplay ? "Writer" : "Written by"
    }

    private func creditNames(forJobs jobs: [String]) -> String? {
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
