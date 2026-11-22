import SwiftUI

#if !os(tvOS)

/// "Details" key/value list rendered below the hero. Mirrors
/// `TVDetailFactsSection` — same data sources (crew, studios, networks,
/// dates) — but laid out as a phone-friendly inset list with thin
/// dividers and tight rows.
struct PhoneDetailFactsSection: View {
    let detail: ItemDetail

    @Environment(\.locale) private var locale

    var body: some View {
        PhoneDetailFactList(facts: DetailFacts(detail: detail).assembleFacts(locale: locale))
    }
}

/// The rows of a facts list: a capitalized label beside its value, with a
/// thin divider between rows.
struct PhoneDetailFactList: View {
    let facts: [DetailFacts.Fact]
    /// VoiceOver reads each row in one stop, as "label, value".
    var readsRowsWhole = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    /// The label column grows with its text so "FIRST AIRED" and "NARRATORS"
    /// keep their default line breaks at larger text sizes.
    @ScaledMetric(relativeTo: .caption2) private var labelWidth: CGFloat = 100

    var body: some View {
        if !facts.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 1)
                    }
                    row(fact)
                        .padding(.vertical, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func row(_ fact: DetailFacts.Fact) -> some View {
        if readsRowsWhole {
            factRow(fact)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: fact.value.isEmpty ? fact.label : "\(fact.label), \(fact.value)"))
        } else {
            factRow(fact)
        }
    }

    /// Label beside value; at accessibility sizes a side column would leave
    /// the value a few words per line, so the label sits above it instead.
    @ViewBuilder
    private func factRow(_ fact: DetailFacts.Fact) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                label(fact)
                value(fact)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .top, spacing: 16) {
                label(fact)
                    .frame(width: labelWidth, alignment: .leading)
                value(fact)
            }
        }
    }

    private func label(_ fact: DetailFacts.Fact) -> some View {
        Text(fact.label.uppercased(with: locale))
            .siloScaledFont(size: 11, weight: .bold, relativeTo: .caption2)
            .tracking(1.2)
            .foregroundColor(.siloOnSurface.opacity(0.5))
    }

    private func value(_ fact: DetailFacts.Fact) -> some View {
        Text(fact.value)
            .siloScaledFont(size: 14, relativeTo: .subheadline)
            .foregroundColor(.siloOnSurface)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Labels come out in the language `locale` shows; a view passes its `\.locale`.
    func assembleFacts(locale: Locale = AppLanguage.displayedLocale) -> [Fact] {
        if let audiobook = detail.audiobook {
            return audiobookFacts(audiobook, locale: locale)
        }
        func label(_ resource: LocalizedStringResource) -> String {
            AppLanguage.string(resource, locale: locale)
        }
        var facts: [Fact] = []

        // Crew jobs are matched against the server's English job names.
        if let directors = creditNames(forJobs: ["Director"]), !directors.isEmpty {
            facts.append(Fact(label: label(.detailDirector), value: directors))
        }
        if let writers = creditNames(forJobs: ["Writer", "Screenplay", "Story"]), !writers.isEmpty {
            facts.append(Fact(label: label(writerLabel), value: writers))
        }
        if let studios = detail.studios, !studios.isEmpty {
            facts.append(Fact(label: label(.detailStudio), value: studios.prefix(3).joined(separator: ", ")))
        }
        if let networks = detail.networks, !networks.isEmpty {
            facts.append(Fact(label: label(.detailNetwork), value: networks.prefix(3).joined(separator: ", ")))
        }
        if let countries = detail.countries, !countries.isEmpty {
            facts.append(Fact(label: label(.detailCountry), value: countries.prefix(3).joined(separator: ", ")))
        }
        if let airDate = DetailDateFormatting.longDate(detail.airDate) {
            facts.append(Fact(label: label(.detailAired), value: airDate))
        }
        if let releaseDate = DetailDateFormatting.longDate(detail.releaseDate) {
            facts.append(Fact(label: label(.detailReleased), value: releaseDate))
        }
        if let firstAired = DetailDateFormatting.longDate(detail.firstAirDate) {
            facts.append(Fact(label: label(.detailFirstAired), value: firstAired))
        }
        if let lastAired = DetailDateFormatting.longDate(detail.lastAirDate) {
            facts.append(Fact(label: label(.detailLastAired), value: lastAired))
        }
        return facts
    }

    /// Book facts replace the film credits: who wrote and read it, who
    /// published it, how long it runs, and the file format.
    private func audiobookFacts(_ audiobook: AudiobookDetail, locale: Locale) -> [Fact] {
        func label(_ resource: LocalizedStringResource) -> String {
            AppLanguage.string(resource, locale: locale)
        }
        var facts: [Fact] = []
        let authors = audiobook.authors.map(\.name)
        if let names = AudiobookDetailFormatting.peopleSummary(authors, visible: maxCreditNames) {
            facts.append(Fact(label: label(.detailFactsAuthor(count: personCount(authors))), value: names))
        }
        let narrators = audiobook.narrators.map(\.name)
        if let names = AudiobookDetailFormatting.peopleSummary(narrators, visible: maxCreditNames) {
            facts.append(Fact(label: label(.detailFactsNarrator(count: personCount(narrators))), value: names))
        }
        if let publisher = audiobook.publisher?.trimmingCharacters(in: .whitespaces), !publisher.isEmpty {
            facts.append(Fact(label: label(.detailFactsPublisher), value: publisher))
        }
        if let releaseDate = DetailDateFormatting.longDate(detail.releaseDate) {
            facts.append(Fact(label: label(.detailReleased), value: releaseDate))
        } else if let year = detail.year, year > 0 {
            facts.append(Fact(label: label(.detailReleased), value: LocaleFormat.integer(year, locale: locale)))
        }
        let length = PlayerTimeFormatter.formatRuntime(BookDetailPresentation.totalDurationSeconds(of: detail))
        if !length.isEmpty {
            facts.append(Fact(label: label(.detailFactsLength), value: length))
        }
        if let format = audiobookFormat(locale: locale) {
            facts.append(Fact(label: label(.detailFactsFormat), value: format))
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
    private func audiobookFormat(locale: Locale) -> String? {
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
            tokens.append(AppLanguage.string(.detailAudiobookPartCount(count: parts.count, LocaleFormat.integer(parts.count, locale: locale)), locale: locale))
        }
        return tokens.isEmpty ? nil : tokens.joined(separator: " · ")
    }

    private var writerLabel: LocalizedStringResource {
        let hasScreenplay = detail.crew?.contains { $0.job?.lowercased() == "screenplay" } ?? false
        return hasScreenplay ? .detailWriter : .detailWrittenBy
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
