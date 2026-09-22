import Foundation

/// Rejoining exchanges this code for fresh room proof after an explicit action.
struct WatchPartyRecentRoom: Codable, Equatable, Sendable {
    let roomId: String
    let code: String
    var selectedTitle: String?
}

struct WatchPartySelectedItem: Equatable, Sendable {
    let contentId: String
    let type: String
    let title: String
    let subtitle: String?
    let posterUrl: String?
    let posterThumbhash: String?
    let backdropUrl: String?
    let backdropThumbhash: String?
    let year: Int?
    let runtimeMinutes: Int?
    let contentRating: String?
    /// Outlined quality chips for the hero facts line ("4K", "HDR").
    let qualityChips: [String]
    let overview: String?

    init(_ item: APIv2CatalogRead.CatalogItemDetail) {
        contentId = item.contentId
        type = item.type
        title = item.title
        if let season = item.seasonNumber, let episode = item.episodeNumber {
            subtitle = [item.seriesTitle, "S\(season):E\(episode)"].compactMap { $0 }.joined(separator: " · ")
        } else { subtitle = item.seriesTitle }
        posterUrl = item.posterUrl
        posterThumbhash = item.posterThumbhash
        backdropUrl = item.backdropUrl
        backdropThumbhash = item.backdropThumbhash
        year = item.year.flatMap { Int(exactly: $0) }
        runtimeMinutes = item.runtime.flatMap { Int(exactly: $0) }
        contentRating = item.contentRating?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        var chips: [String] = []
        if let resolution = item.effectiveVersionResolution?.lowercased() {
            if resolution.contains("2160") || resolution.contains("4k") { chips.append("4K") }
            else if resolution.contains("1080") { chips.append("1080p") }
            else if resolution.contains("720") { chips.append("720p") }
        }
        if item.effectiveVersionHdr == true { chips.append("HDR") }
        qualityChips = chips
        overview = item.overview
    }

    /// "2024 · 2h 46m" style facts for the hero.
    var factsLine: [String] {
        var facts: [String] = []
        if let year, year > 0 { facts.append(String(year)) }
        if let runtimeMinutes, runtimeMinutes > 0 {
            facts.append(runtimeMinutes >= 60 ? "\(runtimeMinutes / 60)h \(runtimeMinutes % 60)m" : "\(runtimeMinutes)m")
        }
        return facts
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// How a member's seat reads in the lobby and during playback.
enum WatchPartySeatState: Equatable, Sendable {
    case ready, notReady, away, watching, syncing, buffering, joining
}

/// The one action the lobby foregrounds for this member right now.
enum WatchPartyPrimaryAction: Equatable, Sendable {
    /// Host in host-pick mode with nothing staged.
    case chooseTitle
    /// Host may start now. `title` names the vote winner when relevant.
    case start(title: String?)
    /// Host in vote mode before any suggestion has a vote.
    case waitingForVotes
    /// Guest lobby readiness toggle.
    case ready(isReady: Bool)
    /// The room is playing; this device can rejoin the player.
    case returnToPlayback
    case none
}

enum WatchPartyLobbyPolicy {
    /// Include the deployment path: two Silo servers may share a public origin.
    static func sameServer(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = authority(lhs), let right = authority(rhs) else { return false }
        return left == right
    }

    private static func authority(_ value: String) -> String? {
        guard let url = URLComponents(string: value),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        let path = url.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(scheme)://\(host):\(port)/\(path)"
    }

    static func inviteURL(path: String, serverURL: String) -> URL? {
        guard var invitation = URLComponents(string: path) else { return nil }
        if invitation.scheme == nil && invitation.host == nil {
            guard let server = URLComponents(string: serverURL), invitation.path == "/rooms/join" else { return nil }
            invitation.scheme = server.scheme
            invitation.host = server.host
            invitation.port = server.port
            invitation.percentEncodedPath = server.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .split(separator: "/").reduce("") { $0 + "/" + $1 } + "/rooms/join"
        }
        guard let url = invitation.url, let parsed = WatchPartyInvitation(url: url),
              sameServer(parsed.serverURL, serverURL) else { return nil }
        return url
    }

    static func memberStateIDs(_ ids: [String], maximum: Int) -> [String] {
        guard maximum > 0 else { return [] }
        let limit = min(200, maximum)
        var seen = Set<String>()
        var result: [String] = []
        for id in ids where !id.isEmpty && seen.insert(id).inserted {
            result.append(id)
            if result.count == limit { break }
        }
        return result
    }

    static func voteWinner(_ suggestions: [WatchPartySuggestion]) -> WatchPartySuggestion? {
        suggestions.filter { $0.voteCount > 0 }.sorted {
            if $0.voteCount != $1.voteCount { return $0.voteCount > $1.voteCount }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id < $1.id
        }.first
    }

    static func canRemove(_ suggestion: WatchPartySuggestion, room: WatchPartyRoom?) -> Bool {
        guard let room, room.roomId == suggestion.roomId, room.phase != .ended else { return false }
        if room.selfCanManageRoom { return true }
        guard let member = room.members.first(where: \.isSelf) else { return false }
        return member.userId == suggestion.suggesterUserId && member.profileId == suggestion.suggesterProfileId
    }

    // MARK: - Lobby presentation

    /// The host starts playback, so the host never has to mark ready.
    static func seatState(_ member: WatchPartyMember, phase: WatchPartyPhase) -> WatchPartySeatState {
        if !member.connected { return .away }
        if phase == .lobby { return member.isHost || member.lobbyReady ? .ready : .notReady }
        if member.isBuffering { return .buffering }
        if member.isSyncing { return .syncing }
        return member.isReady ? .watching : .joining
    }

    /// Short trailing summary for the seats row: "2 of 3 ready".
    static func presenceSummary(members: [WatchPartyMember], phase: WatchPartyPhase) -> String {
        let here = members.filter(\.connected)
        if here.count <= 1 { return here.count == 1 ? "only you so far" : "nobody connected" }
        if phase == .lobby {
            let ready = here.filter { seatState($0, phase: phase) == .ready }.count
            return "\(ready) of \(here.count) ready"
        }
        let watching = here.filter { seatState($0, phase: phase) == .watching }.count
        return "\(watching) of \(here.count) watching"
    }

    /// Connected guests who have not marked ready, for the host's advisory hint.
    static func waitingNames(members: [WatchPartyMember]) -> [String] {
        members.filter { $0.connected && !$0.isHost && !$0.lobbyReady }.map(\.displayName)
    }

    static func primaryAction(room: WatchPartyRoom, capabilities: WatchPartyCapabilities?,
                              canStart: Bool, winnerTitle: String?, selectionUnavailable: Bool = false) -> WatchPartyPrimaryAction {
        switch room.phase {
        case .playing: return selectionUnavailable && !room.selfCanManageRoom ? .none : .returnToPlayback
        case .lobby: break
        default: return .none
        }
        // A guest who cannot see the title has nothing to ready up for.
        if selectionUnavailable, !room.selfCanManageRoom { return .none }
        if room.selfCanManageRoom {
            if room.selectionMode == .vote { return canStart ? .start(title: winnerTitle) : .waitingForVotes }
            if room.selectedContentId?.isEmpty ?? true { return .chooseTitle }
            return canStart ? .start(title: nil) : .chooseTitle
        }
        if capabilities?.lobbyReady == true, let member = room.members.first(where: \.isSelf) {
            return .ready(isReady: member.lobbyReady)
        }
        return .none
    }
}
