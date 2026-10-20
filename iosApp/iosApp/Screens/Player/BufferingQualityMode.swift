import Foundation

/// What Silo does when playback keeps buffering —
/// `playback.buffering_quality_mode`, settings contract revision 23.
///
/// The spec is the server repo's `docs/design/2026-10-17-buffering-quality.md`.
/// Web and Android implement the same modes.
enum BufferingQualityMode: String, CaseIterable, Identifiable, Sendable {
    /// Detect and report stalls only: no replan, no pill.
    case never
    /// Ask before lowering, on Auto and on a quality the viewer picked.
    case ask
    /// Lower Auto at once and offer an undo. A quality the viewer picked is
    /// still asked about first.
    case always

    /// The contract default.
    static let `default`: BufferingQualityMode = .always

    var id: String { rawValue }

    /// The contract's enum member spelling.
    var wireValue: String { rawValue }

    /// The contract's option labels, shared with web and Android.
    var label: String {
        switch self {
        case .never: return "Never"
        case .ask: return "Ask first"
        case .always: return "Automatically"
        }
    }

    /// Parses a stored or wire value; nil for absent or unrecognized input.
    init?(wireValue: String?) {
        guard let wireValue, let mode = BufferingQualityMode(rawValue: wireValue) else { return nil }
        self = mode
    }
}
