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

    /// The locale the app shows `tag` in, which text and formatting share
    /// (D26): the device's locale with its language replaced, so region,
    /// calendar and hour cycle stay the user's. This is what the system
    /// itself shows once the app's own `AppleLanguages` holds `tag` (from
    /// the next launch), so a switch formats the same before and after a
    /// relaunch. Arabic writes Arabic-Indic digits (D55) unless the user
    /// chose other digits; Apple's plain `ar` would write Latin ones.
    static func locale(for tag: String, base: Locale = .autoupdatingCurrent) -> Locale {
        var components = Locale.Components(locale: base)
        // `en_GB` keeps its region inside the language components, so read it
        // before replacing them.
        let region = base.region
        components.languageComponents = Locale.Language.Components(identifier: tag)
        components.region = region
        if components.languageComponents.languageCode == .arabic, components.numberingSystem == nil {
            components.numberingSystem = Locale.NumberingSystem("arab")
        }
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

    /// Read by every string and number built outside a view, so the
    /// resolved locale is kept until the tag or the device locale changes.
    static var displayedLocale: Locale {
        guard let tag = displayedTag else { return .autoupdatingCurrent }
        let device = Locale.autoupdatingCurrent
        let key = "\(tag)|\(device.identifier)|\(device.hourCycle)"
        displayedLocaleLock.lock()
        defer { displayedLocaleLock.unlock() }
        if let cached = displayedLocaleCache, cached.key == key { return cached.locale }
        let resolved = locale(for: tag, base: device)
        displayedLocaleCache = (key, resolved)
        return resolved
    }

    private static let displayedLocaleLock = NSLock()
    nonisolated(unsafe) private static var displayedLocaleCache: (key: String, locale: Locale)?

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
        string(resource, locale: formattingLocale)
    }

    /// The locale text and numbers built outside a view use: the app's, or
    /// English while ``inEnglish(_:)`` runs. A view passes its `\.locale`
    /// instead, so it re-renders on a language switch.
    static var formattingLocale: Locale {
        dataLocale ?? displayedLocale
    }

    /// Set while ``inEnglish(_:)`` runs.
    @TaskLocal private static var dataLocale: Locale?

    /// Runs `body` with ``string(_:)`` resolving in English. Text that is
    /// sent to another device, stored or matched stays English in every
    /// language; wrap code that builds it from shared label helpers.
    static func inEnglish<T>(_ body: () throws -> T) rethrows -> T {
        try $dataLocale.withValue(Locale(identifier: "en")) { try body() }
    }

    /// Resolves a catalog string in the language a view shows, for a view
    /// that needs a `String` (a component's `String` parameter, an
    /// accessibility label built from parts). Pass the view's `\.locale`, so
    /// the view re-renders when the language changes.
    static func string(_ resource: LocalizedStringResource, locale: Locale) -> String {
        var resource = resource
        resource.locale = locale
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
        // The argument slots the template uses, by position (`%@` is `%1$@`).
        // A template without any keeps a literal `%` unescaped.
        let slots = Set(template.replacingOccurrences(of: "%%", with: "")
            .matches(of: #/%(\d+\$)?(@|l{0,2}[df])/#)
            .map { "\($0.output.1 ?? "1$")\($0.output.2)" })
        let values = args.map { Array($0.values) } ?? []
        if slots.isEmpty { return template }
        guard slots == ["1$@"], values.count == 1 else { return text }
        return String(format: template, locale: locale(for: language), isolated(values[0], language: language))
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

extension LocalizedStringResource {
    /// Text shown as is where an API takes catalog text: a name, a number, a
    /// server value, or text a model outside the catalog still writes in
    /// English. It resolves through the `%@` format, which the catalog never
    /// defines, so every language shows `text` unchanged.
    static func verbatim(_ text: String) -> LocalizedStringResource {
        "\(text)"
    }
}
