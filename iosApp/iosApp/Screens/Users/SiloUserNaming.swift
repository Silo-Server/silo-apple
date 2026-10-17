import Foundation

/// How a Silo user is named on screen (spec §4). Names are stored on the
/// device and never change the account on the server.
enum SiloUserNaming {
    static let maxDisplayNameLength = 40
    /// Joins a name and the server added to tell two users apart.
    static let separator = " · "
    /// Only when neither a username nor a server name is known.
    static let fallbackName = "Silo User"

    /// What a rename stores: trimmed and cut to 40 characters. Nil, which
    /// restores the default name, when nothing is left.
    static func normalizedDisplayName(_ input: String?) -> String? {
        guard let input else { return nil }
        let name = String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxDisplayNameLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The username of the user's oldest sign-in, or that sign-in's server
    /// name until the username is known (after migration or phone pairing).
    /// A user with only pending legacy servers is named after the first one.
    static func defaultName(
        for user: SiloUser,
        in directory: SiloUserDirectorySnapshot,
        serverNames: [String: String]
    ) -> String {
        if let oldest = user.signIns.first,
           let username = nonEmpty(directory.signIns[oldest]?.username) {
            return username
        }
        return foundingServerID(of: user).flatMap { nonEmpty(serverNames[$0]) } ?? fallbackName
    }

    /// The rename when there is one, otherwise the default name.
    static func displayName(
        for user: SiloUser,
        in directory: SiloUserDirectorySnapshot,
        serverNames: [String: String]
    ) -> String {
        normalizedDisplayName(user.displayName)
            ?? defaultName(for: user, in: directory, serverNames: serverNames)
    }

    /// Every user's name, keyed by user ID, with shared names told apart
    /// (plan G7). Names compare without case.
    /// 1. Add the founding (oldest) sign-in's server: "alex · Friend's Silo".
    ///    A name that already is that server's name keeps it once.
    /// 2. Still shared: add the newest server's name, when it's another server.
    /// 3. Still shared: number the later users in index order: "alex (2)".
    static func disambiguatedNames(
        in directory: SiloUserDirectorySnapshot,
        serverNames: [String: String]
    ) -> [String: String] {
        let users = directory.users
        let baseNames = users.map { displayName(for: $0, in: directory, serverNames: serverNames) }
        var names = baseNames

        for group in sharedNameGroups(names) {
            for index in group {
                guard let founding = foundingServerID(of: users[index]).flatMap({ nonEmpty(serverNames[$0]) }),
                      comparisonKey(founding) != comparisonKey(baseNames[index]) else { continue }
                names[index] = baseNames[index] + separator + founding
            }
        }

        for group in sharedNameGroups(names) {
            for index in group {
                let servers = SignInTargetList.serverIDs(in: users[index])
                guard servers.count > 1, let newestID = servers.last,
                      let newest = nonEmpty(serverNames[newestID]) else { continue }
                names[index] += separator + newest
            }
        }

        for group in sharedNameGroups(names) {
            for (position, index) in group.enumerated() where position > 0 {
                names[index] += " (\(position + 1))"
            }
        }

        return Dictionary(zip(users.map(\.id), names), uniquingKeysWith: { first, _ in first })
    }

    private static func foundingServerID(of user: SiloUser) -> String? {
        SignInTargetList.serverIDs(in: user).first
    }

    /// Indices of names that more than one user shares, each group in index
    /// order.
    private static func sharedNameGroups(_ names: [String]) -> [[Int]] {
        var groups: [String: [Int]] = [:]
        var order: [String] = []
        for (index, name) in names.enumerated() {
            let key = comparisonKey(name)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(index)
        }
        return order.compactMap { groups[$0] }.filter { $0.count > 1 }
    }

    private static func comparisonKey(_ name: String) -> String {
        name.folding(options: .caseInsensitive, locale: nil)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
