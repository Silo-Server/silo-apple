import Foundation

/// The one minutes-to-runtime label. Surfaces differ only in how they spell a
/// sub-hour length, so that is the single knob; an exact hour always elides
/// the zero remainder ("2h", never "2h 0m").
enum RuntimeLabel {
    enum Style {
        /// "1h 4m" / "2h" / "42m" — cards, rails, badges.
        case compact
        /// "1h 4m" / "2h" / "42 min" — the hero facts line and the tvOS
        /// focus marquee, which have room to spell it out.
        case spelled
    }

    /// nil for a missing or non-positive runtime, so callers can drop the
    /// token entirely.
    static func minutes(_ minutes: Int?, style: Style) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0 {
            return remainder > 0 ? "\(hours)h \(remainder)m" : "\(hours)h"
        }
        return style == .spelled ? "\(remainder) min" : "\(remainder)m"
    }
}
