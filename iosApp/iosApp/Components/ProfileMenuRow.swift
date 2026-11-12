import Foundation

/// The profile row of the avatar menu on iPhone, iPad, Mac and Apple TV
/// (spec §4.3). Which row shows depends on how many profiles the open
/// account has and how many it may have.
enum ProfileMenuRow: Equatable {
    /// Opens the open account's "Who's watching?".
    case switchProfile
    /// Opens profile creation: the account has one profile, so there is
    /// nothing to switch to, and room for another.
    case addProfile

    /// The row to show, or nil for none.
    ///
    /// - Parameters:
    ///   - profileCount: profiles in the open account's cached list; 0 while
    ///     no list has been read.
    ///   - profileLimit: how many profiles the account may have; nil when
    ///     the server didn't say.
    ///   - isHandoffSession: a phone's remote playback borrows this device.
    ///     Its session can neither switch nor add a profile.
    static func row(profileCount: Int, profileLimit: Int?, isHandoffSession: Bool = false) -> ProfileMenuRow? {
        if isHandoffSession { return nil }
        // Several profiles, or a list not read yet: the picker, as before.
        guard profileCount == 1 else { return .switchProfile }
        if let profileLimit, profileLimit <= 1 { return nil }
        return .addProfile
    }

    /// The row for a saved account, from its cached profile list and limit.
    /// Switch Profile while the account isn't known.
    static func row(for account: SavedAccountSummary?, isHandoffSession: Bool = false) -> ProfileMenuRow? {
        row(
            profileCount: account?.cachedProfiles.count ?? 0,
            profileLimit: account?.maxProfiles,
            isHandoffSession: isHandoffSession
        )
    }

    var title: LocalizedStringResource {
        switch self {
        case .switchProfile: .menuSwitchProfile
        case .addProfile: .menuAddProfile
        }
    }

    /// SF Symbol name. Apple TV's menu draws filled glyphs.
    var systemImage: String {
        #if os(tvOS)
        switch self {
        case .switchProfile: "person.2.fill"
        case .addProfile: "person.fill.badge.plus"
        }
        #else
        switch self {
        case .switchProfile: "person.2"
        case .addProfile: "person.badge.plus"
        }
        #endif
    }
}

extension AccountDirectory {
    /// The account open on the active server, as the profile menu draws it.
    var openAccount: SavedAccountSummary? {
        guard let serverId = ServerRegistry.shared.activeServerId,
              let selected = AccountScope.localAccountId(onServer: serverId) else { return nil }
        return account(selected)
    }
}
