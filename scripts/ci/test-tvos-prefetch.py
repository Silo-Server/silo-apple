#!/usr/bin/env python3
"""Exercise the actual tvOS library model with deterministic cache/network spies.

The app has no tvOS XCTest target. Compile its unmodified model body on the
host, replacing only the platform guard and Nuke import; the stubs below keep
this lifecycle regression independent of UIKit, network access and credentials.
"""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = "iosApp/iosApp/tvOS/Screens/Libraries/TVLibraryGridViewModel.swift"

STUBS = r'''
import Foundation

struct BrowseItem { let posterUrl: String? }
struct CatalogResponse {
    let items: [BrowseItem]
    var hasMore: Bool? = true
    var snapshot: String? = nil
}
enum BrowseMediaType { case movie
    static func from(libraryType: String) -> Self { .movie }
}
enum SiloMediaType {
    static func isSeries(_ value: String) -> Bool { false }
    static func isMovieLibrary(_ value: String) -> Bool { true }
}
enum SortOrder { case ascending, descending
    var flipped: Self { self == .ascending ? .descending : .ascending }
}
enum CatalogSortKey { case title, year }
struct CatalogFilterState: Equatable {
    static let none = Self()
    var namePrefix: String? = nil
    var sort: CatalogSortKey = .title
    var order: SortOrder? = nil
    var isDefault: Bool { self == .none }
    var effectiveOrder: SortOrder { order ?? .ascending }
    var cacheKeyFragment: String { "test" }
}
struct CatalogFacets {}
struct ErrorState { init(_ error: Error) {} }
enum CatalogQueryBuilder {
    static func build(_ filter: CatalogFilterState, libraryId: Int,
                      mediaType: BrowseMediaType, offset: Int, limit: Int,
                      snapshot: String?, includeType: Bool) -> [String: String] { [:] }
}
enum CacheKey {
    static func tvLibrary(libraryId: Int, filterKey: String) -> String { "library" }
}
@MainActor final class BrowsePrefsStore {
    static let shared = BrowsePrefsStore()
    func savedState(libraryId: Int) -> CatalogFilterState? { nil }
    func saveState(_ state: CatalogFilterState, libraryId: Int) {}
    func preserveEnabled(libraryId: Int) -> Bool { false }
    func setPreserveEnabled(_ enabled: Bool, libraryId: Int) {}
}
@MainActor final class FacetLoader {
    static let shared = FacetLoader()
    func cachedFacets(libraryId: Int) -> CatalogFacets? { nil }
    func facets(libraryId: Int) async throws -> CatalogFacets { CatalogFacets() }
}
@MainActor final class ResponseCache {
    static let shared = ResponseCache()
    var values: [String: Any] = [:]
    func get<T>(_ key: String) -> T? { values[key] as? T }
    func set<T>(_ value: T, for key: String) { values[key] = value }
}
@MainActor final class ContinuumAPI {
    static let shared = ContinuumAPI()
    var response = CatalogResponse(items: [])
    var onRequest: (() -> Void)?
    func get<T>(_ path: String, query: [String: String]) async throws -> T {
        onRequest?()
        return response as! T
    }
}
final class ImagePipeline { static let shared = ImagePipeline() }
@MainActor final class ImagePrefetcher {
    enum Destination { case diskCache, memoryCache }
    static var latest: ImagePrefetcher!
    let destination: Destination
    let concurrency: Int
    var active: Set<URL> = []
    var started: [URL] = []
    var stopped: Set<URL> = []
    init(pipeline: ImagePipeline, destination: Destination, maxConcurrentRequestCount: Int) {
        self.destination = destination
        concurrency = maxConcurrentRequestCount
        Self.latest = self
    }
    func startPrefetching(with urls: [URL]) {
        started += urls
        active.formUnion(urls)
    }
    func stopPrefetching(with urls: [URL]) {
        stopped.formUnion(urls)
        active.subtract(urls)
    }
    func stopPrefetching() {
        stopped.formUnion(active)
        active.removeAll()
    }
}
'''

