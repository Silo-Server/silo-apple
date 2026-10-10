//
//  EpisodeSpoilers.swift
//  Silo (iOS + tvOS + macOS)
//
//  Spoiler protection for unwatched episodes
//  (`catalog.hide_unwatched_episode_{images,overviews}`, contract revision
//  16). Image provenance is profile-independent; each surface that shows a
//  specific episode's still or description asks these helpers whether to hide
//  it. The observable store that reads and writes the two profile settings
//  lives in EpisodeSpoilerPreferences.swift.
//
//  Series and season artwork and overviews are never hidden.
//

import SwiftUI

/// The watch state the unwatched rule reads. Matches the web client's
/// `isEpisodeUnwatched`: an episode is unwatched when it has no watch state,
/// or when it is neither played nor in progress and has no saved position.
struct EpisodeWatchState: Hashable, Sendable {
    var played: Bool
    var isInProgress: Bool?
    var positionSeconds: Double?

    init(played: Bool, isInProgress: Bool? = nil, positionSeconds: Double? = nil) {
        self.played = played
        self.isInProgress = isInProgress
        self.positionSeconds = positionSeconds
    }

    /// Missing user data means the profile has never touched the episode.
    init(_ userData: LeafItemUserData?, playedOverride: Bool? = nil) {
        self.init(
            played: playedOverride ?? userData?.played ?? false,
            isInProgress: userData?.isInProgress,
            positionSeconds: userData?.positionSeconds
        )
    }

    /// Section rows carry `user_state.played` and the resume position.
    /// `playedOverride` is a card's local mark-watched answer.
    init(sectionItem item: SectionItem, playedOverride: Bool? = nil) {
        self.init(
            played: playedOverride ?? item.userState?.played ?? false,
            positionSeconds: item.positionSeconds
        )
    }

    /// Browse rows carry `user_state.played`, and a resume position only on
    /// section-sourced pages.
    init(browseItem item: BrowseItem) {
        self.init(played: item.userState?.played ?? false, positionSeconds: item.positionSeconds)
    }

    var isUnwatched: Bool {
        !played && isInProgress != true && (positionSeconds ?? 0) <= 0
    }
}

/// The active profile's two spoiler switches, as the server resolved them.
struct EpisodeSpoilerSettings: Codable, Hashable, Sendable {
    var hidesImages: Bool
    var hidesOverviews: Bool

    static let off = EpisodeSpoilerSettings(hidesImages: false, hidesOverviews: false)

    func hidesImage(for state: EpisodeWatchState, isEpisodeStill: Bool? = nil) -> Bool {
        hidesImages && state.isUnwatched && isEpisodeStill != false
    }

    func hidesOverview(for state: EpisodeWatchState) -> Bool {
        hidesOverviews && state.isUnwatched
    }

    /// Section rows mix episodes with movies and series; only an episode's
    /// own still or description is ever hidden.
    func hidesImage(for item: SectionItem, playedOverride: Bool? = nil) -> Bool {
        let provenance = item.backdropUrl?.isEmpty == false ? item.backdropIsEpisodeStill : item.posterIsEpisodeStill
        return item.isEpisodeItem
            && hidesImage(for: EpisodeWatchState(sectionItem: item, playedOverride: playedOverride), isEpisodeStill: provenance)
    }

    func hidesOverview(for item: SectionItem, playedOverride: Bool? = nil) -> Bool {
        item.isEpisodeItem
            && hidesOverview(for: EpisodeWatchState(sectionItem: item, playedOverride: playedOverride))
    }
}

extension BrowseItem {
    var isEpisodeItem: Bool {
        switch type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "episode", "episodes": return true
        default: return false
        }
    }
}

extension SectionItem {
    var isEpisodeItem: Bool {
        switch type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "episode", "episodes": return true
        default: return false
        }
    }
}

/// How strongly a hidden still is blurred. Web blurs with a 24px standard
/// deviation; the design language asks for at least sigma 12.
enum EpisodeSpoilerBlur {
    static let radius: CGFloat = 24
}

extension View {
    /// Blurs a hidden episode still in place. Apply it to the image before
    /// the card frames and clips it, so the layout, badges, and progress bar
    /// drawn over the artwork stay exactly as they are. `opaque` keeps the
    /// blurred edges from fading to transparent inside the card. The modifier
    /// is always present so revealing a still never reloads the image.
    func episodeSpoilerBlur(_ hidden: Bool) -> some View {
        blur(radius: hidden ? EpisodeSpoilerBlur.radius : 0, opaque: hidden)
    }
}
