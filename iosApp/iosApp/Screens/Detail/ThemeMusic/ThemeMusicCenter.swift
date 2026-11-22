import Foundation

/// What the open title page reports to theme music. Pages send a fresh value
/// whenever any part changes.
struct ThemeMusicPage: Equatable {
    /// The page item's server-resolved set. A season or episode page shows its
    /// series, so this is the series' set there.
    var themes: ThemeSongSet?
    /// The season selected on a series page. A season can own themes the
    /// series' set does not include; its detail resolves them.
    var seasonContentId: String?
    /// The page is still resolving what it shows.
    var isLoading: Bool
    /// On screen, in the foreground and not covered.
    var isVisible: Bool
    /// A video, trailer or audiobook is playing.
    var isOtherMediaActive: Bool
    var enabled: Bool
    var loop: Bool
}

/// Decides when the app's single theme player plays, following the web
/// (`useThemeMusic.ts` in silo-server): only when the profile opted in and the
/// server reports the capability, only for the most recently shown page,
/// suspended while that page is hidden or resolving, and stopped at once when
/// other media starts or the profile changes.
@MainActor
final class ThemeMusicCenter {
    static let shared = ThemeMusicCenter(
        controller: ThemeMusicController(
            grant: { owner, theme in try await SiloAPI.shared.themePlayback(ownerId: owner, themeId: theme) },
            makeOutput: { AVThemeAudioOutput(grant: $0) }
        ),
        identity: {
            TitleArtPreferences.activeRequestIdentity()?.profileKey
        },
        capability: { try await SiloAPI.shared.themeSongsCapability().isAvailable },
        seasonThemes: { try await MetadataRequestPool.shared.itemDetail(contentId: $0).themes }
    )

    /// How long a capability answer stands before the next page asks again.
    static let capabilityLifetime: TimeInterval = 60

    private let controller: ThemeMusicController
    private let identity: @MainActor () -> String?
    private let capability: @MainActor () async throws -> Bool
    private let seasonThemes: @MainActor (String) async throws -> ThemeSongSet?

    private var activePageID: String?
    private var page: ThemeMusicPage?
    /// The page whose theme the controller was last asked to play.
    private var playingPageID: String?
    private var loadedIdentity: String?
    private var capabilityAnswer: (available: Bool, at: Date)?
    private var capabilityTask: Task<Void, Never>?
    /// Resolved season sets for the loaded identity. A stored nil means the
    /// lookup failed and the series' set stands.
    private var seasonSets: [String: ThemeSongSet?] = [:]
    private var seasonTasks: [String: Task<Void, Never>] = [:]

    init(
        controller: ThemeMusicController,
        identity: @escaping @MainActor () -> String?,
        capability: @escaping @MainActor () async throws -> Bool,
        seasonThemes: @escaping @MainActor (String) async throws -> ThemeSongSet?
    ) {
        self.controller = controller
        self.identity = identity
        self.capability = capability
        self.seasonThemes = seasonThemes
    }

    /// Page `id` is the open title page now, in the state `page` describes.
    func show(_ page: ThemeMusicPage, id: String) {
        activePageID = id
        self.page = page
        apply()
    }

    /// Page `id` went away. A page that was already replaced changes nothing.
    func leave(id: String) {
        guard id == activePageID else { return }
        activePageID = nil
        page = nil
        apply()
    }

    /// Sign-out or an identity reset: stop and forget the identity's answers.
    func reset() {
        controller.stop(.silence)
        forgetIdentity()
        loadedIdentity = nil
        activePageID = nil
        playingPageID = nil
        page = nil
    }

    /// Resolves once no capability, season or grant request is in flight. For tests.
    func waitUntilSettled() async {
        while true {
            let pending = [capabilityTask].compactMap { $0 } + Array(seasonTasks.values)
            if pending.isEmpty {
                await controller.waitUntilSettled()
                if capabilityTask == nil && seasonTasks.isEmpty { return }
                continue
            }
            for task in pending { await task.value }
        }
    }

    private func apply() {
        let current = identity()
        if current != loadedIdentity {
            controller.stop(.silence)
            forgetIdentity()
            loadedIdentity = current
        }
        guard current != nil, let page, page.enabled else {
            controller.stop()
            return
        }
        guard !page.isOtherMediaActive else {
            controller.stop(.handOff)
            return
        }
        guard let available = capabilityAvailable() else { return }
        guard available else {
            controller.stop()
            return
        }
        guard page.isVisible, !page.isLoading else {
            controller.suspend()
            return
        }
        guard let themes = resolvedThemes(for: page) else {
            // While a newly selected season's own set is looked up, this
            // page's theme keeps playing (most seasons inherit the series'
            // set); another page's theme does not.
            if playingPageID != activePageID { controller.suspend() }
            return
        }
        playingPageID = activePageID
        controller.select(themes, loop: page.loop)
    }

    /// The capability for the loaded identity, asking when it has no fresh
    /// answer. Nil until the first answer arrives.
    private func capabilityAvailable() -> Bool? {
        let fresh = capabilityAnswer.map { Date().timeIntervalSince($0.at) < Self.capabilityLifetime } ?? false
        if !fresh && capabilityTask == nil {
            let asked = loadedIdentity
            capabilityTask = Task { [weak self, capability] in
                let available = (try? await capability()) ?? false
                // A reset cancels this lookup; a newer one may already be asking.
                guard let self, !Task.isCancelled, self.loadedIdentity == asked else { return }
                self.capabilityAnswer = (available, Date())
                self.capabilityTask = nil
                self.apply()
            }
        }
        return capabilityAnswer?.available
    }

    /// The page's set, or the selected season's once resolved. Nil while the
    /// season's own set is being looked up.
    private func resolvedThemes(for page: ThemeMusicPage) -> ThemeSongSet?? {
        guard let season = page.seasonContentId else { return .some(page.themes) }
        if let resolved = seasonSets[season] { return .some(resolved ?? page.themes) }
        if seasonTasks[season] == nil {
            let asked = loadedIdentity
            seasonTasks[season] = Task { [weak self, seasonThemes] in
                let resolved = try? await seasonThemes(season)
                guard let self, !Task.isCancelled, self.loadedIdentity == asked else { return }
                self.seasonSets[season] = .some(resolved)
                self.seasonTasks[season] = nil
                self.apply()
            }
        }
        return nil
    }

    private func forgetIdentity() {
        capabilityTask?.cancel()
        capabilityTask = nil
        capabilityAnswer = nil
        seasonTasks.values.forEach { $0.cancel() }
        seasonTasks = [:]
        seasonSets = [:]
    }
}
