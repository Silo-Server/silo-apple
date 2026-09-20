import SwiftUI

extension Font {
    #if os(tvOS)

    // Semantic styles use the platform's viewing-distance metrics and follow
    // the user's text-size preference, rather than scaling fixed point sizes.

    /// Hero title overlaid on backdrop — massive on TV
    static let siloHeroTitle = Font.largeTitle.weight(.heavy).leading(.tight)

    /// Large screen titles — "Discover", "TV Shows"
    static let siloTitle = Font.title.weight(.bold)

    /// Section headlines — "Continue Watching"
    static let siloHeadline = Font.title2.weight(.semibold)

    /// Card titles and subheadlines
    static let siloSubheadline = Font.headline

    /// Movie/series names directly beneath artwork. Kept quieter than general
    /// subheadlines so dense eight-across rows remain readable rather than
    /// visually shouting over the posters.
    static let siloPosterTitle = Font.subheadline.weight(.medium)

    /// Year, episode title, and other secondary poster-card metadata.
    static let siloPosterMetadata = Font.caption

    /// Body text — descriptions, synopses
    static let siloBody = Font.body

    /// Captions and metadata
    static let siloCaption = Font.caption

    /// Smallest text — badges, episode numbers, tab labels
    static let siloSmall = Font.caption2

    /// Numeric displays like PINs
    static let siloPIN = Font.largeTitle.monospaced().bold()

    #else

    /// Hero title overlaid on backdrop
    static let siloHeroTitle = Font.largeTitle.bold().leading(.tight)

    /// Large screen titles — "Discover", "TV Shows"
    static let siloTitle = Font.title3.bold()

    /// Section headlines — "Continue Watching"
    static let siloHeadline = Font.headline

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
