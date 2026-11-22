import Foundation

/// One (server, account) pair the phone can send a TV.
struct CompanionAccountChoice: Hashable, Sendable {
    let serverId: String
    /// nil: the account the phone uses on the server, which has no saved
    /// account record to name it (an older install).
    let localAccountId: String?
}

/// One account row in the phone's chooser.
struct CompanionAccountOption: Identifiable, Hashable, Sendable {
    let serverId: String
    let localAccountId: String?
    let username: String?
    /// The server refused the account's credentials on this phone: shown,
    /// but it can't approve anything until it signs in again.
    let needsSignIn: Bool
    /// The account requests to this server use on this phone.
    let isInUse: Bool

    var id: CompanionAccountChoice { CompanionAccountChoice(serverId: serverId, localAccountId: localAccountId) }

    /// The server's account in use when no saved account names it.
    static func inUse(on server: ServerEntry) -> CompanionAccountOption {
        CompanionAccountOption(serverId: server.id, localAccountId: nil, username: nil, needsSignIn: false, isInUse: true)
    }
}

/// A saved server and its accounts, the one in use first.
struct CompanionServerSection: Identifiable, Equatable, Sendable {
    let server: ServerEntry
    let accounts: [CompanionAccountOption]

    var id: String { server.id }
}

/// What a TV can take from one session, from its advertisement, and the
/// chooser rules that follow (contract §C.1–2).
struct CompanionAccountChooser: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        /// `acct=1`: any accounts, several on one server included.
        case several
        /// An Apple TV or Android TV without `acct=1`: one account per server.
        case onePerServer
        /// A Roku without `acct=1`: one account in all.
        case one
    }

    /// Why a row can't be ticked.
    enum Unavailable: Equatable, Sendable {
        case needsSignIn
        /// The TV keeps at most this many sign-ins from one session (`lim`).
        case limitReached(Int)
    }

    let mode: Mode
    /// `lim`: the most sign-ins the TV keeps from one session; nil for none.
    let limit: Int?

    init(isRoku: Bool, acceptsSeveralAccounts: Bool, limit: Int? = nil) {
        if acceptsSeveralAccounts {
            mode = .several
        } else {
            mode = isRoku ? .one : .onePerServer
        }
        self.limit = limit.flatMap { $0 > 0 ? $0 : nil }
    }

    /// The selection after tapping `option`. Tapping a chosen row clears it.
    /// In a one-account mode a new row replaces the one it conflicts with.
    /// A row that is unavailable leaves the selection as it was.
    func toggling(_ option: CompanionAccountOption, in selection: Set<CompanionAccountChoice>) -> Set<CompanionAccountChoice> {
        if selection.contains(option.id) { return selection.subtracting([option.id]) }
        guard unavailable(option, in: selection) == nil else { return selection }
        return adding(option, to: selection)
    }

    /// Why `option` can't be ticked now, or nil when it can. A chosen row is
    /// always available, so it can be cleared.
    func unavailable(_ option: CompanionAccountOption, in selection: Set<CompanionAccountChoice>) -> Unavailable? {
        if option.needsSignIn { return .needsSignIn }
        if selection.contains(option.id) { return nil }
        if let limit, adding(option, to: selection).count > limit { return .limitReached(limit) }
        return nil
    }

    private func adding(_ option: CompanionAccountOption, to selection: Set<CompanionAccountChoice>) -> Set<CompanionAccountChoice> {
        switch mode {
        case .several: return selection.union([option.id])
        case .onePerServer: return selection.filter { $0.serverId != option.serverId }.union([option.id])
        case .one: return [option.id]
        }
    }

    /// Only the account the phone uses on its active server, when it can
    /// approve (decision D2). Nobody signs a shared TV in as a housemate
    /// without ticking them.
    static func defaultSelection(_ sections: [CompanionServerSection], activeServerId: String?) -> Set<CompanionAccountChoice> {
        guard let active = sections.first(where: { $0.server.id == activeServerId })?
            .accounts.first(where: { $0.isInUse && !$0.needsSignIn }) else { return [] }
        return [active.id]
    }

    /// The chosen accounts in sending order: the phone's account on its
    /// active server first, then list order, trimmed to what the TV takes.
    func sendingOrder(
        _ selection: Set<CompanionAccountChoice>,
        in sections: [CompanionServerSection],
        activeServerId: String?
    ) -> [(server: ServerEntry, account: CompanionAccountOption)] {
        var listed = sections.flatMap { section in
            section.accounts
                .filter { selection.contains($0.id) && !$0.needsSignIn }
                .map { (server: section.server, account: $0) }
        }
        if let lead = listed.firstIndex(where: { $0.server.id == activeServerId && $0.account.isInUse }) {
            listed.insert(listed.remove(at: lead), at: 0)
        }
        switch mode {
        case .several:
            break
        case .onePerServer:
            var seen = Set<String>()
            listed = listed.filter { seen.insert($0.server.id).inserted }
        case .one:
            listed = Array(listed.prefix(1))
        }
        if let limit { listed = Array(listed.prefix(limit)) }
        return listed
    }
}
