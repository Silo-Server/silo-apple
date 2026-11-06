import Foundation
import Observation
import OSLog
import Synchronization
#if canImport(UIKit)
import UIKit
#endif

/// Where a download's media file lives. Everything else about a download
/// (its store record, manifest, artwork, and subtitles) always stays in the
/// app container, so a drive that is not connected never hides or loses a
/// download: only its media goes missing until the drive returns.
enum DownloadMediaVolume: Codable, Hashable, Sendable {
    /// The app container (`DownloadFilePaths.rootDirectory()`).
    case device
    /// A folder the user picked, by `ExternalDownloadLocation.id`.
    case external(id: String)
}

/// A folder outside the app container that the user picked for downloads,
/// usually on a USB drive. The bookmark keeps access to it across launches.
struct ExternalDownloadLocation: Codable, Hashable, Sendable {
    let id: String
    var bookmark: Data
    /// The picked folder's name, for labels while the drive is away.
    var displayName: String
}

/// The folders downloads can be saved to outside the app container, and
/// which of them can be reached right now.
///
/// Every folder ever picked stays registered: a download moved there keeps
/// naming it, and other profiles' stores (not loaded here) may too. Media go
/// in a `Silo Downloads` folder inside the picked folder, laid out like the
/// app container's download tree (see `DownloadFilePaths`).
///
/// Reachability is read with `refreshAvailability()`, never in view bodies:
/// resolving a bookmark and checking a mounted volume are file-system calls.
@MainActor
@Observable
final class ExternalDownloadStorage {
    static let shared = ExternalDownloadStorage()

    private static let logger = Logger.downloads
    nonisolated static let downloadsFolderName = "Silo Downloads"

    /// Where new downloads go; nil for the app container.
    private(set) var currentLocationId: String?
    /// The registered folders that can be read and written now.
    private(set) var availableLocationIds: Set<String> = []
    /// Reachable folders on a drive that can't hold files over 4 GB.
    private(set) var smallFileLimitIds: Set<String> = []

    private var locations: [String: ExternalDownloadLocation]
    /// `<picked folder>/Silo Downloads` of each reachable folder, with
    /// security-scoped access started.
    private var roots: [String: URL] = [:]
    /// Folders whose access was started and must be stopped when they go.
    private var scopedFolders: [String: URL] = [:]
    private var refreshGeneration = 0

    /// The reachable roots and registered folders, readable off the main
    /// actor, and the work folders missed while out of reach.
    nonisolated private static let folderState = Mutex(FolderState(
        registeredIds: Set(loadSavedLocations().map(\.id)),
        work: loadFolderWork()
    ))

    private let defaults = UserDefaults.standard

    private init() {
        let saved = Self.loadSavedLocations()
        locations = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let current = defaults.string(forKey: Keys.currentLocationId)
        currentLocationId = current.flatMap { locations[$0] == nil ? nil : $0 }
    }

    // MARK: - Reading

    /// The volume new downloads move to once they finish.
    var newDownloadVolume: DownloadMediaVolume {
        currentLocationId.map { .external(id: $0) } ?? .device
    }

    func isAvailable(_ volume: DownloadMediaVolume) -> Bool {
        switch volume {
        case .device: return true
        case .external(let id): return availableLocationIds.contains(id)
        }
    }

    /// The root a volume's media tree starts at, when it can be reached.
    /// Path only; reachability is as of the last refresh.
    func downloadsRoot(for volume: DownloadMediaVolume) -> URL? {
        switch volume {
        case .device: return DownloadFilePaths.rootDirectory()
        case .external(let id): return roots[id]
        }
    }


    /// A label for the volume, such as the drive folder's name.
    func displayName(for volume: DownloadMediaVolume) -> String {
        switch volume {
        case .device: return Self.deviceName
        case .external(let id): return locations[id]?.displayName ?? "External Drive"
        }
    }

    static var deviceName: String { "This \(deviceNoun)" }

    static var deviceNoun: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    // MARK: - Choosing

    enum ChooseError: LocalizedError {
        case noAccess
        case cloudFolder
        case readOnly
        case notWritable

