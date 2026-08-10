import Foundation

/// Encodes/decodes `CardOverlayPrefs` to/from the JSON document the server
/// stores under the `ui.card_overlays` contract setting (and, on
/// pre-contract servers, the legacy `card_overlays` user setting). The
/// shape must stay compatible with the web's `parseOverlayPrefs` in
/// `web/src/lib/overlays/schema.ts` and the contract schema
/// `contracts/settings/v1/schemas/card-overlays.json`, since clients
/// share the setting.
enum OverlaySchema {

    /// Build the default prefs document from the registry. Used the
    /// first time a user opens overlay settings, when the server
    /// returns no value, and when JSON parsing fails.
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
        if looksLikeV2(dict) {
            return parseV2(dict)
        }
        return migrateFromV1(dict)
    }

    static func serialize(_ prefs: CardOverlayPrefs) -> String {
        let dict = toDict(prefs)
        // Sorted keys keep the wire format stable so the user setting
        // doesn't churn the server-side change log on every save.
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: options),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    // MARK: - V2

    /// Strict version check: a V2 document MUST carry `version: 2`. Earlier
    /// drafts relied on a heuristic ("looks v2 if it has `preset` and
    /// `items`"), but that would misclassify a future V3 schema that
    /// happens to keep those field names. V1 documents have no `version`
    /// key at all, so they fall through to `migrateFromV1`.
    private static func looksLikeV2(_ dict: [String: Any]) -> Bool {
        (dict["version"] as? Int) == 2
    }

    private static func parseV2(_ dict: [String: Any]) -> CardOverlayPrefs {
        var prefs = buildDefaults()

        if let presetRaw = dict["preset"] as? String,
           let preset = PresetId(rawValue: presetRaw) {
            prefs.preset = preset
        }

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
           let position = OverlayPosition(rawValue: positionRaw) {
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
        return next
    }

    private static func isHexColor(_ value: String) -> Bool {
        value.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil
    }

    // MARK: - Encoding

    private static func toDict(_ prefs: CardOverlayPrefs) -> [String: Any] {
        var items: [String: Any] = [:]
        for (id, cfg) in prefs.items {
            var entry: [String: Any] = [
                "enabled": cfg.enabled,
                "position": cfg.position.rawValue,
            ]
            if let accent = cfg.accentColor { entry["accentColor"] = accent }
            if let showIcon = cfg.showIcon { entry["showIcon"] = showIcon }
            items[id.rawValue] = entry
        }
        return [
            "version": prefs.version,
            "preset": prefs.preset.rawValue,
            "order": prefs.order.map { $0.rawValue },
            "items": items,
        ]
    }
}
