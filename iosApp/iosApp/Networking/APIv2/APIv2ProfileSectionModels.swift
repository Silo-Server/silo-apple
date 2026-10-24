import Foundation

// The acting profile's own Home layout (`/api/v2/profile/sections*`). These
// documents carry section `config` objects whose keys belong to each recipe,
// so they are decoded and encoded with plain coders and explicit coding keys,
// never the shared snake_case strategy that would rewrite those keys.

/// `ProfileSectionSetting`: one Home row as the acting profile sees it,
/// hidden rows included. `id` is the admin section id, or for a row the
/// profile built itself (`isCustom`) the id of its own override.
struct APIv2ProfileSectionSetting: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let sectionType: String
    let title: String
    let defaultTitle: String
    let featured: Bool
    let itemLimit: Int
    var hidden: Bool
    let isCustom: Bool
    let customized: Bool
    let position: Int
    let config: [String: SettingJSONValue]?

    private enum CodingKeys: String, CodingKey {
        case id
        case sectionType = "section_type"
        case title
        case defaultTitle = "default_title"
        case featured
        case itemLimit = "item_limit"
        case hidden
        case isCustom = "is_custom"
        case customized
        case position
        case config
    }
}

/// `SectionOverride` as read, and `SectionOverrideWrite` as sent: one saved
/// change of the profile's layout. Encoding writes only the members the write
/// schema allows (it rejects unknown members, so the read-only timestamps are
/// never sent), and omits the config objects when none is saved, because
/// `{}` would save an explicitly empty config.
struct APIv2SectionOverride: Codable, Hashable, Sendable {
    var id: String
    /// The admin section this customizes; empty for a profile-built row.
    var sectionId: String
    /// Nil keeps the admin order.
    var position: Int?
    var hidden: Bool
    var removed: Bool
    var sectionType: String
    var title: String
    var featured: Bool?
    var itemLimit: Int?
    var isUserAdded: Bool
    var userSectionType: String
    var userTitle: String
    var config: [String: SettingJSONValue]?
    var userConfig: [String: SettingJSONValue]?

    init(
        id: String,
        sectionId: String,
        position: Int?,
        hidden: Bool,
        removed: Bool = false,
        sectionType: String = "",
        title: String = "",
        featured: Bool? = nil,
        itemLimit: Int? = nil,
        isUserAdded: Bool = false,
        userSectionType: String = "",
        userTitle: String = "",
        config: [String: SettingJSONValue]? = nil,
        userConfig: [String: SettingJSONValue]? = nil
    ) {
        self.id = id
        self.sectionId = sectionId
        self.position = position
        self.hidden = hidden
        self.removed = removed
        self.sectionType = sectionType
        self.title = title
        self.featured = featured
        self.itemLimit = itemLimit
        self.isUserAdded = isUserAdded
        self.userSectionType = userSectionType
        self.userTitle = userTitle
        self.config = config
        self.userConfig = userConfig
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sectionId = "section_id"
        case position
        case hidden
        case removed
        case sectionType = "section_type"
        case title
        case featured
        case itemLimit = "item_limit"
        case isUserAdded = "is_user_added"
        case userSectionType = "user_section_type"
        case userTitle = "user_title"
        case config
        case userConfig = "user_config"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sectionId = try c.decode(String.self, forKey: .sectionId)
        position = try c.decodeIfPresent(Int.self, forKey: .position)
        hidden = try c.decode(Bool.self, forKey: .hidden)
        removed = try c.decode(Bool.self, forKey: .removed)
        sectionType = try c.decode(String.self, forKey: .sectionType)
        title = try c.decode(String.self, forKey: .title)
        featured = try c.decodeIfPresent(Bool.self, forKey: .featured)
        itemLimit = try c.decodeIfPresent(Int.self, forKey: .itemLimit)
        isUserAdded = try c.decode(Bool.self, forKey: .isUserAdded)
        userSectionType = try c.decode(String.self, forKey: .userSectionType)
        userTitle = try c.decode(String.self, forKey: .userTitle)
        config = try c.decodeIfPresent([String: SettingJSONValue].self, forKey: .config)
        userConfig = try c.decodeIfPresent([String: SettingJSONValue].self, forKey: .userConfig)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if !sectionId.isEmpty { try c.encode(sectionId, forKey: .sectionId) }
        try c.encode(position, forKey: .position)
        try c.encode(hidden, forKey: .hidden)
        try c.encode(removed, forKey: .removed)
        try c.encode(sectionType, forKey: .sectionType)
        try c.encode(title, forKey: .title)
        try c.encode(featured, forKey: .featured)
        try c.encode(itemLimit, forKey: .itemLimit)
        try c.encode(isUserAdded, forKey: .isUserAdded)
        try c.encode(userSectionType, forKey: .userSectionType)
        try c.encode(userTitle, forKey: .userTitle)
        try c.encodeIfPresent(config, forKey: .config)
        try c.encodeIfPresent(userConfig, forKey: .userConfig)
    }
}

/// The two reads an editor of the profile's Home layout starts from, taken
/// for one owner: the rows in the order the profile sees them and the
/// overrides it has saved.
struct APIv2ProfileHomeLayoutRead: Sendable {
    let auth: CapturedOrdinaryRequestAuth
    let rows: [APIv2ProfileSectionSetting]
    let saved: [APIv2SectionOverride]
}
