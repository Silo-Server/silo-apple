#if os(iOS) || os(tvOS)
import Foundation

/// tvOS devices only permit writes under Caches; the simulator does not enforce
/// this constraint, so simulator testing cannot catch storage-root regressions.
enum DiagnosticsStorageRoot {
    static func baseDirectory(fileManager: FileManager) -> URL {
#if os(tvOS)
        let searchPathDirectory: FileManager.SearchPathDirectory = .cachesDirectory
#else
        let searchPathDirectory: FileManager.SearchPathDirectory = .applicationSupportDirectory
#endif
        return fileManager.urls(for: searchPathDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }
}
#endif
