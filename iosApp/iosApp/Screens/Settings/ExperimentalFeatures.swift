#if os(iOS) || os(tvOS)
import Foundation
import Observation

/// A feature that ships dark and is opted into per device from Settings.
enum ExperimentalFeature: String, CaseIterable, Identifiable {
    case watchParty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .watchParty: return "Watch Party"
        }
    }

    var subtitle: String {
        switch self {
        case .watchParty: return "Watch together with synchronized playback"
        }
    }

    var systemImage: String {
        switch self {
        case .watchParty: return "person.3"
        }
    }

    /// The Settings toggle's action: stores the choice and updates any live
    /// state the feature owns.
    @MainActor func setEnabled(_ enabled: Bool) {
        switch self {
        case .watchParty: WatchPartyEntry.setEnabled(enabled)
        }
    }
}

/// Device-local switches for features still in testing. Release builds keep
/// every feature off and the Settings section hidden until someone taps the
/// version row `unlockTapCount` times; Debug builds start with both on.
@MainActor @Observable
final class ExperimentalFeatures {
    static let shared = ExperimentalFeatures()
    static let unlockTapCount = 7

    private(set) var isUnlocked: Bool
    private var enabled: Set<ExperimentalFeature>

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let defaultOn: Bool
    @ObservationIgnored private var versionTaps = 0

    init(defaults: UserDefaults = .standard, defaultOn: Bool = ExperimentalFeatures.isDebugBuild) {
        self.defaults = defaults
        self.defaultOn = defaultOn
        isUnlocked = defaultOn || defaults.bool(forKey: Self.unlockedKey)
        enabled = Set(ExperimentalFeature.allCases.filter { feature in
            let key = Self.key(for: feature)
            return defaults.object(forKey: key) == nil ? defaultOn : defaults.bool(forKey: key)
        })
    }

    func isEnabled(_ feature: ExperimentalFeature) -> Bool {
        enabled.contains(feature)
    }

    func setEnabled(_ feature: ExperimentalFeature, _ value: Bool) {
        if value { enabled.insert(feature) } else { enabled.remove(feature) }
        defaults.set(value, forKey: Self.key(for: feature))
    }

    /// Counts taps on the version row. Returns true on the tap that reveals
    /// the section, so the caller can acknowledge it.
    @discardableResult
    func registerVersionTap() -> Bool {
        guard !isUnlocked else { return false }
        versionTaps += 1
        guard versionTaps >= Self.unlockTapCount else { return false }
        isUnlocked = true
        defaults.set(true, forKey: Self.unlockedKey)
        return true
    }

    private static let unlockedKey = "experimental.unlocked"

    private static func key(for feature: ExperimentalFeature) -> String {
        "experimental.\(feature.rawValue)"
    }

    nonisolated static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
#endif
