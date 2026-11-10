@testable import Silo
import XCTest

/// Numbers, durations, sizes and names follow the app's language (D26, D55),
/// and US English keeps the exact bytes the app printed before.
final class LocaleFormatTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let german = Locale(identifier: "de")
    /// Apple's plain `ar` writes Latin digits; Egypt uses Arabic-Indic ones.
    private let arabic = Locale(identifier: "ar_EG")
    private let japanese = Locale(identifier: "ja")

    // MARK: US English, byte for byte

    func testEnglishClocksMatchPrintf() {
        for seconds in stride(from: 0, through: 200_000, by: 37) {
            let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
            let old = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
            XCTAssertEqual(LocaleFormat.clock(seconds: seconds, locale: english), old)
        }
    }

    func testEnglishDurationsMatchTheOldHandBuiltText() {
        for minutes in Array(0..<6_000) + [59_999, 60_000, 61_234, 600_042] {
            let h = minutes / 60, rest = minutes % 60
            let withZero = h > 0 ? "\(h)h \(rest)m" : "\(rest)m"
            let withoutZero = h > 0 ? (rest > 0 ? "\(h)h \(rest)m" : "\(h)h") : "\(rest)m"
            XCTAssertEqual(LocaleFormat.duration(minutes: minutes, showZeroMinutes: true, locale: english), withZero)
            XCTAssertEqual(LocaleFormat.duration(minutes: minutes, showZeroMinutes: false, locale: english), withoutZero)
        }
    }

    func testEnglishDecimalsRoundAsPrintfDoes() {
        for step in 0..<2_000 {
            let value = Double(step) / 997
            XCTAssertEqual(LocaleFormat.decimal(value, fractionDigits: 2, locale: english), String(format: "%.2f", value))
        }
        // The format style would round this half-even to "1.02".
        XCTAssertEqual(LocaleFormat.decimal(1.015, fractionDigits: 2, locale: english), "1.01")
    }

    func testEnglishKeepsItsNumbersSizesAndNames() {
        XCTAssertEqual(LocaleFormat.integer(1234, locale: english), "1234")
        XCTAssertEqual(LocaleFormat.integer(-5, locale: english), "-5")
        XCTAssertEqual(LocaleFormat.rate(1, locale: english), "1×")
        XCTAssertEqual(LocaleFormat.rate(1.25, locale: english), "1.25×")
        XCTAssertEqual(LocaleFormat.rate(0.5, locale: english), "0.5×")
        XCTAssertEqual(LocaleFormat.percent(42, locale: english), "42%")
        for bytes: Int64 in [0, 999, 1_536, 1_500_000, 54_800_000_000] {
            XCTAssertEqual(LocaleFormat.bytes(bytes, locale: english), ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        XCTAssertEqual(LocaleFormat.languageName("de", locale: english), "German")
        XCTAssertEqual(LocaleFormat.languageName("pt-BR", locale: english), "Portuguese (Brazil)")
    }

    /// After a live switch from Arabic, the process locale stays Arabic until
    /// relaunch; English sizes still write Latin digits.
    func testEnglishSizesIgnoreAnotherProcessLocale() {
        let processArabic = Locale(identifier: "ar_EG")
        XCTAssertEqual(LocaleFormat.bytes(1_500_000, locale: english, processLocale: processArabic), "1.5 MB")
        XCTAssertEqual(LocaleFormat.bytes(2_048, locale: english, processLocale: processArabic), "2 KB")
        XCTAssertEqual(
            LocaleFormat.bytes(54_800_000_000, megabytesAndUp: true, locale: english, processLocale: processArabic),
            "54.8 GB"
        )
    }

    // MARK: Other languages

    func testGerman() {
        XCTAssertEqual(LocaleFormat.decimal(1.25, fractionDigits: 2, locale: german), "1,25")
        XCTAssertEqual(LocaleFormat.rate(1.25, locale: german), "1,25×")
        XCTAssertEqual(LocaleFormat.duration(minutes: 102, showZeroMinutes: false, locale: german), "1h 42min")
        XCTAssertEqual(LocaleFormat.bytes(1_500_000, locale: german), "1,5 MB")
        XCTAssertEqual(LocaleFormat.percent(42, locale: german), "42\u{A0}%")
        XCTAssertEqual(LocaleFormat.languageName("en", locale: german), "Englisch")
        XCTAssertEqual(LocaleFormat.ordinal(3, locale: german), "3.")
    }

    func testArabicDigits() {
        XCTAssertEqual(LocaleFormat.integer(1234, locale: arabic), "١٢٣٤")
        XCTAssertEqual(LocaleFormat.clock(seconds: 3725, locale: arabic), "١:٠٢:٠٥")
        XCTAssertEqual(LocaleFormat.decimal(1.25, fractionDigits: 2, locale: arabic), "١٫٢٥")
        XCTAssertEqual(LocaleFormat.duration(minutes: 102, showZeroMinutes: false, locale: arabic), "١س ٤٢د")
        XCTAssertEqual(LocaleFormat.languageName("de", locale: arabic), "الألمانية")
        // Plain `ar` keeps Latin digits on Apple platforms.
        XCTAssertEqual(LocaleFormat.integer(1234, locale: Locale(identifier: "ar")), "1234")
    }

    func testJapanese() {
        XCTAssertEqual(LocaleFormat.duration(minutes: 102, showZeroMinutes: false, locale: japanese), "1時間42分")
        XCTAssertEqual(LocaleFormat.duration(minutes: 60, showZeroMinutes: true, locale: japanese), "1時間0分")
        XCTAssertEqual(LocaleFormat.languageName("de", locale: japanese), "ドイツ語")
        XCTAssertEqual(LocaleFormat.integer(1234, locale: japanese), "1234")
    }

    // MARK: Call sites follow the language on screen

    /// These read the app's language through the default argument, as the
    /// screens do; on the base they printed English or ASCII.
    func testCallSitesFollowTheDisplayedLanguage() {
        withDisplayedTag("de") {
            XCTAssertEqual(PlayerTimeFormatter.formatRuntime(6_120), "1h 42min")
            XCTAssertEqual(MediaTextFormatting.runtime(minutes: 60), "1h 0min")
            XCTAssertEqual(SubtitleDisplayOrder.languageDisplayName("de"), "Deutsch")
            XCTAssertEqual(DetailDateFormatting.longDate("2026-07-08"), "8. Juli 2026")
        }
        // Arabic writes Arabic-Indic digits on any device (D55). Separators
        // follow the device's region, as the system's own formatting does.
        withDisplayedTag("ar") {
            XCTAssertEqual(PlayerTimeFormatter.formatHMS(3_725), "١:٠٢:٠٥")
            XCTAssertEqual(AudioFullPlayerView.rateLabel(1.25), "١٫٢٥×")
        }
        withDisplayedTag("ja") {
            XCTAssertEqual(PlayerTimeFormatter.formatRuntime(6_120), "1時間42分")
        }
    }

    /// Data built in English stays English (D44): the phone's copy of a
    /// track label, for example.
    func testInEnglishFormatsInEnglish() {
        withDisplayedTag("ar") {
            XCTAssertEqual(AppLanguage.inEnglish { AudioFullPlayerView.rateLabel(1.25) }, "1.25×")
            XCTAssertEqual(AppLanguage.inEnglish { SubtitleDisplayOrder.languageDisplayName("de") }, "German")
        }
    }

    /// A release title names its language in English; it still counts as
    /// repeating the row's language in a translated interface.
    func testEnglishTrackTitlesStillDropUnderAnotherLanguage() {
        withDisplayedTag("de") {
            XCTAssertNil(TrackLabels.audioTitle("English 5.1", language: "eng"))
            XCTAssertNil(TrackLabels.subtitleTitle("English", language: "eng", codec: "subrip", showsHearingImpaired: false))
        }
    }

    private func withDisplayedTag(_ tag: String, _ body: () -> Void) {
        let defaults = SharedStorage.suite
        let previous = defaults.string(forKey: AppLanguage.displayedTagKey)
        AppLanguage.storeDisplayedTag(tag)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppLanguage.displayedTagKey)
            } else {
                defaults.removeObject(forKey: AppLanguage.displayedTagKey)
            }
        }
        body()
    }
}
