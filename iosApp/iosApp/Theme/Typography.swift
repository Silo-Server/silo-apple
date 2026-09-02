import SwiftUI

extension Font {
    #if os(tvOS)

    // tvOS is viewed from ~10 feet away, so all typography is scaled up
    // roughly 2.3x from iOS and uses Apple TV's system text design.

    /// Hero title overlaid on backdrop — massive on TV (76pt bold)
    static let continuumHeroTitle = Font.system(size: 76, weight: .heavy).leading(.tight)

    /// Large screen titles — "Discover", "TV Shows" (48pt bold)
    static let continuumTitle = Font.system(size: 48, weight: .bold)

    /// Section headlines — "Continue Watching" (36pt semibold)
    static let continuumHeadline = Font.system(size: 36, weight: .semibold)

    /// Card titles and subheadlines (28pt semibold)
    static let continuumSubheadline = Font.system(size: 28, weight: .semibold)

    /// Movie/series names directly beneath artwork. Kept quieter than general
    /// subheadlines so dense eight-across rows remain readable rather than
    /// visually shouting over the posters.
    static let continuumPosterTitle = Font.system(size: 20, weight: .medium)

    /// Year, episode title, and other secondary poster-card metadata.
    static let continuumPosterMetadata = Font.system(size: 17, weight: .regular)

    /// Body text — descriptions, synopses (26pt regular)
    static let continuumBody = Font.system(size: 26)

    /// Captions and metadata (22pt regular)
    static let continuumCaption = Font.system(size: 22, weight: .regular)

    /// Smallest text — badges, episode numbers, tab labels (20pt regular)
    static let continuumSmall = Font.system(size: 20, weight: .regular)

    /// Numeric displays like PINs (64pt monospaced bold)
    static let continuumPIN = Font.system(size: 64, weight: .bold, design: .monospaced)

    #else

    /// Hero title overlaid on backdrop (36pt bold, tight tracking)
    static let continuumHeroTitle = Font.system(size: 36, weight: .bold).leading(.tight)

    /// Large screen titles — "Discover", "TV Shows" (18pt bold)
    static let continuumTitle = Font.system(size: 18, weight: .bold)

    /// Section headlines — "Continue Watching" (16pt semibold)
    static let continuumHeadline = Font.system(size: 16, weight: .semibold)

    /// Card titles and subheadlines (14pt bold)
    static let continuumSubheadline = Font.system(size: 14, weight: .bold)

    /// Body text — descriptions, synopses (14pt regular)
    static let continuumBody = Font.system(size: 14)

    /// Captions and metadata (12pt regular)
    static let continuumCaption = Font.system(size: 12, weight: .regular)

    /// Smallest text — badges, episode numbers, tab labels (11pt regular)
    static let continuumSmall = Font.system(size: 11, weight: .regular)

    /// Numeric displays like PINs (32pt monospaced bold)
    static let continuumPIN = Font.system(size: 32, weight: .bold, design: .monospaced)

    #endif
}
