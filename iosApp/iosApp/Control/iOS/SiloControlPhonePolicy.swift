#if os(iOS)
import Foundation

/// What the phone does when the TV closes its session.
enum SiloControlCloseResponse: Equatable {
    /// Connect again quietly, as after a dropped link.
    case reconnect
    /// End the session. With `forgetTarget`, no later foreground probe
    /// silently reattaches to that TV.
    case letGo(forgetTarget: Bool)
}

enum SiloControlClosePolicy {
    /// A TV without `multi_controller` closes only to hand the slot to
    /// another phone or because someone pressed Disconnect, so the phone
    /// lets go and forgets it, as it always has. A TV that keeps several
    /// controllers says why: a deliberate disconnect (or no reason) still
    /// forgets the TV, a timeout reconnects, and the rest end the session
    /// but let a later foreground find the TV again.
    static func response(reason: String?, tvKeepsOtherControllers: Bool) -> SiloControlCloseResponse {
        guard tvKeepsOtherControllers else { return .letGo(forgetTarget: true) }
        switch reason {
        case SiloControlCloseReason.timeout:
            return .reconnect
        case nil, SiloControlCloseReason.tvDisconnected:
            return .letGo(forgetTarget: true)
        default:
            return .letGo(forgetTarget: false)
        }
    }
}

/// A launch the TV refused because another profile's title is playing,
/// waiting for the user to agree to replace it.
struct SiloControlPendingReplace: Equatable {
    let request: SiloControlPlaybackRequest
    let nowPlaying: SiloControlNowPlayingSummary?
    let tvName: String
    /// The TV's own wording, used when it sent no summary.
    let fallbackMessage: String

    var message: String {
        guard let nowPlaying else { return fallbackMessage }
        let who = nowPlaying.profileName ?? "Someone"
        let what = [nowPlaying.subtitle, nowPlaying.title]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
        return "\(who) is watching \(what) on \(tvName). Play yours instead?"
    }
}

/// The handoff offer's display-only `title`, in the wording silo-android
/// sends so every TV shows the same thing: an episode as "Series · S1 · E2",
/// anything else by its own title.
enum SiloControlOfferTitle {
    static func make(type: String, title: String, seriesTitle: String?, seasonNumber: Int?, episodeNumber: Int?) -> String? {
        func blank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if SiloMediaType.isEpisode(type), let series = seriesTitle, !blank(series) {
            return [series, seasonNumber.map { "S\($0)" }, episodeNumber.map { "E\($0)" }]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
        return blank(title) ? nil : title
    }

    static func make(for detail: ItemDetail) -> String? {
        make(type: detail.type, title: detail.title, seriesTitle: detail.seriesTitle,
             seasonNumber: detail.seasonNumber, episodeNumber: detail.episodeNumber)
    }
}

/// Resume tokens the TVs issued this phone, held in memory only. A token
/// lets a later connection to the same TV reuse the profile it already
/// holds for this phone without a new approval, as after a Wi-Fi change.
struct SiloControlResumeTokens {
    private struct Entry {
        let serverId: String
        let profileId: String
        let token: String
    }

    private var entries: [String: Entry] = [:]

    func token(tvId: String, serverId: String, profileId: String) -> String? {
        guard let entry = entries[tvId],
              ServerRegistry.serverIdsMatch(entry.serverId, serverId),
              entry.profileId == profileId else { return nil }
        return entry.token
    }

    mutating func store(_ token: String?, tvId: String, serverId: String, profileId: String) {
        guard let token, !token.isEmpty else { return }
        entries[tvId] = Entry(serverId: serverId, profileId: profileId, token: token)
    }
}
#endif
