import Foundation

/// Device-level download preferences. Persisted to `UserDefaults` in each
/// property's `didSet`, mirroring the `PlayerSettings` convention. These
/// are local decisions (not server-synced): the download quality to
/// request, whether to restrict to Wi-Fi, and the defaults used when
/// creating a new series-monitoring subscription.
@Observable
final class DownloadSettings {
    static let shared = DownloadSettings()

    /// Requested download quality. Coerced to `original` if the active
    /// server doesn't currently offer the stored choice.
    var preferredFormat: String {
        didSet { defaults.set(preferredFormat, forKey: Keys.preferredFormat) }
    }

    /// When true, downloads only transfer over Wi-Fi.
    var wifiOnly: Bool {
        didSet { defaults.set(wifiOnly, forKey: Keys.wifiOnly) }
    }

    /// Default `delete_watched` for new subscriptions.
    var defaultDeleteWatched: Bool {
        didSet { defaults.set(defaultDeleteWatched, forKey: Keys.defaultDeleteWatched) }
    }

    /// Default per-subscription storage cap in GB. `0` = unlimited.
    var defaultMaxStorageGB: Int {
        didSet { defaults.set(defaultMaxStorageGB, forKey: Keys.defaultMaxStorageGB) }
    }

    /// Last-chosen ordering for the Downloads Manager list.
    var sortOption: DownloadSortOption {
        didSet { defaults.set(sortOption.rawValue, forKey: Keys.sortOption) }
    }

    /// When true, suppress the "Free up space" reclaim suggestion (the user
    /// prefers to keep watched downloads around).
    var keepWatchedDownloads: Bool {
        didSet { defaults.set(keepWatchedDownloads, forKey: Keys.keepWatchedDownloads) }
    }

    /// How many downloads transfer at once. Two keep a typical connection
    /// busy while each file, and the first episode of a season, still
    /// finishes soon; more split the bandwidth without adding much.
    var simultaneousDownloads: Int {
        didSet { defaults.set(simultaneousDownloads, forKey: Keys.simultaneousDownloads) }
    }

    static let simultaneousDownloadChoices = [1, 2, 3, 4]

    private let defaults: UserDefaults

    /// Internal so tests can verify the contract-known local preferences in an
    /// isolated defaults domain instead of mutating the app-wide singleton.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.preferredFormat: DownloadFormat.original.rawValue,
            Keys.wifiOnly: true,
            Keys.defaultDeleteWatched: false,
            Keys.defaultMaxStorageGB: 0,
            Keys.sortOption: DownloadSortOption.largestFirst.rawValue,
            Keys.keepWatchedDownloads: false,
            Keys.simultaneousDownloads: 2,
        ])
        preferredFormat = defaults.string(forKey: Keys.preferredFormat) ?? DownloadFormat.original.rawValue
        wifiOnly = defaults.bool(forKey: Keys.wifiOnly)
        defaultDeleteWatched = defaults.bool(forKey: Keys.defaultDeleteWatched)
        defaultMaxStorageGB = defaults.integer(forKey: Keys.defaultMaxStorageGB)
        sortOption = defaults.string(forKey: Keys.sortOption)
            .flatMap(DownloadSortOption.init(rawValue:)) ?? .largestFirst
        keepWatchedDownloads = defaults.bool(forKey: Keys.keepWatchedDownloads)
        simultaneousDownloads = min(
            max(1, defaults.integer(forKey: Keys.simultaneousDownloads)),
            Self.simultaneousDownloadChoices.last ?? 4
        )
    }

    /// The quality to actually request, given what the server offers right
    /// now. Falls back to `original`, which should always be available.
    func resolvedFormat(allowedFormats: [String]) -> String {
        if allowedFormats.contains(preferredFormat) {
            return preferredFormat
        }
        return DownloadFormat.original.rawValue
    }

    /// Bytes per gigabyte (GiB), shared by the storage-cap conversions.
    static let bytesPerGB: Int64 = 1_073_741_824

    private enum Keys {
        static let preferredFormat = "downloads.preferredFormat"
        static let wifiOnly = "downloads.wifiOnly"
        static let defaultDeleteWatched = "downloads.defaultDeleteWatched"
        static let defaultMaxStorageGB = "downloads.defaultMaxStorageGB"
        static let sortOption = "downloads.sortOption"
        static let keepWatchedDownloads = "downloads.keepWatchedDownloads"
        static let simultaneousDownloads = "downloads.simultaneousDownloads"
    }
}