        var errorDescription: String? {
            switch self {
            case .noAccess: return "Silo couldn't open that folder."
            case .cloudFolder: return "Choose a folder on an external drive. iCloud Drive can remove downloaded files to save space."
            case .readOnly: return "That drive is read-only. Drives formatted as NTFS can't be written on this device."
            case .notWritable: return "Silo couldn't save files in that folder."
            }
        }
    }

    /// Registers a folder from the system folder picker and makes it where
    /// new downloads go. Reuses the registration of a folder picked before,
    /// so downloads already there keep their volume.
    func choose(folder: URL) throws {
        let scoped = folder.startAccessingSecurityScopedResource()
        var keepAccess = false
        defer { if scoped && !keepAccess { folder.stopAccessingSecurityScopedResource() } }

        let values = try? folder.resourceValues(
            forKeys: [.isUbiquitousItemKey, .volumeIsReadOnlyKey, .localizedNameKey]
        )
        if values?.isUbiquitousItem == true { throw ChooseError.cloudFolder }
        if values?.volumeIsReadOnly == true { throw ChooseError.readOnly }

        let root = folder.appendingPathComponent(Self.downloadsFolderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Picked download folder is not writable: \(String(describing: error), privacy: .public)")
            throw ChooseError.notWritable
        }
        guard let bookmark = try? folder.bookmarkData(options: Self.bookmarkOptions,
                                                      includingResourceValuesForKeys: nil, relativeTo: nil)
        else { throw ChooseError.noAccess }

        let path = folder.standardizedFileURL.path
        let existing = locations.values.first { registeredPath(of: $0) == path }
        // A refresh still resolving would apply what it saw before this choice.
        refreshGeneration += 1
        let location = ExternalDownloadLocation(
            id: existing?.id ?? UUID().uuidString,
            bookmark: bookmark,
            // A drive's root folder is named after the drive.
            displayName: values?.localizedName ?? folder.lastPathComponent
        )
        locations[location.id] = location
        if let previous = scopedFolders[location.id], previous != folder {
            previous.stopAccessingSecurityScopedResource()
            scopedFolders[location.id] = nil
        }
        if scoped {
            keepAccess = scopedFolders[location.id] == nil
            if keepAccess { scopedFolders[location.id] = folder }
        }
        roots[location.id] = root
        availableLocationIds.insert(location.id)
        if Self.hasSmallFileLimit(folder) {
            smallFileLimitIds.insert(location.id)
        } else {
            smallFileLimitIds.remove(location.id)
        }
        currentLocationId = location.id
        publishRoots()
        save()
    }

    /// Makes the app container where new downloads go. Registered folders
    /// stay, so downloads already on a drive still play from it.
    func useDeviceStorage() {
        currentLocationId = nil
        save()
    }

