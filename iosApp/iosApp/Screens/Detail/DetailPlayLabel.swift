import Foundation

/// Titles for the detail pages' primary Play button. The title uses the
/// same `PlaybackResumePoint` rule as the resume prompt (more than 30
/// seconds in and not within 5 seconds of the end), applied to the page's
/// saved watch state. The tap re-reads the server, so after another device
/// moved on the prompt can offer a newer position than the title implies.
/// A position saved on another edition than the file shown (`shown`) is not
/// one: Play starts that file at 0.
enum DetailPlayLabel {
    static func resumePosition(
        _ userData: LeafItemUserData?,
        shown: FileVersion? = nil,
        in versions: [FileVersion] = []
    ) -> Double? {
        guard DetailVersionSelection.savedPositionIsInEdition(of: shown, in: versions, userData: userData) else {
            return nil
        }
        return PlaybackResumePoint.position(userData?.positionSeconds, duration: userData?.durationSeconds)
    }

    /// "Resume" or "Play" for a movie or a single episode's own page.
    static func item(
        _ userData: LeafItemUserData?,
        shown: FileVersion? = nil,
        in versions: [FileVersion] = []
    ) -> String {
        AppLanguage.string(resumePosition(userData, shown: shown, in: versions) == nil ? .commonPlay : .detailResume)
    }

    /// "Resume S1·E2" or "Play S1·E2" for the series page's next-up episode.
    static func episode(
        _ episode: EpisodeListItem,
        shown: FileVersion? = nil,
        in versions: [FileVersion] = []
    ) -> String {
        let code = AppLanguage.string(.detailEpisodeCode(LocaleFormat.codeNumber(episode.seasonNumber), LocaleFormat.codeNumber(episode.episodeNumber)))
        return AppLanguage.string(resumePosition(episode.userData, shown: shown, in: versions) == nil
            ? .detailPlayEpisodeCode(code)
            : .detailResumeEpisodeCode(code))
    }
}
