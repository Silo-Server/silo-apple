import Foundation

/// The outside services whose data or artwork Silo shows, for Settings >
/// About > Acknowledgements. List only services the app itself names or
/// loads from; providers the server uses without the app showing them are out
/// of scope here.
enum ThirdPartyCredits {
    struct Credit: Identifiable, Sendable {
        let name: String
        /// What Silo shows or loads from the service.
        let use: LocalizedStringResource
        /// Wording the service's terms require, shown verbatim in English.
        var notice: String? = nil
        var logoAsset: String? = nil

        var id: String { name }
    }

    @MainActor static let credits: [Credit] = [
        // TMDB's API terms require this notice and TMDB's logo in an About or
        // Credits section of any app that shows TMDB data.
        Credit(
            name: "TMDB",
            use: .settingsAboutCreditTmdb,
            notice: "This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB.",
            logoAsset: RatingEntryView.tmdbLogoAsset
        ),
        Credit(name: "IMDb", use: .settingsAboutCreditImdb),
        Credit(name: "Rotten Tomatoes", use: .settingsAboutCreditRottenTomatoes),
        Credit(
            name: "Common Sense Media and MDBList",
            use: .settingsAboutCreditAdvisoryAges
        ),
        Credit(
            name: "OpenSubtitles, SubDL, and Subsource",
            use: .settingsAboutCreditSubtitleSearch
        ),
        Credit(
            name: "DiceBear",
            use: .settingsAboutCreditDiceBear,
            notice: """
            Fun Emoji is a remix of "Fun Emoji Set" by Davis Uche, licensed under \
            CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Bottts is a \
            remix of "Bottts" by Pablo Stanley. Pixel Art, Identicon, and \
            Initials are by DiceBear, licensed under CC0 1.0.
            """
        ),
        Credit(name: "YouTube", use: .settingsAboutCreditYouTube),
    ]

    static let trademarkNotice: LocalizedStringResource = .settingsAboutTrademarkNotice
}
