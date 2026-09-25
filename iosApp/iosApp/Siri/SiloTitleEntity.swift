#if os(iOS) || os(tvOS)
import AppIntents

/// A movie or series Siri can name in Silo's phrases.
struct SiloTitleEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Title"
    static let defaultQuery = SiloTitleQuery()

    let id: String
    let title: String
    let year: Int?
    let isSeries: Bool

    init(_ title: SiriTitleCatalog.Title) {
        self.id = title.contentId
        self.title = title.title
        self.year = title.year
        self.isSeries = title.isSeries
    }

    var displayRepresentation: DisplayRepresentation {
        if let year {
            return DisplayRepresentation(title: "\(title)", subtitle: "\(String(year))")
        }
        return DisplayRepresentation(title: "\(title)")
    }
}

struct SiloTitleQuery: EntityStringQuery {
    /// The titles Siri learns for its phrases.
    func suggestedEntities() async throws -> [SiloTitleEntity] {
        SiriTitleCatalog.titles().map(SiloTitleEntity.init)
    }

    /// Titles Siri already resolved, such as a phrase's value or a saved
    /// shortcut. One that has left the list is looked up again.
    func entities(for identifiers: [SiloTitleEntity.ID]) async throws -> [SiloTitleEntity] {
        let known = Dictionary(
            SiriTitleCatalog.titles().map { ($0.contentId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result: [SiloTitleEntity] = []
        for id in identifiers {
            if let title = known[id] {
                result.append(SiloTitleEntity(title))
            } else if let detail = try? await SiloAPI.shared.itemDetail(contentId: id) {
                result.append(SiloTitleEntity(SiriTitleCatalog.Title(
                    contentId: detail.contentId,
                    title: detail.title,
                    year: detail.year,
                    isSeries: SiloMediaType.isSeries(detail.type)
                )))
            }
        }
        return result
    }

    /// A title said after Siri asks "What do you want to play?". Several
    /// matches let Siri ask which one.
    func entities(matching string: String) async throws -> [SiloTitleEntity] {
        try await SiriPlaybackResolver.live.search(string)
            .filter { SiloMediaType.isSeries($0.type) || SiloMediaType.isMovieLibrary($0.type) }
            .prefix(10)
            .map {
                SiloTitleEntity(SiriTitleCatalog.Title(
                    contentId: $0.contentId,
                    title: $0.title,
                    year: $0.year,
                    isSeries: SiloMediaType.isSeries($0.type)
                ))
            }
    }
}
#endif
