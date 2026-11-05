import Foundation

#if os(tvOS)
import SwiftUI
#endif

/// Sub-destinations of a Skyline library-type tab (§3). The on-page pill
/// row was removed, so these are now reached only through the top-bar
/// cascade dropdown (§5.3); `TVLibraryTypeTabView` renders the selected
/// one, with `.recommended` as the landing default.
enum TVLibraryPill: String, Hashable, CaseIterable {
    /// The server-driven landing feed (recommendations + sections).
    case recommended
    case collections
    /// The full library, browsable as an A–Z grid.
    case browse

    var title: String {
        switch self {
        case .recommended: return "Recommended"
        case .collections: return "Collections"
        case .browse: return "Browse"
        }
    }

    /// SF Symbol shown beside the section name in the cascade flyout (§5.3).
    var systemImage: String {
        switch self {
        case .recommended: return "sparkles"
        case .collections: return "square.stack.3d.up"
        case .browse: return "square.grid.2x2"
        }
    }

}

