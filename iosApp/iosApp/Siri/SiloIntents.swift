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

/// "Play Dune in Silo". Plays the one library title that matches, or opens
/// Search for the title when several match or none does. On iPhone, a TV
/// already under remote control takes the playback, as a Play tap would.
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

#if os(iOS)
/// "Play on TV with Silo": the same title lookup as `PlayInSiloIntent`, then
/// playback on a Silo Apple TV. App Shortcut phrases can't carry free text,
/// so Siri asks for the title after the phrase.
struct PlayOnTVIntent: AppIntent {
    static let title: LocalizedStringResource = "Play on TV"
    static let description = IntentDescription("Plays a movie or series from your Silo library on a Silo Apple TV.")
    static let openAppWhenRun = true

    @Parameter(title: "Title", requestValueDialog: "What do you want to play on your TV?")
    var term: String

    @MainActor
    func perform() async throws -> some IntentResult {
        SiriLink.play(title: term, onTV: true).deliver()
        return .result()
    }
}
#endif

struct SiloAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayInSiloIntent(),
            phrases: [
                "Play in \(.applicationName)",
                "Play something in \(.applicationName)",
            ],
            shortTitle: "Play",
            systemImageName: "play.fill"
        )
        #if os(iOS)
        AppShortcut(
            intent: PlayOnTVIntent(),
            phrases: [
                "Play on TV with \(.applicationName)",
                "Play on my TV with \(.applicationName)",
                "Play on Apple TV with \(.applicationName)",
            ],
            shortTitle: "Play on TV",
            systemImageName: "tv"
        )
        #endif
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
