import SwiftUI

/// On-view description translation for an item detail page.
///
/// A page can be missing up to two translations in the profile's metadata
/// language: its own description (`pending_translation_language` on the
/// detail), and, on a series page, the selected season's episode
/// descriptions (`pending_translation_language` on episode rows). Season and
/// episode links open the series page with that season selected, so the
/// series page is where both appear. The season's job translates the season
/// and its episodes, so one job covers every episode row on show.
///
/// The server's `on_view` mode decides the UX: `auto` starts each missing
/// translation once per item and language while the page is on screen;
/// `button` offers a Translate action. Either way a failed run can be retried.
extension ItemDetailViewModel {
    struct DescriptionTranslationTargets: Hashable {
        /// The page's own description.
        var item: DescriptionTranslationCoordinator.Key?
        /// The selected season, when one of its episode rows is missing its
        /// description. Series pages only.
        var season: DescriptionTranslationCoordinator.Key?

        var isEmpty: Bool { item == nil && season == nil }

        static func make(
            detail: ItemDetail?,
            selectedSeason: Season?,
            episodes: [EpisodeListItem]
        ) -> DescriptionTranslationTargets {
            guard let detail else { return DescriptionTranslationTargets() }
            var targets = DescriptionTranslationTargets()
            if let language = detail.pendingTranslationLanguage, !language.isEmpty {
                targets.item = .init(contentId: detail.contentId, targetLanguage: language)
            }
            if detail.type == "series", let season = selectedSeason,
               let language = episodes.first(where: {
                   $0.seasonNumber == season.seasonNumber && $0.pendingTranslationLanguage?.isEmpty == false
               })?.pendingTranslationLanguage {
                targets.season = .init(contentId: season.contentId, targetLanguage: language)
            }
            return targets
        }
    }

    var descriptionTranslationTargets: DescriptionTranslationTargets {
        .make(detail: detail, selectedSeason: selectedSeason, episodes: episodes)
    }

    /// True while a translation for this page's item or selected season runs.
    var isTranslatingDescriptions: Bool {
        isTranslating(descriptionTranslation, contentId: detail?.contentId)
            || isTranslating(seasonDescriptionTranslation, contentId: selectedSeason?.contentId)
    }

    /// True while the page's own description translates.
    var isTranslatingItemDescription: Bool {
        isTranslating(descriptionTranslation, contentId: detail?.contentId)
    }

    /// True while the selected season's episode descriptions translate.
    var isTranslatingSeasonEpisodes: Bool {
        isTranslating(seasonDescriptionTranslation, contentId: selectedSeason?.contentId)
    }

    /// What to show under the page's own description. Only the item's own
    /// run counts: a season job leaves an already localized series overview
    /// and its label alone, as web does.
    var descriptionTranslationStatus: DescriptionTranslationStatus? {
        .resolve(
            translating: isTranslatingItemDescription,
            machineTranslatedFields: detail?.machineTranslatedFields
        )
    }

    /// Whether to offer an explicit Translate action: in `button` mode while
    /// something on the page is missing, and in either mode after a run for
    /// a missing translation failed.
    var offersDescriptionTranslation: Bool {
        let mode = AICapabilities.shared.metadataOnView
        guard mode != .off, !isTranslatingDescriptions else { return false }
        let targets = descriptionTranslationTargets
        guard !targets.isEmpty else { return false }
        if mode == .button { return true }
        return targets.item.map(descriptionTranslation.hasFailed) == true
            || targets.season.map(seasonDescriptionTranslation.hasFailed) == true
    }

    /// The `auto` mode: start each missing translation once per item and
    /// language. Call whenever the targets or the mode change.
    func autoTranslateDescriptions() {
        guard AICapabilities.shared.metadataOnView == .auto else { return }
        startDescriptionTranslations(automatic: true)
    }

    /// The Translate action.
    func translateDescriptions() {
        guard AICapabilities.shared.metadataOnView != .off else { return }
        startDescriptionTranslations(automatic: false)
    }

    /// Stop polling when the page leaves the screen. A cancelled automatic
    /// run starts again when the page comes back and still reports the
    /// language missing.
    func cancelDescriptionTranslation() {
        descriptionTranslation.cancel()
        seasonDescriptionTranslation.cancel()
    }