    /// Whether files over 4 GB can't be saved in the folder (FAT32 and
    /// older FAT formats). Unknown formats count as able.
    nonisolated static func hasSmallFileLimit(_ folder: URL) -> Bool {
        let format = (try? folder.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey]))?
            .volumeLocalizedFormatDescription ?? ""
        return format.localizedCaseInsensitiveContains("MS-DOS") || format.localizedCaseInsensitiveContains("FAT32")
    }

    // MARK: - Availability

    /// Re-reads which registered folders can be reached. Bookmarks resolve
    /// off the main actor; a drive that went away loses its access, and one
    /// that came back gets it again.
    func refreshAvailability() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let snapshot = Array(locations.values)
        let held = scopedFolders
        let resolved = await Task.detached(priority: .utility) {
            snapshot.map { location in
                var result = Self.resolve(location, holding: held[location.id])
                // Work missed while away runs before anything uses the folder,
                // and a folder whose work can't finish stays out of use: its
                // media may not be where the records look yet.
                if result.reachable, let folder = result.folder,
                   !Self.catchUp(locationId: location.id,
                                 root: folder.appendingPathComponent(Self.downloadsFolderName, isDirectory: true)) {
                    result.reachable = false
                }
                return result
            }
        }.value
        guard generation == refreshGeneration else {
            // A newer refresh owns the outcome; drop access this one started.
            for result in resolved where result.startedAccess { result.folder?.stopAccessingSecurityScopedResource() }
            return
        }
        var available: Set<String> = []
        var smallFileLimit: Set<String> = []
        for result in resolved {
            let id = result.id
            if let refreshed = result.refreshedBookmark, var location = locations[id] {
                location.bookmark = refreshed
                locations[id] = location
            }
            if let folder = result.folder, result.reachable {
                if result.startedAccess {
                    scopedFolders[id]?.stopAccessingSecurityScopedResource()
                    scopedFolders[id] = folder
                }
                roots[id] = folder.appendingPathComponent(Self.downloadsFolderName, isDirectory: true)
                available.insert(id)
                if result.smallFileLimit { smallFileLimit.insert(id) }
            } else {
                if result.startedAccess { result.folder?.stopAccessingSecurityScopedResource() }
                scopedFolders[id]?.stopAccessingSecurityScopedResource()
                scopedFolders[id] = nil
                roots[id] = nil
            }
        }
        if available != availableLocationIds { availableLocationIds = available }
        if smallFileLimit != smallFileLimitIds { smallFileLimitIds = smallFileLimit }
        publishRoots()
        if resolved.contains(where: { $0.refreshedBookmark != nil }) { save() }
    }

    private struct Resolution: Sendable {
        let id: String
        let folder: URL?
        var reachable: Bool
        let startedAccess: Bool
        let refreshedBookmark: Data?
        var smallFileLimit = false
    }

    /// Resolves a bookmark and checks the folder is there. A folder already
    /// held keeps its access while it stays reachable.
    nonisolated private static func resolve(_ location: ExternalDownloadLocation, holding: URL?) -> Resolution {
        if let holding, isReachable(holding) {
            return Resolution(id: location.id, folder: holding, reachable: true, startedAccess: false,
                              refreshedBookmark: nil, smallFileLimit: hasSmallFileLimit(holding))
        }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: location.bookmark, options: resolveOptions,
                                    relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return Resolution(id: location.id, folder: nil, reachable: false, startedAccess: false,
                              refreshedBookmark: nil)
        }
        let started = folder.startAccessingSecurityScopedResource()
        let reachable = isReachable(folder)
        var refreshed: Data?
        if stale, reachable {
            refreshed = try? folder.bookmarkData(options: bookmarkOptions, includingResourceValuesForKeys: nil,
                                                 relativeTo: nil)
        }
        return Resolution(id: location.id, folder: folder, reachable: reachable, startedAccess: started,
                          refreshedBookmark: refreshed, smallFileLimit: reachable && hasSmallFileLimit(folder))
    }

    nonisolated private static func isReachable(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The folder a registration names: its reachable root, or else where
    /// its bookmark resolves now.
    private func registeredPath(of location: ExternalDownloadLocation) -> String? {
        if let root = roots[location.id] {
            return root.deletingLastPathComponent().standardizedFileURL.path
        }
        var stale = false
        return (try? URL(resolvingBookmarkData: location.bookmark, options: Self.resolveOptions,
                         relativeTo: nil, bookmarkDataIsStale: &stale))?.standardizedFileURL.path
    }

    // MARK: - Persistence

    private func publishRoots() {
        let snapshot = roots
        let registered = Set(locations.keys)
        Self.folderState.withLock {
            $0.roots = snapshot
            $0.registeredIds = registered
        }
    }

    nonisolated private static func loadSavedLocations() -> [ExternalDownloadLocation] {
        UserDefaults.standard.data(forKey: Keys.locations)
            .flatMap { try? JSONDecoder().decode([ExternalDownloadLocation].self, from: $0) } ?? []
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Array(locations.values)) {
            defaults.set(data, forKey: Keys.locations)
        }
        defaults.set(currentLocationId, forKey: Keys.currentLocationId)
    }

    #if os(macOS)
    nonisolated private static let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    nonisolated private static let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    nonisolated private static let bookmarkOptions: URL.BookmarkCreationOptions = []
    nonisolated private static let resolveOptions: URL.BookmarkResolutionOptions = []
    #endif

    private enum Keys {
        static let locations = "downloads.externalLocations"
        static let currentLocationId = "downloads.externalCurrentLocationId"
        static let folderWork = "downloads.externalFolderWork"
    }

    // MARK: - Work for every folder

    /// Removes a path, relative to the download tree, from every registered
    /// folder: now from those in reach, and from the rest when they are next
    /// found in reach.
    nonisolated static func removeFromExternalFolders(_ relativePath: String) {
        schedule(.remove(path: relativePath))
    }

    /// Merges one path of the download tree into another in every
    /// registered folder, like `removeFromExternalFolders`. Where both hold a
    /// file, the destination's stays: a server merge keeps the surviving
    /// account's records, so its media is the one they name.
    nonisolated static func moveInExternalFolders(from source: String, to destination: String) {
        schedule(.move(from: source, to: destination))
    }

    struct FolderWork: Codable, Sendable {
        enum Action: Codable, Sendable {
            case remove(path: String)
            case move(from: String, to: String)
        }
        var id = UUID()
        let action: Action
        var waitingLocationIds: Set<String>
    }

    private struct FolderState: Sendable {
        var roots: [String: URL] = [:]
        var registeredIds: Set<String>
        var work: [FolderWork]
    }

    /// A folder that still has earlier work waiting gets this action queued
    /// behind it, never run ahead: a retried move must not bring back media
    /// that a later removal deleted.
    nonisolated private static func schedule(_ action: FolderWork.Action) {
        let (roots, registered, behind) = folderState.withLock { state in
            (state.roots, state.registeredIds, state.work.reduce(into: Set<String>()) { $0.formUnion($1.waitingLocationIds) })
        }
        let waiting = registered.filter { id in
            guard let root = roots[id], !behind.contains(id) else { return true }
            return !perform(action, at: root)
        }
        guard !waiting.isEmpty else { return }
        folderState.withLock { state in
            state.work.append(FolderWork(action: action, waitingLocationIds: Set(waiting)))
            saveFolderWork(state.work)
        }
    }

    /// Runs, in order, the work a folder missed while out of reach. Stops at
    /// the first step that fails, so later steps never run ahead of it.
    /// Returns whether none is left.
    nonisolated private static func catchUp(locationId: String, root: URL) -> Bool {
        let pending = folderState.withLock { $0.work.filter { $0.waitingLocationIds.contains(locationId) } }
        var done: Set<UUID> = []
        for work in pending {
            guard perform(work.action, at: root) else { break }
            done.insert(work.id)
        }
        guard !done.isEmpty else { return pending.isEmpty }
        folderState.withLock { state in
            for index in state.work.indices where done.contains(state.work[index].id) {
                state.work[index].waitingLocationIds.remove(locationId)
            }
            state.work.removeAll { $0.waitingLocationIds.isEmpty }
            saveFolderWork(state.work)
        }
        return done.count == pending.count
    }

    /// Whether the action's outcome now holds in the download tree at `root`.
    nonisolated static func perform(_ action: FolderWork.Action, at root: URL) -> Bool {
        guard DownloadMediaTransfer.isReachable(root) else { return false }
        let fm = FileManager.default
        switch action {
        case .remove(let path):
            let url = root.appendingPathComponent(path)
            try? fm.removeItem(at: url)
            return !fm.fileExists(atPath: url.path)
        case .move(let from, let to):
            let source = root.appendingPathComponent(from)
            guard fm.fileExists(atPath: source.path) else { return true }
            return DownloadFilePaths.merge(source, into: root.appendingPathComponent(to), keepingDestination: true)
        }
    }

    nonisolated private static func loadFolderWork() -> [FolderWork] {
        UserDefaults.standard.data(forKey: Keys.folderWork)
            .flatMap { try? JSONDecoder().decode([FolderWork].self, from: $0) } ?? []
    }

    nonisolated private static func saveFolderWork(_ work: [FolderWork]) {
        if work.isEmpty {
            UserDefaults.standard.removeObject(forKey: Keys.folderWork)
        } else if let data = try? JSONEncoder().encode(work) {
            UserDefaults.standard.set(data, forKey: Keys.folderWork)
        }
    }
}
