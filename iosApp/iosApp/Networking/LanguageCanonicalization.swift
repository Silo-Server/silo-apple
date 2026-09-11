import Foundation

enum LanguageCanonicalization {
    static func wireTag(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliases = [
            "arabic": "ar", "english": "en", "spanish": "es", "french": "fr", "german": "de",
            "ara": "ar", "eng": "en", "spa": "es", "fre": "fr", "fra": "fr", "deu": "de", "ger": "de",
            "ita": "it", "por": "pt", "jpn": "ja", "kor": "ko", "zho": "zh", "chi": "zh",
        ]
        let mapped = aliases[raw.lowercased()] ?? raw
        let locale = Locale(identifier: mapped.replacingOccurrences(of: "_", with: "-"))
        guard let language = locale.languageCode, language != "und", Locale.isoLanguageCodes.contains(language.lowercased()) else { return nil }
        var tag = language.lowercased()
        if let script = locale.scriptCode { tag += "-" + script.capitalized }
        if let region = locale.regionCode { tag += "-" + region.uppercased() }
        return tag
    }

    static func primary(_ value: String?) -> String? {
        guard let tag = wireTag(value) else { return nil }
        return tag.split(separator: "-").first.map(String.init)
    }
}
