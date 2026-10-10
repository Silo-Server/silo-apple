import Foundation

/// On-view description translation for the card a hero shows: the Mac's
/// Featured hero slide and the tvOS marquee's focused card. Only Featured
/// cards start a translation on view, as on web; the marquee shows a landed
/// translation for any card.
///
/// Section cards carry `pending_translation_language` when their description
/// is missing in the profile's metadata language. Only the card on show
/// translates: `auto` mode starts its job once per item and language when it
/// comes on screen, and `button` mode offers a Translate action. While a job
/// runs, the card's item detail is re-read until it no longer reports the
/// language missing (or ~45 s pass), and the localized text then replaces the
/// card's for as long as this profile's identity lasts, so the hero shows it
/// without reloading the whole section.
@MainActor
@Observable
final class CardDescriptionTranslation {
    static let shared = CardDescriptionTranslation()

    /// A card's text after its translation landed.
    struct Localized: Equatable {
        let overview: String?
        let machineTranslatedFields: [String]?
    }

    /// What a hero shows for one card.
    struct Presentation: Equatable {
        let overview: String?
        let status: DescriptionTranslationStatus?
        /// The language to translate into, while the card's description is
        /// still missing in it.
        let pendingLanguage: String?
    }

    private(set) var localized: [String: Localized] = [:]
    /// One coordinator per item, so a run keeps going while the hero moves
    /// on to the next card; each run ends on its own within its cap.
    @ObservationIgnored private var coordinators: [String: DescriptionTranslationCoordinator] = [:]
    /// Coordinator lookups are not observed, so views re-read through this.
    private var revision = 0
    private let makeCoordinator: @MainActor () -> DescriptionTranslationCoordinator
    private let fetchDetail: @MainActor (String, Int?) async -> ItemDetail?
    private let onViewMode: @MainActor () -> MetadataAIStatus.OnViewMode

    init(
        makeCoordinator: @escaping @MainActor () -> DescriptionTranslationCoordinator = { DescriptionTranslationCoordinator() },
        fetchDetail: @escaping @MainActor (String, Int?) async -> ItemDetail? = { contentId, libraryId in
            try? await SiloAPI.shared.itemDetail(contentId: contentId, libraryId: libraryId)
        },
        onViewMode: @escaping @MainActor () -> MetadataAIStatus.OnViewMode = { AICapabilities.shared.metadataOnView }
    ) {
        self.makeCoordinator = makeCoordinator
        self.fetchDetail = fetchDetail
        self.onViewMode = onViewMode
    }

    /// The text, status and pending language a hero shows for a card.
    func presentation(
        contentId: String?,
        overview: String?,
        pendingLanguage: String?,
        machineTranslatedFields: [String]?
    ) -> Presentation {
        _ = revision
        guard let contentId else {
            return Presentation(overview: overview, status: nil, pendingLanguage: nil)
        }
        if let localized = localized[contentId] {
            return Presentation(
                overview: localized.overview ?? overview,
                status: .resolve(translating: false, machineTranslatedFields: localized.machineTranslatedFields),
                pendingLanguage: nil
            )
        }
        let pending = pendingLanguage?.isEmpty == false ? pendingLanguage : nil
        let translating = pending.map {
            coordinators[contentId]?.isTranslating(.init(contentId: contentId, targetLanguage: $0)) == true
        } ?? false
        return Presentation(
            overview: overview,
            status: .resolve(translating: translating, machineTranslatedFields: machineTranslatedFields),
            pendingLanguage: pending
        )
    }

    func presentation(for item: SectionItem) -> Presentation {
        presentation(
            contentId: item.contentId,
            overview: item.overview,
            pendingLanguage: item.pendingTranslationLanguage,
            machineTranslatedFields: item.machineTranslatedFields
        )
    }

    /// Whether to offer Translate for a card: `button` mode, or after a run
    /// failed, while its description is missing and nothing runs for it.
    func offersTranslation(contentId: String?, pendingLanguage: String?) -> Bool {
        _ = revision
        let mode = onViewMode()
        guard mode != .off, let contentId, localized[contentId] == nil,
              let language = pendingLanguage, !language.isEmpty else { return false }
        let key = DescriptionTranslationCoordinator.Key(contentId: contentId, targetLanguage: language)
        if coordinators[contentId]?.isTranslating(key) == true { return false }
        return mode == .button || coordinators[contentId]?.hasFailed(key) == true
    }

    /// The card came on screen: in `auto` mode, translate it once per item
    /// and language.
    func cardDidAppear(contentId: String?, pendingLanguage: String?, libraryId: Int?) {
        guard onViewMode() == .auto else { return }
        start(contentId: contentId, pendingLanguage: pendingLanguage, libraryId: libraryId, automatic: true)
    }

    /// The Translate action for a card.
    func translate(contentId: String?, pendingLanguage: String?, libraryId: Int?) {
        guard onViewMode() != .off else { return }
        start(contentId: contentId, pendingLanguage: pendingLanguage, libraryId: libraryId, automatic: false)
    }

    /// Drop every localized text and stop every run: the profile, account
    /// or metadata language changed.
    func reset() {
        for coordinator in coordinators.values { coordinator.reset() }
        coordinators.removeAll()
        localized.removeAll()
        revision &+= 1
    }

    private func start(contentId: String?, pendingLanguage: String?, libraryId: Int?, automatic: Bool) {
        guard let contentId, localized[contentId] == nil,
              let language = pendingLanguage, !language.isEmpty else { return }
        let coordinator = coordinators[contentId] ?? {
            let made = makeCoordinator()
            coordinators[contentId] = made
            return made
        }()
        let key = DescriptionTranslationCoordinator.Key(contentId: contentId, targetLanguage: language)
        let fetch: @MainActor () async -> ItemDetail? = { [fetchDetail] in
            await fetchDetail(contentId, libraryId)
        }
        let apply: @MainActor (ItemDetail) -> Bool = { [weak self] detail in
            guard detail.pendingTranslationLanguage == nil else { return false }
            ResponseCache.shared.set(detail, for: CacheKey.itemDetail(contentId, libraryId: libraryId))
            self?.localized[contentId] = Localized(
                overview: detail.overview,
                machineTranslatedFields: detail.machineTranslatedFields
            )
            return true
        }
        let started = automatic
            ? coordinator.translateAutomatically(key, fetch: fetch, apply: apply)
            : coordinator.translate(key, fetch: fetch, apply: apply)
        if started { revision &+= 1 }
    }
}