    private func isTranslating(_ coordinator: DescriptionTranslationCoordinator, contentId: String?) -> Bool {
        coordinator.phase == .translating && contentId != nil && coordinator.key?.contentId == contentId
    }

    private func startDescriptionTranslations(automatic: Bool) {
        let targets = descriptionTranslationTargets
        // A run for another item or season (the user picked another season,
        // or tvOS reused this view model) no longer shows on the page.
        for (coordinator, key) in [(descriptionTranslation, targets.item), (seasonDescriptionTranslation, targets.season)]
        where coordinator.isRunning && coordinator.key != key {
            coordinator.cancel()
        }
        if let key = targets.item {
            let fetch = itemTranslationFetch(key)
            let apply = itemTranslationApply(key)
            if automatic {
                descriptionTranslation.translateAutomatically(key, fetch: fetch, apply: apply)
            } else {
                descriptionTranslation.translate(key, fetch: fetch, apply: apply)
            }
        }
        if let key = targets.season, let seriesId = loadedSeriesContentId,
           let seasonNumber = selectedSeason?.seasonNumber {
            let fetch = seasonTranslationFetch(seriesId: seriesId, seasonNumber: seasonNumber)
            let apply = seasonTranslationApply(seriesId: seriesId, seasonNumber: seasonNumber)
            if automatic {
                seasonDescriptionTranslation.translateAutomatically(key, fetch: fetch, apply: apply)
            } else {
                seasonDescriptionTranslation.translate(key, fetch: fetch, apply: apply)
            }
        }
    }

    // MARK: Item

    private func itemTranslationFetch(_ key: DescriptionTranslationCoordinator.Key) -> @MainActor () async -> ItemDetail? {
        { [libraryId] in
            try? await SiloAPI.shared.itemDetail(contentId: key.contentId, libraryId: libraryId)
        }
    }

    private func itemTranslationApply(_ key: DescriptionTranslationCoordinator.Key) -> @MainActor (ItemDetail) -> Bool {
        { [weak self] refreshed in
            // The page moved on to another item (tvOS reuses view models):
            // nothing here shows this item any more.
            guard let self, self.detail?.contentId == key.contentId else { return true }
            // Through the view model's generation gate, so a detail load
            // still suspended in enrichment can't land its pre-translation
            // copy on top of this one.
            self.publishRefetchedDetail(refreshed, contentId: key.contentId)
            return refreshed.pendingTranslationLanguage == nil
        }
    }

    // MARK: Season episodes

    private func seasonTranslationFetch(seriesId: String, seasonNumber: Int) -> @MainActor () async -> EpisodesResponse? {
        { [libraryId] in
            try? await SiloAPI.shared.episodes(seriesId: seriesId, seasonNumber: seasonNumber, libraryId: libraryId)
        }
    }

    private func seasonTranslationApply(seriesId: String, seasonNumber: Int) -> @MainActor (EpisodesResponse) -> Bool {
        { [weak self] response in
            guard let self else { return true }
            self.publishTranslatedEpisodes(response, seriesId: seriesId, seasonNumber: seasonNumber)
            return !response.episodes.contains { $0.pendingTranslationLanguage?.isEmpty == false }
        }
    }
}

/// Starts the page's automatic translations whenever what is missing, or the
/// server's on-view mode, changes, and stops polling when the page leaves.
struct DescriptionTranslationTrigger: ViewModifier {
    let viewModel: ItemDetailViewModel

    private struct TriggerID: Hashable {
        let targets: ItemDetailViewModel.DescriptionTranslationTargets
        let mode: MetadataAIStatus.OnViewMode
    }

    func body(content: Content) -> some View {
        content
            .task(id: TriggerID(
                targets: viewModel.descriptionTranslationTargets,
                mode: AICapabilities.shared.metadataOnView
            )) {
                viewModel.autoTranslateDescriptions()
            }
            .onDisappear { viewModel.cancelDescriptionTranslation() }
    }
}

extension View {
    func descriptionTranslation(_ viewModel: ItemDetailViewModel) -> some View {
        modifier(DescriptionTranslationTrigger(viewModel: viewModel))
    }
}
