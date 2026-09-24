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

/// Device-local switches for features still in testing. Release builds start
/// with every feature off; Debug builds start with them on.
@MainActor @Observable
final class ExperimentalFeatures {
    static let shared = ExperimentalFeatures()

    private var enabled: Set<ExperimentalFeature>

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, defaultOn: Bool = ExperimentalFeatures.isDebugBuild) {
        self.defaults = defaults
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
