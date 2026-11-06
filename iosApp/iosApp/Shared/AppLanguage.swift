import Foundation

/// The interface language the app shows, and the helpers that resolve text
/// and formatting in it (`ui.app_language`; see `AppLanguagePreferences`).
///
/// Compiled into the apps and the Top Shelf extension. The extension runs in
/// its own process with its own defaults, so the app keeps the language it
/// shows in the App Group and the extension reads it from there.
enum AppLanguage {
    /// The languages this build ships: the bundle's localizations, which the
    /// generated string catalog decides. Never a hand-kept list. The
    /// development language comes first: the system falls back to the first
    /// entry, as the process does to the development language.
    static let shipped: [String] = {
        let development = Bundle.main.developmentLocalization ?? "en"
        let others = Bundle.main.localizations.filter { $0 != "Base" && $0 != development }
        return [development] + others.sorted()
    }()

    /// The shipped language a tag selects, matched the way the system matches
    /// the device language list (`es-MX` → `es`, `zh-CN` → `zh-Hans`), or nil
    /// when nothing matches (`it`, `zh-TW` with only `zh-Hans`).
    static func match(_ tag: String, shipped: [String] = shipped) -> String? {
        guard let best = Bundle.preferredLocalizations(from: shipped, forPreferences: [tag]).first else {
            return nil
        }
        // With no match the system falls back to the first shipped language.
        let wanted = Locale.Language(identifier: tag).languageCode
        return wanted != nil && Locale.Language(identifier: best).languageCode == wanted ? best : nil
    }

    /// The shipped language a preference list selects, the first one as a
    /// fallback (the system's own rule for the process language).
    static func match(preferences: [String], shipped: [String] = shipped) -> String {
        Bundle.preferredLocalizations(from: shipped, forPreferences: preferences).first
            ?? shipped.first ?? "en"
    }

    /// The device's locale with its language replaced, so region, calendar
    /// and hour cycle stay the user's.
    static func locale(for tag: String, base: Locale = .autoupdatingCurrent) -> Locale {
        var components = Locale.Components(locale: base)
        // `en_GB` keeps its region inside the language components, so read it
        // before replacing them.
        let region = base.region
        components.languageComponents = Locale.Language.Components(identifier: tag)
        components.region = region
        return Locale(components: components)
    }

    static func isRightToLeft(_ tag: String) -> Bool {
        Locale.Language(identifier: tag).characterDirection == .rightToLeft
    }

    /// A language's own name, capitalized for a list ("Español", "العربية").
    static func endonym(_ tag: String) -> String {
        let locale = Locale(identifier: tag)
        let name = locale.localizedString(forIdentifier: tag) ?? tag
        return name.prefix(1).capitalized(with: locale) + name.dropFirst()
    }

    // MARK: The language on screen

    static let displayedTagKey = "appLanguage.displayed.v1"

    /// The language the app shows now, as the app last stored it. Nil before
    /// the app has run with this build.
    static var displayedTag: String? {
        sharedDefaults.string(forKey: displayedTagKey)
    }

    static func storeDisplayedTag(_ tag: String) {
        sharedDefaults.set(tag, forKey: displayedTagKey)
    }

    /// Read on every request, so made once.
    private static let sharedDefaults = SharedStorage.suite

    static var displayedLocale: Locale {
        displayedTag.map { locale(for: $0) } ?? .autoupdatingCurrent
    }

    /// Every Silo request names the language the app shows.
    static func applyHeader(to request: inout URLRequest) {
        if let tag = displayedTag {
            request.setValue(tag, forHTTPHeaderField: "Accept-Language")
        }
    }

    // MARK: Text outside views

    /// Resolves a catalog string in the app's language. SwiftUI views take
    /// the root's `\.locale`; a `String` built anywhere else must come through
    /// here, because `String(localized:)` alone uses the process language.
    static func string(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = displayedLocale
        return String(localized: resource)
    }

    /// Wraps a title or name in first-strong isolates (FSI…PDI) when the
    /// interface reads right to left, so text of the other direction keeps
    /// its neighbours' punctuation in place. Left-to-right output keeps its
    /// bytes (D28). For text joined outside the catalog; catalog placeholders
    /// formatted by SwiftUI are isolated by the system.
    static func isolated(_ value: String, language: String = displayedLanguage) -> String {
        isRightToLeft(language) ? "\u{2068}\(value)\u{2069}" : value
    }

    // MARK: Server text

    /// The shipped language on screen; the development language before the
    /// app has stored one.
    static var displayedLanguage: String {
        displayedTag ?? development
    }

    /// The shipped language a view's `\.locale` shows. The root sets it to
    /// the app language, so a view that reads it re-renders on a switch.
    static func language(of locale: Locale) -> String {
        // Most views ask in the development language; skip the matching.
        if locale.language.languageCode == Locale.Language(identifier: development).languageCode { return development }
        return match(locale.identifier(.bcp47)) ?? development
    }

    private static var development: String { shipped.first ?? "en" }

    /// Text the server wrote that may carry a catalog key: a section's
    /// `title_key`, a problem's `type`, a settings-manifest label. Shows the
    /// translation when `language`'s own table has the key, otherwise the
    /// server's `text`. English shows exactly what the server sent, never the
    /// catalog's English.
    ///
    /// A key that takes an argument gets the one value in `args`. Apple
    /// arguments are positional and the catalog doesn't name them, so any
    /// other shape shows the server's text.
    static func serverText(
        _ text: String,
        key: String?,
        args: [String: String]? = nil,
        language: String = displayedLanguage
    ) -> String {
        guard let key, !key.isEmpty, language != development,
              let template = catalogLookup(key, language) else { return text }
        let specifiers = template.replacingOccurrences(of: "%%", with: "").filter { $0 == "%" }.count
        let values = args.map { Array($0.values) } ?? []
        switch (specifiers, values.count) {
        case (0, _):
            return template
        case (1, 1) where template.contains("%1$@") || template.contains("%@"):
            return String(format: template, locale: locale(for: language), isolated(values[0], language: language))
        default:
            return text
        }
    }

    /// Looks a key up in one shipped language's own table, with no fallback
    /// to English: nil when that language doesn't translate it. Tests swap it.
    nonisolated(unsafe) static var catalogLookup: (_ key: String, _ language: String) -> String? = { key, language in
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        let missing = "\u{0}"
        let value = bundle.localizedString(forKey: key, value: missing, table: nil)
        return value == missing ? nil : value
    }
}
