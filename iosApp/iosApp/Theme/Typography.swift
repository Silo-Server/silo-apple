import SwiftUI

extension Font {
    #if os(tvOS)

    // tvOS is viewed from ~10 feet away, so all typography is scaled up
    // roughly 2.3x from iOS. tvOS has no user text-size preference, so fixed
    // point sizes are used to keep proportions stable across screens.

    /// Large screen titles — "Discover", "TV Shows" (48pt bold)
    static let siloTitle = Font.system(size: 48, weight: .bold)

    /// Section headlines — "Continue Watching" (36pt semibold)
    static let siloHeadline = Font.system(size: 36, weight: .semibold)

    /// Card titles and subheadlines (28pt semibold)
    static let siloSubheadline = Font.system(size: 28, weight: .semibold)

    /// Movie/series names directly beneath artwork. Kept quieter than general
    /// subheadlines so dense eight-across rows remain readable rather than
    /// visually shouting over the posters.
    static let siloPosterTitle = Font.system(size: 24, weight: .medium)

    /// Year, episode title, and other secondary poster-card metadata.
    static let siloPosterMetadata = Font.system(size: 20, weight: .regular)

    /// Body text — descriptions, synopses (26pt regular)
    static let siloBody = Font.system(size: 26)

    /// Captions and metadata (22pt regular)
    static let siloCaption = Font.system(size: 22, weight: .regular)

    /// Smallest text — badges, episode numbers, tab labels (20pt regular)
    static let siloSmall = Font.system(size: 20, weight: .regular)

    /// Numeric displays like PINs (64pt monospaced bold)
    static let siloPIN = Font.system(size: 64, weight: .bold, design: .monospaced)

    #else

    #if os(macOS)
    // macOS text styles run about two points smaller than iOS, which left
    // page and row headings undersized in a desktop window. The Mac steps
    // both up one style.

    /// Large screen titles — "Discover", "TV Shows"
    static let siloTitle = Font.title2.bold()

    /// Section headlines — "Continue Watching"
    static let siloHeadline = Font.title3.weight(.semibold)
    #else
    /// Large screen titles — "Discover", "TV Shows"
    static let siloTitle = Font.title3.bold()

    /// Section headlines — "Continue Watching"
    static let siloHeadline = Font.headline
    #endif

    /// Card titles and subheadlines
    static let siloSubheadline = Font.subheadline.bold()

    /// Body text — descriptions, synopses
    static let siloBody = Font.body

    /// Captions and metadata
    static let siloCaption = Font.caption

    /// Smallest text — badges, episode numbers, tab labels
    static let siloSmall = Font.caption2

    /// Numeric displays like PINs
    static let siloPIN = Font.largeTitle.monospaced().bold()

    #endif
}
