import SwiftUI

/// The notice TMDB's API terms require in any app that shows TMDB data, with
/// TMDB's logo identifying the source. Silo shows TMDB scores and Requests
/// artwork. The logo stays smaller than Silo's own branding, as the terms ask.
struct TMDBAttributionNotice: View {
    nonisolated static let text = "This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB."

    var logoHeight: CGFloat = 11

    var body: some View {
        VStack(alignment: .leading, spacing: logoHeight * 0.6) {
            Image(RatingEntryView.tmdbLogoAsset)
                .resizable()
                .scaledToFit()
                .frame(height: logoHeight)
                .accessibilityHidden(true)
            Text(Self.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