TESTS = r'''
@main struct PrefetchRegression {
    @MainActor static var failures = 0

    @MainActor static func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "PASS" : "FAIL"): \(message)")
        if !condition { failures += 1 }
    }

    static func items(_ prefix: String, _ range: Range<Int>) -> [BrowseItem] {
        range.map { BrowseItem(posterUrl: "https://example.invalid/\(prefix)/\($0).jpg") }
    }

    static func urls(_ prefix: String, _ range: Range<Int>) -> Set<URL> {
        Set(items(prefix, range).compactMap { URL(string: $0.posterUrl!) })
    }

    @MainActor static func model(count: Int = 100) -> TVLibraryGridViewModel {
        ResponseCache.shared.values.removeAll()
        ResponseCache.shared.set(CatalogResponse(items: items("old", 0..<count)), for: "library")
        ContinuumAPI.shared.onRequest = nil
        ContinuumAPI.shared.response = CatalogResponse(items: items("new", 0..<count))
        return TVLibraryGridViewModel(libraryId: 1, libraryType: "movies")
    }

    @MainActor static func main() async {
        // Stable row geometry need not emit another visibility callback during
        // a cache-backed reload. Both cache and network replacements must warm.
        let reload = model()
        reload.setPosterRowVisibility(0..<6, isVisible: true)
        let reloadSpy = ImagePrefetcher.latest!
        ResponseCache.shared.set(CatalogResponse(items: items("cached", 0..<100)), for: "library")
        ContinuumAPI.shared.onRequest = {
            check(reloadSpy.active == urls("cached", 0..<18), "cache replacement refreshes without a visibility event")
        }
        await reload.loadInitial()
        check(reloadSpy.active == urls("new", 0..<18), "network replacement refreshes the retained visible window")
        check(reloadSpy.stopped.isSuperset(of: urls("old", 0..<18)), "obsolete poster requests are cancelled")

        let paging = model(count: 6)
        paging.setPosterRowVisibility(0..<6, isVisible: true)
        let pagingSpy = ImagePrefetcher.latest!
        ContinuumAPI.shared.response = CatalogResponse(items: items("old", 6..<18))
        await paging.loadMoreIfNeeded()
        check(pagingSpy.active == urls("old", 0..<18), "appended items enter the nearby prefetch window")

        let leaving = model()
        leaving.setPosterRowVisibility(0..<6, isVisible: true)
        let leavingSpy = ImagePrefetcher.latest!
        ContinuumAPI.shared.onRequest = { leaving.cancelPosterPrefetch() }
        await leaving.loadInitial()
        check(leavingSpy.active.isEmpty, "a response after screen exit does not restart prefetching")

        let shorter = model()
        shorter.setPosterRowVisibility(90..<96, isVisible: true)
        let shorterSpy = ImagePrefetcher.latest!
        ContinuumAPI.shared.response = CatalogResponse(items: items("short", 0..<4))
        await shorter.loadInitial()
        check(shorterSpy.active.isEmpty, "shorter results clamp obsolete high row indices safely")
        shorter.setPosterRowVisibility(0..<4, isVisible: true)
        check(shorterSpy.active == urls("short", 0..<4), "a newly visible short row resumes prefetching")

        let empty = model()
        empty.setPosterRowVisibility(0..<6, isVisible: true)
        let emptySpy = ImagePrefetcher.latest!
        ContinuumAPI.shared.response = CatalogResponse(items: [])
        await empty.loadInitial()
        check(emptySpy.active.isEmpty, "empty replacement cancels all poster requests")

        let scrolling = model(count: 1000)
        let scrollingSpy = ImagePrefetcher.latest!
        scrolling.setPosterRowVisibility(0..<6, isVisible: true)
        let initialStarts = scrollingSpy.started.count
        scrolling.setPosterRowVisibility(0..<6, isVisible: true)
        check(scrollingSpy.started.count == initialStarts, "unchanged visibility does not duplicate requests")
        for start in stride(from: 180, to: 300, by: 6) {
            scrolling.setPosterRowVisibility(start..<(start + 6), isVisible: true)
        }
        check(scrollingSpy.active.count <= 48, "large visibility windows retain the 48-entry cap")
        check(scrollingSpy.concurrency == 2 && scrollingSpy.destination == .memoryCache,
              "prefetch decodes into the memory cache with two concurrent requests")
        scrolling.cancelPosterPrefetch()
        check(scrollingSpy.active.isEmpty, "explicit cancellation stops all work")

        if failures > 0 { exit(1) }
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", help="Read the model from a Git revision for baseline comparison")
    parser.add_argument("--work-dir", default=os.environ.get("RUNNER_TEMP"), help="Parent for temporary compiler files")
    args = parser.parse_args()
    if args.revision:
        source = subprocess.check_output(["git", "show", f"{args.revision}:{SOURCE}"], cwd=ROOT, text=True)
    else:
        source = (ROOT / SOURCE).read_text()
    assert source.startswith("#if os(tvOS)\n") and source.rstrip().endswith("#endif")
    source = source.removeprefix("#if os(tvOS)\n").rstrip().removesuffix("#endif")
    source = source.replace("import Nuke\n", "")
    with tempfile.TemporaryDirectory(prefix="tvos-prefetch-", dir=args.work_dir) as temporary:
        directory = Path(temporary)
        swift = directory / "Regression.swift"
        binary = directory / "regression"
        swift.write_text(STUBS + source + TESTS)
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                        "-module-cache-path", str(directory / "module-cache"),
                        str(swift), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
