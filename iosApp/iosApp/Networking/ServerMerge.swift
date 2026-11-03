import Foundation
import OSLog

/// The local data side of folding one saved server into another that
/// reported the same `verifiedServerId` (spec §5,
/// `ServerRegistry.mergeDuplicateServers`). Accounts keep their
/// `localAccountId`, so their data only changes server: downloads,
/// account-scoped preferences, player settings, snapshots, and the
/// onboarding marker move first, before the account index commits, and the
/// dropped server's leftovers go after the registry commits. Every step
/// moves into an empty place only and deletes its source last, so a rerun
/// after an interruption finishes the job. Needs no network.
enum ServerMerge {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "ServerMerge"
    )

    /// Moves what `merge`'s dropped server keeps on this device to the
    /// accounts that hold it on `survivor`. Runs before
    /// `AccountStore.commitServerMerge`.
    static func moveLocalData(_ merge: AccountServerMerge, from dropped: ServerEntry, to survivor: ServerEntry) {
        let movedIds = Set(merge.moved.map(\.localAccountId))
        let legacyTarget = merge.legacyDataTarget
        moveDownloads(merge, survivorServerId: survivor.id)
        moveAccountScopedKeys(from: dropped.id, to: survivor.id, accounts: movedIds, legacyTarget: legacyTarget)
        PlayerSettings.moveLocalData(fromServerURL: dropped.url, toServerURL: survivor.url,
                                     accounts: movedIds, legacyTarget: legacyTarget)
        ResponseSnapshotStore.moveAll(fromServer: dropped.id, toServer: survivor.id,
                                      accounts: movedIds, legacyTarget: legacyTarget)
        UnrenderableOnboardingTourSuppression.move(fromServer: dropped.id, toServer: survivor.id,
                                                   accounts: movedIds, legacyTarget: legacyTarget)
    }

    /// Deletes what the dropped server leaves once the registry no longer
    /// lists it: the removed accounts' local data (they are signed out
    /// locally, never on the server, since the kept account may share their
    /// session), its push installation, and its branding.
    static func removeLeftovers(_ merge: AccountServerMerge, from dropped: ServerEntry, stillSaved: [ServerEntry]) {
        let removed = merge.removed.map(\.account)
        Task { @MainActor in
            for account in removed {
                AccountLocalData.purge(localAccountId: account.localAccountId, serverId: account.serverId,
                                       ownedLegacyData: false)
            }
        }
        #if os(iOS)
        dropPushInstallation(of: dropped.id, keeping: merge.survivorServerId)
        #endif
        if !stillSaved.contains(where: { ServerRegistry.normalize(url: $0.url) == ServerRegistry.normalize(url: dropped.url) }) {
            ServerBrandingCache.remove(for: dropped.url)
        }
        let serverDirectory = DownloadFilePaths.serverPath(serverId: dropped.id, root: DownloadFilePaths.rootDirectory())
        if (try? FileManager.default.contentsOfDirectory(atPath: serverDirectory.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: serverDirectory)
        }
    }

    // MARK: - Proof

    /// A login-session proof (`LoginSessionProof`) for two saved entries,
    /// kept so a proven pair can merge offline later and a disproven pair is
    /// not asked again. It holds while the sessions it compared do: each
    /// account's sign-in epoch.
    private struct Proof: Codable {
        let outcome: LoginSessionProof.Outcome
        let epochs: [String: UUID]
        let provenAt: Date
    }

    private static let proofsKey = "serverMerge.proofs.v1"

    static func pairKey(_ lhs: String, _ rhs: String) -> String {
        [lhs, rhs].sorted().joined(separator: "|")
    }

    /// The stored verdict for two entries while it still holds: a proof
    /// while either compared session is still saved (a merge removes one of
    /// them), a disproof while both are. Nil when there is none.
    static func cachedProof(_ lhs: String, _ rhs: String, accounts: [Account]) -> LoginSessionProof.Outcome? {
        guard let proof = storedProofs()[pairKey(lhs, rhs)] else { return nil }
        let held = proof.epochs.filter { id, epoch in accounts.contains { $0.localAccountId == id && $0.epoch == epoch } }
        switch proof.outcome {
        case .proven: return held.isEmpty ? nil : .proven
        case .disproven: return held.count == proof.epochs.count ? .disproven : nil
        case .unavailable: return nil
        }
    }

    /// Runs the proof for two entries with one server user signed in on
    /// both: `lhs`'s account reads its own session at its own address, and
    /// `rhs`'s account looks for it among its sessions at its address. No
    /// token goes to the other address. A proof or disproof is stored; nil
    /// when no such pair of accounts exists or no answer came.
    static func prove(_ lhs: String, _ rhs: String, accounts: AccountStore, http: HTTPClient) async -> LoginSessionProof.Outcome? {
        let left = ((try? accounts.accounts(onServer: lhs)) ?? []).filter(\.isSignedIn)
        let right = ((try? accounts.accounts(onServer: rhs)) ?? []).filter(\.isSignedIn)
        for own in left {
            guard let user = own.serverUserId, let ownEpoch = own.epoch,
                  let holder = right.first(where: { $0.serverUserId == user }), let holderEpoch = holder.epoch,
                  let ownSessions = sessions(of: own, http: http),
                  let holderSessions = sessions(of: holder, http: http) else { continue }
            let outcome = await LoginSessionProof.check(own: ownSessions, holder: holderSessions)
            guard outcome != .unavailable else { continue }
            var proofs = storedProofs()
            proofs[pairKey(lhs, rhs)] = Proof(
                outcome: outcome,
                epochs: [own.localAccountId: ownEpoch, holder.localAccountId: holderEpoch],
                provenAt: Date()
            )
            if let data = try? JSONEncoder().encode(proofs) { SharedDefaults.shared.set(data, forKey: proofsKey) }
            logger.notice("Checked whether two saved addresses reach one server: \(outcome.rawValue, privacy: .public)")
            return outcome
        }
        return nil
    }

    private static func storedProofs() -> [String: Proof] {
        SharedDefaults.shared.data(forKey: proofsKey)
            .flatMap { try? JSONDecoder().decode([String: Proof].self, from: $0) } ?? [:]
    }

    private static let proofSession = URLSession(configuration: .ephemeral,
                                                 delegate: InsecureRedirectRefusingDelegate.shared,
                                                 delegateQueue: nil)

    /// `account`'s own login sessions, read at the one address its server is
    /// keyed by, with its own bearer. Nil when the account is bound to
    /// another address.
    private static func sessions(of account: Account, http: HTTPClient) -> LoginSessionProof.Sessions? {
        guard let address = ServerRegistry.url(forServerId: account.serverId),
              ServerRegistry.normalize(url: account.origin) == address else { return nil }
        let serverId = account.serverId, localAccountId = account.localAccountId
        return { cursor in
            guard let bearer = await http.freshAccessToken(serverId: serverId, localAccountId: localAccountId).token,
                  var components = URLComponents(string: address + APIv2Client.loginSessionsPath) else {
                throw HTTPError.authorityChanged
            }
            components.queryItems = APIv2Client.loginSessionsQuery(cursor: cursor)
                .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = components.url else { throw HTTPError.invalidURL(address) }
            var request = URLRequest(url: url, timeoutInterval: 15)
            AppleDeviceIdentity.current.applyHeaders(to: &request)
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await proofSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw APIv2Error.httpStatus(status) }
            return try HTTPClient.makeJSONDecoder().decode(APIv2LoginSessionPage.self, from: data)
        }
    }

    // MARK: - Private

    /// Each moved account's directory goes to the survivor, a removed
    /// account's downloads join the account kept in its place, and the
    /// dropped server's scopes from before accounts join its owner's.
    private static func moveDownloads(_ merge: AccountServerMerge, survivorServerId: String) {
        let root = DownloadFilePaths.rootDirectory()
        var complete = true
        for move in merge.downloadMoves {
            let source = DownloadFilePaths.accountPath(serverId: move.serverId, localAccountId: move.localAccountId, root: root)
            let target = DownloadFilePaths.accountPath(serverId: survivorServerId, localAccountId: move.target, root: root)
            guard source.standardizedFileURL.path != target.standardizedFileURL.path,
                  FileManager.default.fileExists(atPath: source.path) else { continue }
            let scopes = (try? FileManager.default.contentsOfDirectory(
                at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            if DownloadStore.mergeScopes(scopes, into: target) {
                try? FileManager.default.removeItem(at: source)
            } else {
                complete = false
            }
        }
        if let owner = merge.legacyDataTarget {
            let scopes = DownloadFilePaths.scopesFromBeforeAccounts(serverId: merge.droppedServerId, root: root)
            let target = DownloadFilePaths.accountPath(serverId: survivorServerId, localAccountId: owner, root: root)
            if !DownloadStore.mergeScopes(scopes, into: target) { complete = false }
        }
        if !complete {
            logger.error("Some downloads of a merged server could not move yet; the next launch retries")
        }
    }

    /// `<prefix>.v2.<dropped>.<account>.…` becomes `<prefix>.v2.<survivor>.<account>.…`
    /// for each moved account, and with a `legacyTarget` the dropped server's
    /// keys from before accounts (`<prefix>.<dropped>.…`) become that
    /// account's. A key the survivor already has keeps its value.
    private static func moveAccountScopedKeys(from dropped: String, to survivor: String,
                                              accounts: Set<String>, legacyTarget: String?) {
        let defaults = SharedDefaults.shared
        let marker = AccountScopedKeyAdoption.versionMarker
        let prefixes = AccountLocalData.legacyKeyPrefixes
        for key in defaults.allKeys {
            let newKey: String
            if let account = accounts.first(where: {
                AccountScopedKeyAdoption.isKey(key, ofAccount: $0, onServer: dropped)
            }) {
                newKey = key.replacingOccurrences(of: ".\(marker).\(dropped).\(account).",
                                                  with: ".\(marker).\(survivor).\(account).")
            } else if let legacyTarget,
                      let prefix = prefixes.first(where: { key.hasPrefix("\($0).\(dropped).") }) {
                newKey = "\(prefix).\(marker).\(survivor).\(legacyTarget)." + key.dropFirst("\(prefix).\(dropped).".count)
            } else {
                continue
            }
            guard newKey != key, !defaults.containsObject(forKey: newKey),
                  let value = defaults.object(forKey: key) else { continue }
            defaults.setObject(value, forKey: newKey)
            if defaults.containsObject(forKey: newKey) { defaults.removeObject(forKey: key) }
        }
    }

    #if os(iOS)
    /// Both addresses reach one server, which keys this device's
    /// installation by device ID, so the survivor's record is kept and the
    /// dropped address's record and link are deleted without retiring
    /// anything: a retirement would end the survivor's installation too.
    /// When only the dropped address had a record, its key is the one the
    /// server holds, so the survivor takes it. The next registration pass
    /// registers the survivor's owner.
    private static func dropPushInstallation(of dropped: String, keeping survivor: String) {
        let journal = ApplePushInstallationJournal()
        do {
            let droppedSlot = try journal.recordSlot(for: dropped)
            let survivorSlot = try journal.recordSlot(for: survivor)
            if droppedSlot != survivorSlot, try journal.load(serverID: survivor) == nil,
               let record = try journal.load(serverID: dropped) {
                try journal.save(record, slot: survivorSlot)
            }
            journal.keychain.delete(ApplePushInstallationJournal.linkAccount(for: dropped))
            if droppedSlot == dropped {
                journal.keychain.delete(ApplePushInstallationJournal.account(for: dropped))
            }
        } catch {
            logger.error("A merged server's push installation could not be read; leaving it in place")
        }
        ApplePushDisplayTargetStore(keychain: SharedKeychain(audience: TokenStore.profileCredentialAudience))
            .removeTargets(registeredBy: dropped)
        Task { @MainActor in await ApplePushRegistrationCoordinator.shared.registerCurrentDeviceTokenIfPossible() }
    }
    #endif
}
