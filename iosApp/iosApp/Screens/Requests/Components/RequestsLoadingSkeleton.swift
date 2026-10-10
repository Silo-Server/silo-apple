import SwiftUI

/// First-load placeholders for the requests screens. Each one draws the
/// real layout's geometry — rails, grouped rows, the detail hero — with
/// quiet static fills, the same treatment as `PhoneEpisodeRailSkeleton` and
/// `TVLibraryBrowseLoadingView`: no shimmer, blur, or timer. Content replaces
/// the placeholders in place, so opening Requests reads like opening any
/// other page instead of a relaunch.
enum RequestsSkeleton {
    static func bar(width: CGFloat, height: CGFloat, opacity: Double = 0.12) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.white.opacity(opacity))
            .frame(width: width, height: height)
    }

    static func block(width: CGFloat?, height: CGFloat, cornerRadius: CGFloat, opacity: Double = 0.09) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(opacity))
            .frame(width: width, height: height)
    }
}

/// A section header plus a rail of poster placeholders at request-card size.
struct RequestRailSkeleton: View {
    /// Draw the section title as text when it's already known.
    var title: String? = nil
    var cardCount = 6
    /// Matches a caller's `RequestMediaCard.cardWidth(_:)` override.
    var cardWidth: CGFloat? = nil
    @State private var uiCustomization = UICustomizationPreferences.shared

    private var width: CGFloat {
        cardWidth ?? RequestsUI.cardWidth * uiCustomization.cardPresentation.posterSize.scale
    }

    private var height: CGFloat {
        width * (SiloTheme.posterCardHeight / SiloTheme.posterCardWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RequestsUI.headerSpacing) {
            if let title {
                RequestsSectionHeader(title: title)
            } else {
                RequestsSkeleton.bar(width: titleWidth, height: titleHeight, opacity: 0.14)
            }

            HStack(alignment: .top, spacing: RequestsUI.railSpacing) {
                ForEach(0..<cardCount, id: \.self) { index in
                    VStack(alignment: .leading, spacing: captionSpacing) {
                        RequestsSkeleton.block(
                            width: width,
                            height: height,
                            cornerRadius: SiloTheme.cornerRadius,
                            opacity: 0.09 + Double(index % 3) * 0.01
                        )
                        RequestsSkeleton.bar(width: width * 0.76, height: captionHeight, opacity: 0.14)
                        RequestsSkeleton.bar(width: width * 0.38, height: captionHeight * 0.8, opacity: 0.09)
                    }
                }
            }
            // `minWidth: 0` lets the frame shrink below the cards' total
            // width; without it an overflowing rail widens the whole page
            // column and the scroll view centers it off the leading edge.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var titleWidth: CGFloat {
        #if os(tvOS)
        300
        #else
        160
        #endif
    }

    private var titleHeight: CGFloat {
        #if os(tvOS)
        28
        #else
        18
        #endif
    }

    private var captionHeight: CGFloat {
        #if os(tvOS)
        18
        #else
        10
        #endif
    }

    private var captionSpacing: CGFloat {
        #if os(tvOS)
        14
        #else
        7
        #endif
    }
}

#if !os(tvOS)
/// Grouped-row placeholders for My Requests, in the Downloads manager's
/// inset-grouped shape.
struct MyRequestsSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach([44, 104, 92, 84], id: \.self) { width in
                    RequestsSkeleton.block(width: CGFloat(width), height: 34, cornerRadius: 17, opacity: 0.08)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            RequestsSkeleton.bar(width: 90, height: 11, opacity: 0.12)
                .padding(.horizontal, 32)
                .padding(.top, 22)
                .padding(.bottom, 10)

            ForEach(0..<4, id: \.self) { index in
                row
                    .downloadGroupedRow(DownloadGroupPosition(index: index, count: 4), separatorInset: 74)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var row: some View {
        HStack(spacing: 12) {
            RequestsSkeleton.block(width: 46, height: 69, cornerRadius: SiloTheme.smallCornerRadius)
            VStack(alignment: .leading, spacing: 8) {
                RequestsSkeleton.bar(width: 150, height: 13, opacity: 0.15)
                RequestsSkeleton.bar(width: 110, height: 10, opacity: 0.09)
                RequestsSkeleton.block(width: nil, height: 4, cornerRadius: 2, opacity: 0.08)
                    .frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// Detail placeholder: the hero, the primary action, and the synopsis.
struct RequestDetailSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.05))
                .frame(height: RequestDetailLayout.heroHeight)
                .overlay(alignment: .bottom) {
                    VStack(spacing: 10) {
                        RequestsSkeleton.bar(width: 220, height: 30, opacity: 0.14)
                        RequestsSkeleton.bar(width: 180, height: 11, opacity: 0.1)
                    }
                    .padding(.bottom, 20)
                }

            VStack(alignment: .leading, spacing: 12) {
                RequestsSkeleton.block(width: nil, height: 52, cornerRadius: 26, opacity: 0.1)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
                RequestsSkeleton.bar(width: 330, height: 11, opacity: 0.09)
                RequestsSkeleton.bar(width: 300, height: 11, opacity: 0.09)
                RequestsSkeleton.bar(width: 220, height: 11, opacity: 0.09)
            }
            .padding(SiloTheme.padding)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}
#endif
