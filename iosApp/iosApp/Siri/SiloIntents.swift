#if os(iOS) || os(tvOS)
import AppIntents

/// Siri's in-app search. On Apple TV, a short press of the Siri button while
/// Silo is open, or "Search in Silo", routes the spoken term here.
///
/// tvOS has no `.system.search` schema macro, so both platforms conform to
/// `ShowInAppSearchResultsIntent` directly. The protocol already runs the
/// intent in the app's foreground process.
struct SearchInSiloIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "shell.siri.searchTitle"
    static let description = IntentDescription("shell.siri.searchDescription")
    static let searchScopes: [StringSearchScope] = [.general, .movies, .tv]

    @Parameter(title: "shell.siri.searchTerm", requestValueDialog: "shell.siri.searchPrompt")
    var criteria: StringSearchCriteria

    @MainActor
    func perform() async throws -> some IntentResult {
        if let url = SiriSearchLink.url(term: criteria.term) {
            SiloDeepLinkCoordinator.shared.receive(url)
        }
        return .result()
    }
}

struct SiloAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchInSiloIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Search in \(.applicationName)",
                "Find something on \(.applicationName)",
            ],
            shortTitle: "shell.siri.searchShortTitle",
            systemImageName: "magnifyingglass"
        )
    }
}
#endif
