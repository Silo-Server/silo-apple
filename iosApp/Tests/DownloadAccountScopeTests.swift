#if !os(tvOS)
import Foundation
import XCTest
@testable import Silo

/// Downloads keyed by server, account, and profile. Before this, two
/// accounts on one server whose profiles are both `default` shared one
/// store and one directory (plan §1.8). Downloads saved before accounts move
/// to the account that owns their server's older data, and tags written
/// before accounts follow them there.
final class DownloadAccountScopeTests: XCTestCase {
    private static let server = "server-1"
    private static let alex = "12"
    private static let sam = "13"

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadAccountScopeTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("SiloDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    /// Alex owns the server's downloads from before accounts.
    private func makeStore() -> DownloadStore {
        let root: URL = self.root
        return DownloadStore(rootDirectory: { root }, legacyOwner: { $0 == Self.server ? Self.alex : nil })
    }

    private func scope(_ account: String?) -> URL {
        DownloadFilePaths.scopePath(serverId: Self.server, accountId: account, profileId: "default", root: root)
    }

    private func file(deleting ids: Set<String>) -> DownloadStoreFile {
        var file = DownloadStoreFile.empty
        file.pendingServerDeletes = ids
        return file
    }

    // MARK: - Layout

    func testEachAccountHasItsOwnDirectoryAndAnUnknownAccountKeepsTheOldOne() {
        XCTAssertEqual(scope(nil).path, root.appendingPathComponent("server-1/default").path)
        XCTAssertEqual(scope(Self.alex).path, root.appendingPathComponent("server-1/acct-12/default").path)
        XCTAssertNotEqual(scope(Self.alex), scope(Self.sam))
        let alexMedia = DownloadFilePaths.fileURL(serverId: Self.server, accountId: Self.alex, profileId: "default",
                                                  downloadId: "d1", filename: "media.mp4")
        let samMedia = DownloadFilePaths.fileURL(serverId: Self.server, accountId: Self.sam, profileId: "default",
                                                 downloadId: "d1", filename: "media.mp4")
        XCTAssertNotEqual(alexMedia, samMedia)
        XCTAssertTrue(alexMedia.path.hasSuffix("server-1/acct-12/default/d1/media.mp4"))
    }

    // MARK: - The leak

    /// Signing out of one account and into another on the same server used
    /// to show the first account's downloads to the second account's
    /// `default` profile.
    func testAnotherAccountsMatchingProfileNeverSeesTheseDownloads() async {
        let store = makeStore()
        await store.save(file(deleting: ["alex-download"]), serverId: Self.server, accountId: Self.alex,
                         profileId: "default")

        let samFile = await store.load(serverId: Self.server, accountId: Self.sam, profileId: "default")
        XCTAssertNil(samFile.pendingServerDeletes)
        await store.save(file(deleting: ["sam-download"]), serverId: Self.server, accountId: Self.sam,
                         profileId: "default")

        let alexFile = await makeStore().load(serverId: Self.server, accountId: Self.alex, profileId: "default")
        let samAgain = await makeStore().load(serverId: Self.server, accountId: Self.sam, profileId: "default")
        XCTAssertEqual(alexFile.pendingServerDeletes, ["alex-download"])
        XCTAssertEqual(samAgain.pendingServerDeletes, ["sam-download"])
    }

    func testAScopeWithoutAnAccountReadsAndWritesAsBefore() async throws {
        try FileManager.default.createDirectory(at: scope(nil), withIntermediateDirectories: true)
        try JSONEncoder().encode(file(deleting: ["old"]))
            .write(to: scope(nil).appendingPathComponent(DownloadFilePaths.storeFileName))

        let store = makeStore()
        let loaded = await store.load(serverId: Self.server, accountId: nil, profileId: "default")
        XCTAssertEqual(loaded.pendingServerDeletes, ["old"])
        await store.save(file(deleting: ["old", "new"]), serverId: Self.server, accountId: nil, profileId: "default")
        let reloaded = await store.load(serverId: Self.server, accountId: nil, profileId: "default")
        XCTAssertEqual(reloaded.pendingServerDeletes, ["old", "new"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: scope(Self.alex).path))
    }

    // MARK: - Moving downloads saved before accounts

    func testTheLegacyOwnerTakesOverTheOldDirectoryAndNoOneElseReadsIt() async throws {
        let old = scope(nil)
        let media = old.appendingPathComponent("d1", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data("media".utf8).write(to: media.appendingPathComponent("media.mp4"))
        try JSONEncoder().encode(file(deleting: ["old"]))
            .write(to: old.appendingPathComponent(DownloadFilePaths.storeFileName))
        let store = makeStore()

        let samFile = await store.load(serverId: Self.server, accountId: Self.sam, profileId: "default")
        XCTAssertNil(samFile.pendingServerDeletes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.appendingPathComponent("media.mp4").path),
                      "another account leaves the old directory alone")

        let alexFile = await store.load(serverId: Self.server, accountId: Self.alex, profileId: "default")
        XCTAssertEqual(alexFile.pendingServerDeletes, ["old"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(try Data(contentsOf: scope(Self.alex).appendingPathComponent("d1/media.mp4")), Data("media".utf8))

        await store.save(file(deleting: ["old", "new"]), serverId: Self.server, accountId: Self.alex, profileId: "default")
        let reloaded = await makeStore().load(serverId: Self.server, accountId: Self.alex, profileId: "default")
        XCTAssertEqual(reloaded.pendingServerDeletes, ["old", "new"])
    }

    /// A transfer started before accounts can finish after the move, while
    /// its server's legacy owner isn't known yet in that process, and park
    /// in the old directory. The owner's next load brings it in.
    func testATransferParkedInTheOldDirectoryAfterTheMoveFollows() async throws {
        let store = makeStore()
        await store.save(file(deleting: ["mine"]), serverId: Self.server, accountId: Self.alex, profileId: "default")
        let parked = scope(nil).appendingPathComponent("d2", isDirectory: true)
        try FileManager.default.createDirectory(at: parked, withIntermediateDirectories: true)
        try Data("late".utf8).write(to: parked.appendingPathComponent(DownloadFilePaths.finishedTransferFilename))

        let loaded = await store.load(serverId: Self.server, accountId: Self.alex, profileId: "default")
        XCTAssertEqual(loaded.pendingServerDeletes, ["mine"], "the account's own store wins")
        let finished = DownloadFilePaths.finishedTransfers(serverId: Self.server, accountId: Self.alex,
                                                           profileId: "default", root: root)
        XCTAssertEqual(Array(finished.keys), ["d2"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: scope(nil).path))
    }

    /// When the old directory can't move, the scope loads empty and never
    /// saves over the downloads still waiting there.
    func testAFailedMoveLeavesTheOldDownloadsAndSavesNothing() async throws {
        try FileManager.default.createDirectory(at: scope(nil), withIntermediateDirectories: true)
        try JSONEncoder().encode(file(deleting: ["old"]))
            .write(to: scope(nil).appendingPathComponent(DownloadFilePaths.storeFileName))
        // A file where the account's directory belongs.
        let blocker = scope(Self.alex).deletingLastPathComponent()
        try Data().write(to: blocker)
        let store = makeStore()

        let loaded = await store.loadScope(serverId: Self.server, accountId: Self.alex, profileId: "default")
        XCTAssertNil(loaded.file.pendingServerDeletes)
        XCTAssertFalse(loaded.isComplete, "the manager deletes nothing in an incomplete scope")
        await store.save(file(deleting: ["new"]), serverId: Self.server, accountId: Self.alex, profileId: "default")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: scope(nil).appendingPathComponent(DownloadFilePaths.storeFileName).path))

        try FileManager.default.removeItem(at: blocker)
        let retried = await store.loadScope(serverId: Self.server, accountId: Self.alex, profileId: "default")
        XCTAssertEqual(retried.file.pendingServerDeletes, ["old"], "the next load moves it")
        XCTAssertTrue(retried.isComplete)
    }

    /// Early in a launch the account's scope loads before the legacy owners
    /// are published, finds no store, and saves one at once. When the owner
    /// is known, the old store must replace that empty file, not lose to it.
    func testAnEmptyStoreSavedBeforeTheOwnerWasKnownGivesWayToTheOldOne() async throws {
        let old = scope(nil)
        let media = old.appendingPathComponent("d1", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data("media".utf8).write(to: media.appendingPathComponent("media.mp4"))
        try JSONEncoder().encode(file(deleting: ["old"]))
            .write(to: old.appendingPathComponent(DownloadFilePaths.storeFileName))
        let owner = OwnerBox()
        let root: URL = self.root
        let store = DownloadStore(rootDirectory: { root }, legacyOwner: { _ in owner.value })

        let early = await store.load(serverId: Self.server, accountId: Self.alex, profileId: "default")
        XCTAssertNil(early.pendingServerDeletes)
        var bookkeeping = DownloadStoreFile.empty
        bookkeeping.taskSessionIdentifier = "session"
        await store.save(bookkeeping, serverId: Self.server, accountId: Self.alex, profileId: "default")

        owner.value = Self.alex
        let loaded = await store.load(serverId: Self.server, accountId: Self.alex, profileId: "default")
        XCTAssertEqual(loaded.pendingServerDeletes, ["old"])
        XCTAssertEqual(try Data(contentsOf: scope(Self.alex).appendingPathComponent("d1/media.mp4")), Data("media".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    /// A store left in the old place after the move (a save that landed
    /// late) loses to the account's own, and goes, so the old directory
    /// doesn't linger.
    func testTheAccountsOwnStoreWinsAndAStaleOldCopyIsRemoved() async throws {
        let store = makeStore()
        await store.save(file(deleting: ["mine"]), serverId: Self.server, accountId: Self.alex, profileId: "default")
        try FileManager.default.createDirectory(at: scope(nil), withIntermediateDirectories: true)
        try JSONEncoder().encode(file(deleting: ["stale"]))
            .write(to: scope(nil).appendingPathComponent(DownloadFilePaths.storeFileName))

        let loaded = await store.load(serverId: Self.server, accountId: Self.alex, profileId: "default")
        XCTAssertEqual(loaded.pendingServerDeletes, ["mine"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: scope(nil).path))
    }

    /// An account store that doesn't decode is set aside, as a load would,
    /// and the old store moves in instead of being merged away.
    func testAnUndecodableAccountStoreIsSetAsideAndTheOldOneMovesIn() async throws {
        try FileManager.default.createDirectory(at: scope(nil), withIntermediateDirectories: true)
        try JSONEncoder().encode(file(deleting: ["old"]))
            .write(to: scope(nil).appendingPathComponent(DownloadFilePaths.storeFileName))
        try FileManager.default.createDirectory(at: scope(Self.alex), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: scope(Self.alex).appendingPathComponent(DownloadFilePaths.storeFileName))

        let loaded = await makeStore().load(serverId: Self.server, accountId: Self.alex, profileId: "default")
        XCTAssertEqual(loaded.pendingServerDeletes, ["old"])
        let names = try FileManager.default.contentsOfDirectory(atPath: scope(Self.alex).path)
        XCTAssertEqual(names.filter { $0.hasPrefix("\(DownloadFilePaths.storeFileName).corrupt-") }.count, 1)
    }

    /// A transfer tagged before accounts can finish once its tag names the
    /// owner but before the owner's load moved the old directory, so its
    /// download directory doesn't exist yet in the account's scope. Parking
    /// creates it, and the load brings the rest of the download in.
    func testAFinishedTransferParksBeforeItsDownloadDirectoryMoved() async throws {
        let oldDownload = scope(nil).appendingPathComponent("d1", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDownload, withIntermediateDirectories: true)
        try Data("manifest".utf8).write(to: oldDownload.appendingPathComponent("manifest.json"))
        try JSONEncoder().encode(file(deleting: ["old"]))
            .write(to: scope(nil).appendingPathComponent(DownloadFilePaths.storeFileName))
        let transfer = root.deletingLastPathComponent().appendingPathComponent("transfer.tmp")
        try Data("bytes".utf8).write(to: transfer)
        let parked = scope(Self.alex)
            .appendingPathComponent("d1", isDirectory: true)
            .appendingPathComponent(DownloadFilePaths.finishedTransferFilename)

        try DownloadFilePaths.park(transfer, at: parked)
        XCTAssertEqual(try Data(contentsOf: parked), Data("bytes".utf8))

        let loaded = await makeStore().load(serverId: Self.server, accountId: Self.alex, profileId: "default")
        XCTAssertEqual(loaded.pendingServerDeletes, ["old"])
        XCTAssertEqual(try Data(contentsOf: scope(Self.alex).appendingPathComponent("d1/manifest.json")),
                       Data("manifest".utf8))
        let finished = DownloadFilePaths.finishedTransfers(serverId: Self.server, accountId: Self.alex,
                                                           profileId: "default", root: root)
        XCTAssertEqual(Array(finished.keys), ["d1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: scope(nil).path))
    }

    /// The reverse: the old directory already moved and the tag still
    /// names it. Parking recreates it; the owner's next load follows it.
    func testAFinishedTransferParksAfterTheOldDirectoryMoved() throws {
        let transfer = root.deletingLastPathComponent().appendingPathComponent("transfer.tmp")
        try Data("bytes".utf8).write(to: transfer)
        let parked = scope(nil)
            .appendingPathComponent("d2", isDirectory: true)
            .appendingPathComponent(DownloadFilePaths.finishedTransferFilename)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scope(nil).path))

        try DownloadFilePaths.park(transfer, at: parked)
        XCTAssertEqual(try Data(contentsOf: parked), Data("bytes".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transfer.path))
    }

    // MARK: - Task tags

    func testATagWithAnAccountRoundTripsAsVersionTwo() throws {
        let tag = DownloadTaskTag(serverId: Self.server, accountId: Self.alex, profileId: "default", downloadId: "d.1")
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(tag.taskDescription.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["v"] as? Int, 2)
        XCTAssertEqual(payload["account"] as? String, Self.alex)
        XCTAssertEqual(DownloadTaskTag(taskDescription: tag.taskDescription), tag)
        XCTAssertNil(DownloadTaskTag(taskDescription: #"{"v":2,"server":"s","profile":"p","download":"d"}"#),
                     "a version 2 tag must name its account")
        XCTAssertNil(DownloadTaskTag(taskDescription: #"{"v":3,"server":"s","account":"12","profile":"p","download":"d"}"#))
    }

    func testATagWithoutAnAccountKeepsTheVersionOneForm() {
        let tag = DownloadTaskTag(serverId: "s", accountId: nil, profileId: "p", downloadId: "d")
        XCTAssertEqual(tag.taskDescription, #"{"download":"d","profile":"p","server":"s","v":1}"#)
    }

    func testAVersionOneTagGoesToItsServersLegacyOwner() throws {
        let earlier = #"{"download":"d1","profile":"default","server":"server-1","v":1}"#
        let decoded = try XCTUnwrap(DownloadTaskTag(taskDescription: earlier))
        XCTAssertNil(decoded.accountId)

        let owner: AccountScopedKeyAdoption.LegacyOwner = { $0 == Self.server ? Self.alex : nil }
        let attributed = decoded.attributedToLegacyOwner(owner)
        XCTAssertEqual(attributed, DownloadTaskTag(serverId: Self.server, accountId: Self.alex, profileId: "default",
                                                   downloadId: "d1"))
        XCTAssertEqual(decoded.attributedToLegacyOwner { _ in nil }, decoded, "without an owner it stays account-less")
        let samTag = DownloadTaskTag(serverId: Self.server, accountId: Self.sam, profileId: "default", downloadId: "d1")
        XCTAssertEqual(samTag.attributedToLegacyOwner(owner), samTag, "a tag that names its account keeps it")
        XCTAssertTrue(DownloadFilePaths.finishedTransferURL(for: attributed).path
            .hasSuffix("server-1/acct-12/default/d1/\(DownloadFilePaths.finishedTransferFilename)"))
    }

    func testAnUntaggedTransferIsAttributedToTheLegacyOwner() throws {
        let serverURL = "https://silo.example"
        let fileURL = try XCTUnwrap(APIv2Client.downloadFileURL(id: "d1", serverURL: serverURL))
        let tag = DownloadTaskTag.attributing(requestURL: fileURL, profileId: "default",
                                              servers: [(id: Self.server, url: serverURL)],
                                              legacyOwner: { $0 == Self.server ? Self.alex : nil })
        XCTAssertEqual(tag, DownloadTaskTag(serverId: Self.server, accountId: Self.alex, profileId: "default",
                                            downloadId: "d1"))
    }

    // MARK: - Routing events to the loaded scope

    func testAFinishedTransferReachesOnlyItsOwnAccountsRecord() {
        let alexTag = DownloadTaskTag(serverId: Self.server, accountId: Self.alex, profileId: "default", downloadId: "d1")
        let samTag = DownloadTaskTag(serverId: Self.server, accountId: Self.sam, profileId: "default", downloadId: "d1")
        let legacyTag = DownloadTaskTag(serverId: Self.server, accountId: nil, profileId: "default", downloadId: "d1")

        func disposition(_ tag: DownloadTaskTag, loadedAccount: String?) -> DownloadManager.FinishedTransferDisposition {
            DownloadManager.finishedTransferDisposition(tag: tag, loadedServerId: Self.server,
                                                        loadedAccountId: loadedAccount, loadedProfileId: "default",
                                                        record: nil)
        }
        XCTAssertEqual(disposition(samTag, loadedAccount: Self.alex), .keepForOwner)
        XCTAssertEqual(disposition(alexTag, loadedAccount: Self.sam), .keepForOwner)
        XCTAssertEqual(disposition(legacyTag, loadedAccount: Self.alex), .keepForOwner,
                       "routing takes a tag as given; the manager attributes an account-less one first")
        XCTAssertEqual(disposition(alexTag, loadedAccount: Self.alex), .discardDirectory, "owned, with no record")
        XCTAssertEqual(disposition(legacyTag, loadedAccount: nil), .discardDirectory)

        let live = DownloadManager.liveTaskIds(loadedServerId: Self.server, loadedAccountId: Self.alex,
                                               loadedProfileId: "default",
                                               tasks: [(taskId: 4, tag: samTag), (taskId: 5, tag: alexTag)])
        XCTAssertEqual(live, ["d1": 5])
    }

    /// A scope whose store couldn't be read or moved loads empty, so it can't
    /// tell a leftover from a download only the unread store knows. A live
    /// finish or the parked-file settle then keeps the file parked instead
    /// of deleting it or its download directory; a record of this session
    /// that is waiting for it still takes it.
    func testAStoreThatDidNotLoadDeletesNothing() {
        let tag = DownloadTaskTag(serverId: Self.server, accountId: Self.alex, profileId: "default", downloadId: "d1")
        func disposition(_ status: LocalDownloadStatus?, complete: Bool) -> DownloadManager.FinishedTransferDisposition {
            DownloadManager.finishedTransferDisposition(tag: tag, loadedServerId: Self.server,
                                                        loadedAccountId: Self.alex, loadedProfileId: "default",
                                                        record: status.map(Self.record), storeIsComplete: complete)
        }
        XCTAssertEqual(disposition(nil, complete: true), .discardDirectory)
        XCTAssertEqual(disposition(nil, complete: false), .keepForOwner, "no record: the directory stays")
        XCTAssertEqual(disposition(.queued, complete: true), .discardFile)
        XCTAssertEqual(disposition(.queued, complete: false), .keepForOwner, "unwanted: the file stays parked")
        XCTAssertEqual(disposition(.downloading, complete: false), .complete)
        XCTAssertEqual(disposition(.paused, complete: false), .complete)
    }

    private static func record(_ status: LocalDownloadStatus) -> DownloadRecord {
        DownloadRecord(
            id: "d1", contentId: "c1", episodeId: nil, batchId: nil, mediaFileId: "0", format: "original",
            serverStatus: "ready", localStatus: status, fileSize: 1_000, bytesDownloaded: 0,
            mediaFilename: nil, manifestFilename: nil, posterFilename: nil, backdropFilename: nil,
            logoFilename: nil, subtitleFilenames: [:], title: "Title", subtitle: nil, type: "movie",
            seriesId: nil, seriesTitle: nil, posterThumbhash: nil, container: nil, stableIdentity: nil,
            registeredAt: Date(timeIntervalSinceReferenceDate: 1_000), downloadedAt: nil, lastError: nil,
            retryCount: 0, taskIdentifier: 5
        )
    }
}

/// The legacy owner as a test changes it, read from the store's actor.
private final class OwnerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
#endif
