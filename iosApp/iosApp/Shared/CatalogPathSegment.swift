import Foundation

/// Catalog IDs are opaque values, including when they contain URL delimiters.
enum CatalogPathSegment {
    static func encode(_ value: String) -> String? {
        guard !value.isEmpty, value != ".", value != ".." else { return nil }
        return value.addingPercentEncoding(withAllowedCharacters:
            CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%")))
    }
}
