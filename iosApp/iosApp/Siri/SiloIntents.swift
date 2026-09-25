#if os(iOS) || os(tvOS)
import AppIntents

/// Siri's in-app search. On Apple TV, a short press of the Siri button while
/// Silo is open, or "Search in Silo", routes the spoken term here.
///
/// tvOS has no `.system.search` schema macro, so both platforms conform to
/// `ShowInAppSearchResultsIntent` directly. The protocol already runs the
/// intent in the app's foreground process.
struct SearchInSiloIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Search Silo"
    static let description = IntentDescription("Opens Search in Silo with your search term.")
    static let searchScopes: [StringSearchScope] = [.general, .movies, .tv]

    @Parameter(title: "Search Term", requestValueDialog: "What do you want to search for?")
    var criteria: StringSearchCriteria

    @MainActor
    func perform() async throws -> some IntentResult {
        SiriLink.search(term: criteria.term).deliver()
        return .result()
    }
}

/// "Play Dune in Silo" for any title, through Apple's own video grammar.
/// Plays the one library title that matches, or opens Search for the title
/// when several match or none does. On iPhone, a TV already under remote
/// control takes the playback, as a Play tap would.
struct PlayInSiloIntent: PlayVideoIntent {
    static let title: LocalizedStringResource = "Play in Silo"
    static let description = IntentDescription("Plays a movie or series from your Silo library.")
    static let supportedCategories: [VideoCategory] = [.movies, .tv]

    @Parameter(title: "Title", requestValueDialog: "What do you want to play?")
    var term: String

    @MainActor
    func perform() async throws -> some IntentResult {
        SiriLink.play(title: term, onTV: false).deliver()
        return .result()
    }
}

/// "Play The End of Oak Street with Silo". Siri knows the titles in
/// `SiriTitleCatalog` by name; any other title said after "Play something
/// on Silo" is looked up in the library, and Siri asks which one when
/// several match.
struct PlayTitleIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Title"
    static let description = IntentDescription("Plays a movie or series from your Silo library.")
    static let openAppWhenRun = true

    @Parameter(title: "Title", requestValueDialog: "What do you want to play?")
    var title: SiloTitleEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        SiriLink.playTitle(contentId: title.id, title: title.title, isSeries: title.isSeries, onTV: false).deliver()
        return .result()
    }
}

#if os(iOS)
/// "Play The End of Oak Street on my TV with Silo": `PlayTitleIntent`, then
/// playback on a Silo Apple TV.
struct PlayOnTVIntent: AppIntent {
    static let title: LocalizedStringResource = "Play on TV"
    static let description = IntentDescription("Plays a movie or series from your Silo library on a Silo Apple TV.")
    static let openAppWhenRun = true

    @Parameter(title: "Title", requestValueDialog: "What do you want to play on your TV?")
    var title: SiloTitleEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        SiriLink.playTitle(contentId: title.id, title: title.title, isSeries: title.isSeries, onTV: true).deliver()
        return .result()
    }
}
#endif

struct SiloAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // Each phrase naming a title counts once per title in the catalog
        // toward Apple's 1,000-phrase limit; see `SiriTitleCatalog.limit`.
        AppShortcut(
            intent: PlayTitleIntent(),
            phrases: [
                "Play \(\.$title) with \(.applicationName)",
                "Play \(\.$title) on \(.applicationName)",
                "Play \(\.$title) in \(.applicationName)",
                "Watch \(\.$title) on \(.applicationName)",
                "Watch \(\.$title) with \(.applicationName)",
                "Resume \(\.$title) on \(.applicationName)",
                "Continue \(\.$title) on \(.applicationName)",
                "Play something on \(.applicationName)",
                "Play something with \(.applicationName)",
                "Watch something on \(.applicationName)",
            ],
            shortTitle: "Play",
            systemImageName: "play.fill"
        )
        #if os(iOS)
        AppShortcut(
            intent: PlayOnTVIntent(),
            phrases: [
                "Play \(\.$title) on my TV with \(.applicationName)",
                "Play \(\.$title) on TV with \(.applicationName)",
                "Watch \(\.$title) on my TV with \(.applicationName)",
                "Play on TV with \(.applicationName)",
                "Play on my TV with \(.applicationName)",
                "Play on Apple TV with \(.applicationName)",
            ],
            shortTitle: "Play on TV",
            systemImageName: "tv"
        )
        #endif
        AppShortcut(
            intent: PlayInSiloIntent(),
            phrases: ["Play in \(.applicationName)"],
            shortTitle: "Play by Name",
            systemImageName: "text.magnifyingglass"
        )
        AppShortcut(
            intent: SearchInSiloIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Search in \(.applicationName)",
            ],
            shortTitle: "Search",
            systemImageName: "magnifyingglass"
        )
    }
}

extension SiriLink {
    @MainActor
    func deliver() {
        guard let url else { return }
        SiloDeepLinkCoordinator.shared.receive(url)
    }
}
#endif
