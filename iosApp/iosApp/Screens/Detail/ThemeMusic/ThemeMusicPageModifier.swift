import SwiftUI

extension View {
    /// Plays this title page's local theme music while it is the open page.
    ///
    /// - Parameters:
    ///   - themes: the page item's server-resolved set.
    ///   - seasonContentId: the season selected on a series page, whose own
    ///     set wins when it has one.
    ///   - isLoading: the page has not resolved its item yet.
    func themeMusic(_ themes: ThemeSongSet?, seasonContentId: String?, isLoading: Bool) -> some View {
        modifier(ThemeMusicPageModifier(themes: themes, seasonContentId: seasonContentId, isLoading: isLoading))
    }
}

private struct ThemeMusicPageModifier: ViewModifier {
    let themes: ThemeSongSet?
    let seasonContentId: String?
    let isLoading: Bool

    @Environment(AppRouter.self) private var router
    @Environment(AudioPlaybackStore.self) private var audioStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var pageID = UUID().uuidString
    @State private var isAppeared = false

    private var page: ThemeMusicPage { page(appeared: isAppeared) }

    private func page(appeared: Bool) -> ThemeMusicPage {
        let preferences = ThemeMusicPreferences.shared
        let audiobook = audioStore.player
        var otherMedia = router.presentedPlayer != nil || audiobook.isPlaying || audiobook.isLoading
        #if os(iOS)
        otherMedia = otherMedia || PictureInPictureCoordinator.shared.isEngaged
        #endif
        return ThemeMusicPage(
            themes: themes,
            seasonContentId: seasonContentId,
            isLoading: isLoading,
            // Leaving the app (a trailer in the YouTube app, the Home screen)
            // pauses the theme; coming back resumes it.
            isVisible: appeared && scenePhase == .active,
            isOtherMediaActive: otherMedia,
            enabled: preferences.playsThemeMusic,
            loop: preferences.loops
        )
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                isAppeared = true
                ThemeMusicCenter.shared.show(page(appeared: true), id: pageID)
            }
            .onDisappear {
                isAppeared = false
                ThemeMusicCenter.shared.leave(id: pageID)
            }
            .onChange(of: page) { _, page in
                guard isAppeared else { return }
                ThemeMusicCenter.shared.show(page, id: pageID)
            }
    }
}
