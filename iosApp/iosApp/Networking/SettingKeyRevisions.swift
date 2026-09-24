//
//  SettingKeyRevisions.swift
//  Silo (iOS + tvOS + macOS)
//
//  The manifest revision that introduced each generated key.
//
//  The Swift bindings carry only the newest revision they were generated from,
//  and treating every server older than that as "upgrade required" would turn a
//  binding refresh into an outage for every feature on every older server.
//  Gating per key instead matches the web client
//  (`manifest_revision >= introducedIn`): a revision-8 server keeps serving the
//  keys it has always served, and only features built on newer keys fall back.
//
//  The generator does not emit `introduced_in` for Swift, so this table is
//  hand-maintained. `SettingsConformanceTests` checks it against the vendored
//  manifest, and the exhaustive switch makes a regenerated key a compile error
//  here until its revision is recorded.
//

import Foundation

extension SettingKey {
    /// The oldest contract revision whose pre-existing features this build
    /// relies on. Servers below it keep the behavior they had before per-key
    /// gating: every settings read reports ``SettingsAPIError/serverUpgradeRequired``.
    ///
    /// Revision 8 because features without a per-key fallback read keys up to
    /// it: the player batch carries `playback.intro_skip_mode` (revision 7),
    /// and the card overlay keys arrived in revision 8. The server's
    /// `/api/v2/settings` routes shipped at revision 8, so no v2 server
    /// reports less. Raise this only together with every feature that stops
    /// working below the new value; a feature that can fall back gates on its
    /// own keys instead.
    static let minimumServerRevision = 8

    /// The manifest revision that introduced this key.
    var introducedIn: Int {
        switch self {
        case .catalogMetadataLanguageOverrides:
            return 3
        case .navPrimaryMenu, .navShortcuts, .uiCardPresentation:
            return 5
        case .playbackIntroSkipMode:
            return 7
        case .uiCardOverlaysEnabled, .uiCardQuickActions, .uiCardQuickActionsEnabled:
            return 8
        case .playerVideoSkipBackSeconds, .playerVideoSkipForwardSeconds,
             .playerAudiobookSkipBackSeconds, .playerAudiobookSkipForwardSeconds:
            return 9
        case .catalogMetadataLanguage, .downloadsDefaultQuality, .downloadsKeepWatched,
             .downloadsWifiOnly, .navShowAudiobooks, .playbackAudioLanguage,
             .playbackAutoPlayNext, .playbackAutoPlayNextPreview, .playbackAutoSkipCredits,
             .playbackAutoSkipIntro, .playbackAutoSkipRecap, .playbackMaxBitrateKbps,
             .playbackNextUpPromptSeconds, .playbackPreferredQuality,
             .playbackShowForcedSubtitles, .playbackSubtitleAppearance,
             .playbackSubtitleLanguage, .playbackSubtitleMode, .playerAudioSyncMs,
             .playerDolbyVisionEnabled, .playerDvProfile7Hdr10Fallback, .playerHdrEnabled,
             .playerMatchFrameRate, .playerOrientationMode, .playerPassoutThreshold,
             .playerPictureInPictureEnabled, .playerPlaybackSpeed, .playerResumeRewindSeconds,
             .playerSeekCacheEnabled, .playerSleepTimerDefaultMinutes, .playerSubtitleSyncMs,
             .playerVideoGravity, .searchMediaScope, .subtitleMatchesDevice, .uiCardOverlays,
             .uiCustomCss, .uiCustomThemeVars, .uiDateFormat, .uiDisabledLibraryIds,
             .uiHighContrast, .uiLibraryOrder, .uiLibraryPageState, .uiNextUpMode,
             .uiRememberLibraryPageState, .uiSidebarPins, .uiTextScale, .uiTextWeight,
             .uiTheme, .uiTimeFormat:
            return 1
        }
    }

    /// Whether a server answering at `revision` knows this key.
    func isServed(atRevision revision: Int) -> Bool {
        revision >= Self.minimumServerRevision && revision >= introducedIn
    }
}
