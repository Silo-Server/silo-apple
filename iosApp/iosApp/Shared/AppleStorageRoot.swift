import Foundation
import OSLog

/// One platform rule for every app-private durable file this client writes.
///
/// tvOS devices only permit writes under Caches. Application Support writes
/// fail there with `NSCocoaErrorDomain` 513, and the tvOS simulator does not
/// enforce the constraint, so simulator testing cannot catch a regression.
/// Every other platform uses Application Support, which the OS does not purge
/// under storage pressure.
///
/// This type is deliberately unguarded by `#if os(...)`: the iOS, tvOS, and
/// macOS targets all compile callers of it.
enum AppleStorageRoot {
    /// Storage category selected by the platform rule. Only the category name is
    /// safe to log; a container path identifies the installation and is not.
    enum Category: String {
        case caches
        case applicationSupport

        var searchPathDirectory: FileManager.SearchPathDirectory {
            switch self {
            case .caches: return .cachesDirectory
            case .applicationSupport: return .applicationSupportDirectory
            }
        }
    }

    static var category: Category {
#if os(tvOS)
        .caches
#else
        .applicationSupport
#endif
    }

    static func baseDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: category.searchPathDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    /// Records which category the platform rule chose, by name only. Diagnosing
    /// a storage-root regression needs the category, never the private path.
    static func logSelectedCategory(subsystemCategory: String) {
        Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
            category: subsystemCategory
        ).log("storage root category=\(category.rawValue, privacy: .public)")
    }
}
