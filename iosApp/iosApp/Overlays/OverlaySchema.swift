import Foundation

/// Decodes `CardOverlayPrefs` from the JSON document the server
/// stores under the `ui.card_overlays` contract setting. The shape must
/// stay compatible with the web's `parseOverlayPrefs` in
/// `web/src/lib/overlays/schema.ts` and the contract schema
/// `contracts/settings/v1/schemas/card-overlays.json`, since clients
/// share the setting.
enum OverlaySchema {

    /// Registry defaults, used when the server has no value or parsing fails.
    static func buildDefaults() -> CardOverlayPrefs {
        var items: [OverlayId: OverlayItemConfig] = [:]
        for def in OverlayRegistry.all {
            items[def.id] = OverlayItemConfig(
                enabled: def.defaultEnabled,
                position: def.defaultPosition,
                accentColor: nil,
                showIcon: nil
            )
        }
        return CardOverlayPrefs(
            version: CardOverlayPrefs.currentVersion,
            preset: .classic,
            order: [],
            items: items
        )
    }

    /// Parse a JSON string into a fully populated `CardOverlayPrefs`.
    /// Unknown overlay IDs and malformed entries are dropped — the
    /// remaining fields fall back to registry defaults so the user's
    /// real overrides survive a schema upgrade. V1 docs (flat
    /// `Record<OverlayId, {enabled, position}>`) are migrated to V2.
    static func parse(_ raw: String?) -> CardOverlayPrefs {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else {
            return buildDefaults()
        }
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let dict = any as? [String: Any] else {
            return buildDefaults()
        }
        if isV2(dict) {
            return parseV2(dict)
        }
        return migrateFromV1(dict)
    }

    // MARK: - V2

    /// V2 documents carry `version: 2`, or at least a preset and an items
    /// object; anything else goes through `migrateFromV1`.
    private static func isV2(_ dict: [String: Any]) -> Bool {
        if (dict["version"] as? Int) == 2 { return true }
        return dict["preset"] is String && dict["items"] is [String: Any]
    }

    private static func parseV2(_ dict: [String: Any]) -> CardOverlayPrefs {
        var prefs = buildDefaults()

        if let presetRaw = dict["preset"] as? String,
           let preset = PresetId(rawValue: presetRaw) {
            prefs.preset = preset
        }
        prefs.style = parseStyle(dict["style"])

        if let orderRaw = dict["order"] as? [Any] {
            prefs.order = orderRaw.compactMap { entry in
                (entry as? String).flatMap(OverlayId.init(rawValue:))
            }
        }

        if let items = dict["items"] as? [String: Any] {
            for def in OverlayRegistry.all {
                if let patch = items[def.id.rawValue] as? [String: Any],
                   let base = prefs.items[def.id] {
                    prefs.items[def.id] = applyPatch(base: base, patch: patch)
                }
            }
        }

        return prefs
    }

    // MARK: - V1 migration

    private static func migrateFromV1(_ dict: [String: Any]) -> CardOverlayPrefs {
        var prefs = buildDefaults()
        for def in OverlayRegistry.all {
            if let patch = dict[def.id.rawValue] as? [String: Any],
               let base = prefs.items[def.id] {
                prefs.items[def.id] = applyPatch(base: base, patch: patch)
            }
        }
        return prefs
    }

    private static func applyPatch(base: OverlayItemConfig, patch: [String: Any]) -> OverlayItemConfig {
        var next = base
        if let enabled = patch["enabled"] as? Bool {
            next.enabled = enabled
        }
        if let positionRaw = patch["position"] as? String,
           let position = OverlayPosition(stored: positionRaw) {
            next.position = position
        }
        if let accent = patch["accentColor"] as? String, isHexColor(accent) {
            next.accentColor = accent
        } else {
            // Absent / invalid → drop the override.
            next.accentColor = nil
        }
        if let showIcon = patch["showIcon"] as? Bool {
            next.showIcon = showIcon
        } else {
            next.showIcon = nil
        }
        next.image = (patch["image"] as? String).flatMap { isImageRef($0) ? $0 : nil }
        next.valueImages = parseValueImages(patch["valueImages"])
        return next
    }

    // MARK: - Style and images

    private static let styleSizeRange = 0.75...2.0
    private static let maxValueImages = 32
    private static let maxValueKeyLength = 64

    /// Keeps the fields the contract accepts; an invalid field is dropped
    /// rather than failing the whole style, and an empty style is no style.
    static func parseStyle(_ value: Any?) -> OverlayStyle? {
        guard let raw = value as? [String: Any] else { return nil }
        var style = OverlayStyle()
        if let size = number(raw["size"]), styleSizeRange.contains(size) {
            style.size = size
        }
        style.shape = (raw["shape"] as? String).flatMap(OverlayShape.init(rawValue:))
        if let background = raw["background"] as? String, isHexColorWithAlpha(background) {
            style.background = background
        }
        if let textColor = raw["textColor"] as? String, isHexColor(textColor) {
            style.textColor = textColor
        }
        if let borderColor = raw["borderColor"] as? String, isHexColorWithAlpha(borderColor) {
            style.borderColor = borderColor
        }
        if let width = number(raw["borderWidth"]), width == width.rounded(), (0...3).contains(width) {
            style.borderWidth = Int(width)
        }
        style.fontWeight = (raw["fontWeight"] as? String).flatMap(OverlayFontWeight.init(rawValue:))
        style.uppercase = bool(raw["uppercase"])
        style.shadow = bool(raw["shadow"])
        return style.isEmpty ? nil : style
    }

    private static func parseValueImages(_ value: Any?) -> [String: String] {
        guard let raw = value as? [String: Any] else { return [:] }
        // Sorted so a document over the cap keeps the same entries every parse.
        let valid = raw.keys.sorted().compactMap { key -> (String, String)? in
            // The contract's maxLength counts code points.
            guard !key.isEmpty, key.unicodeScalars.count <= maxValueKeyLength,
                  let ref = raw[key] as? String, isImageRef(ref) else { return nil }
            return (key, ref)
        }
        return Dictionary(uniqueKeysWithValues: valid.prefix(maxValueImages))
    }

    /// A JSON number, but not a boolean: `JSONSerialization` bridges both to
    /// `NSNumber`, and `true` must not read as the size 1.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func isHexColor(_ value: String) -> Bool {
        value.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil
    }

    private static func isHexColorWithAlpha(_ value: String) -> Bool {
        value.range(of: #"^#[0-9a-fA-F]{8}$"#, options: .regularExpression) != nil
    }

    /// An uploaded image's content reference, as the overlay-config endpoint lists it.
    static func isImageRef(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{64}\.webp$"#, options: .regularExpression) != nil
    }

    // MARK: - Rendering

    /// The document cards render: image refs the library does not list are
    /// dropped, so a deleted image costs no request per card.
    static func withoutUnlistedImages(_ prefs: CardOverlayPrefs, listed: Set<String>) -> CardOverlayPrefs {
        var next = prefs
        for (id, item) in prefs.items {
            var kept = item
            if let image = item.image, !listed.contains(image) { kept.image = nil }
            kept.valueImages = item.valueImages.filter { listed.contains($0.value) }
            if kept != item { next.items[id] = kept }
        }
        return next
    }
}
