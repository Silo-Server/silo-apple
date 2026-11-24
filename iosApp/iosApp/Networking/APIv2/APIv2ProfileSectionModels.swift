import Foundation

// The acting profile's own Home & Library layout (`/api/v2/profile/sections*`)
// and section recipe gallery (`/api/v2/sections/recipes`). These documents carry
// section `config` objects whose keys belong to each recipe, so they are decoded
// and encoded with plain coders and explicit coding keys, never the shared
// snake_case strategy that would rewrite those keys.

/// Identifies which page's section layout is being read or saved.
enum ProfileSectionsScope: Hashable, Sendable {
    case home
    case library(Int)

    var queryItems: [String: String] {
        switch self {
        case .home:
            return ["scope": "home"]
        case .library(let libraryId):
            return ["scope": "library", "library_id": String(libraryId)]
        }
    }
}

/// `ProfileSectionSetting`: one row as the acting profile sees it, hidden rows
/// included. `id` is the admin section id, or for a row the profile built
/// itself (`isCustom`) the id of its own override.
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

    init(
        id: String,
        sectionType: String,
        title: String,
        defaultTitle: String = "",
        featured: Bool = false,
        itemLimit: Int = 20,
        hidden: Bool = false,
        isCustom: Bool = false,
        customized: Bool = false,
        position: Int = 0,
        config: [String: SettingJSONValue]? = nil
    ) {
        self.id = id
        self.sectionType = sectionType
        self.title = title
        self.defaultTitle = defaultTitle
        self.featured = featured
        self.itemLimit = itemLimit
        self.hidden = hidden
        self.isCustom = isCustom
        self.customized = customized
        self.position = position
        self.config = config
    }

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

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let defTrimmed = defaultTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !defTrimmed.isEmpty { return defTrimmed }
        return sectionType.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var userCollectionId: String? {
        if case .string(let value) = config?["user_collection_id"], !value.isEmpty {
            return value
        }
        return nil
    }

    var libraryCollectionId: String? {
        if case .string(let value) = config?["library_collection_id"], !value.isEmpty {
            return value
        }
        return nil
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

/// The two reads an editor of a profile page layout starts from, taken for one
/// owner: the rows in display order and the overrides saved for that page.
struct APIv2ProfileLayoutRead: Sendable {
    let auth: CapturedOrdinaryRequestAuth
    let scope: ProfileSectionsScope
    let rows: [APIv2ProfileSectionSetting]
    let saved: [APIv2SectionOverride]
}

// MARK: - Section Recipe Catalog

struct APIv2RecipePreset: Decodable, Hashable, Identifiable, Sendable {
    let key: String
    let displayName: String
    let icon: String
    let descriptionShort: String
    let descriptionLong: String
    let defaultParams: [String: SettingJSONValue]

    var id: String { key }

    init(
        key: String,
        displayName: String,
        icon: String,
        descriptionShort: String,
        descriptionLong: String = "",
        defaultParams: [String: SettingJSONValue] = [:]
    ) {
        self.key = key
        self.displayName = displayName
        self.icon = icon
        self.descriptionShort = descriptionShort
        self.descriptionLong = descriptionLong
        self.defaultParams = defaultParams
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case displayName = "display_name"
        case icon
        case descriptionShort = "description_short"
        case descriptionLong = "description_long"
        case defaultParams = "default_params"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        displayName = try c.decode(String.self, forKey: .displayName)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? ""
        descriptionShort = try c.decodeIfPresent(String.self, forKey: .descriptionShort) ?? ""
        descriptionLong = try c.decodeIfPresent(String.self, forKey: .descriptionLong) ?? ""
        defaultParams = try c.decodeIfPresent([String: SettingJSONValue].self, forKey: .defaultParams) ?? [:]
    }
}

struct APIv2RecipeDefinition: Decodable, Hashable, Identifiable, Sendable {
    let type: String
    let category: String
    let presets: [APIv2RecipePreset]
    let avoidDuplicates: Bool
    let supportsRotation: Bool
    let adminOnly: Bool

    var id: String { type }

    init(
        type: String,
        category: String,
        presets: [APIv2RecipePreset],
        avoidDuplicates: Bool = false,
        supportsRotation: Bool = false,
        adminOnly: Bool = false
    ) {
        self.type = type
        self.category = category
        self.presets = presets
        self.avoidDuplicates = avoidDuplicates
        self.supportsRotation = supportsRotation
        self.adminOnly = adminOnly
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case category
        case presets
        case avoidDuplicates = "avoid_duplicates"
        case supportsRotation = "supports_rotation"
        case adminOnly = "admin_only"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        category = try c.decode(String.self, forKey: .category)
        presets = try c.decodeIfPresent([APIv2RecipePreset].self, forKey: .presets) ?? []
        avoidDuplicates = try c.decodeIfPresent(Bool.self, forKey: .avoidDuplicates) ?? false
        supportsRotation = try c.decodeIfPresent(Bool.self, forKey: .supportsRotation) ?? false
        adminOnly = try c.decodeIfPresent(Bool.self, forKey: .adminOnly) ?? false
    }
}

struct APIv2RecipeCategory: Decodable, Hashable, Identifiable, Sendable {
    let category: String
    let recipes: [APIv2RecipeDefinition]

    var id: String { category }
}

struct APIv2RecipeCatalog: Decodable, Sendable {
    let categories: [APIv2RecipeCategory]

    /// Curated built-in recipes used if `/api/v2/sections/recipes` is unreachable.
    static let curatedFallback = APIv2RecipeCatalog(categories: [
        APIv2RecipeCategory(category: "keep_watching", recipes: [
            APIv2RecipeDefinition(type: "continue_watching", category: "keep_watching", presets: [
                APIv2RecipePreset(
                    key: "continue_watching",
                    displayName: "Continue Watching",
                    icon: "play.circle.fill",
                    descriptionShort: "Pick up movies and episodes where you left off."
                ),
            ]),
            APIv2RecipeDefinition(type: "next_up", category: "keep_watching", presets: [
                APIv2RecipePreset(
                    key: "next_up",
                    displayName: "Next Up",
                    icon: "forward.end.fill",
                    descriptionShort: "The next unwatched episode for series you're watching."
                ),
            ]),
            APIv2RecipeDefinition(type: "watchlist", category: "keep_watching", presets: [
                APIv2RecipePreset(
                    key: "watchlist",
                    displayName: "My Watchlist",
                    icon: "bookmark.fill",
                    descriptionShort: "Titles you saved to watch later."
                ),
            ]),
            APIv2RecipeDefinition(type: "favorites", category: "keep_watching", presets: [
                APIv2RecipePreset(
                    key: "favorites",
                    displayName: "Favorites",
                    icon: "heart.fill",
                    descriptionShort: "Movies and shows you've hearted."
                ),
            ]),
        ]),
        APIv2RecipeCategory(category: "whats_new", recipes: [
            APIv2RecipeDefinition(type: "recently_added", category: "whats_new", presets: [
                APIv2RecipePreset(
                    key: "recently_added",
                    displayName: "Recently Added",
                    icon: "sparkles",
                    descriptionShort: "Newest additions across your libraries."
                ),
            ]),
            APIv2RecipeDefinition(type: "recently_released", category: "whats_new", presets: [
                APIv2RecipePreset(
                    key: "recently_released",
                    displayName: "Recently Released",
                    icon: "calendar.badge.clock",
                    descriptionShort: "Fresh theatrical and streaming releases in your library."
                ),
            ]),
        ]),
        APIv2RecipeCategory(category: "popular", recipes: [
            APIv2RecipeDefinition(type: "trending_on_server", category: "popular", presets: [
                APIv2RecipePreset(
                    key: "trending_on_server",
                    displayName: "Trending on Server",
                    icon: "flame.fill",
                    descriptionShort: "What people on this server are watching right now."
                ),
            ]),
            APIv2RecipeDefinition(type: "most_watched", category: "popular", presets: [
                APIv2RecipePreset(
                    key: "most_watched",
                    displayName: "Most Watched",
                    icon: "chart.bar.fill",
                    descriptionShort: "All-time favorites with the most plays on this server."
                ),
            ]),
        ]),
        APIv2RecipeCategory(category: "for_you", recipes: [
            APIv2RecipeDefinition(type: "recommended_for_you", category: "for_you", presets: [
                APIv2RecipePreset(
                    key: "recommended_for_you",
                    displayName: "Recommended for You",
                    icon: "wand.and.stars",
                    descriptionShort: "Tailored picks based on your watch history."
                ),
            ]),
            APIv2RecipeDefinition(type: "because_you_watched", category: "for_you", presets: [
                APIv2RecipePreset(
                    key: "because_you_watched",
                    displayName: "Because You Watched",
                    icon: "sparkles.tv",
                    descriptionShort: "Similar titles inspired by something you recently enjoyed."
                ),
            ]),
        ]),
    ])
}

/// Shared SF Symbol + category display helpers for section recipes.
enum SectionRecipePresentation {
    static func symbol(for sectionType: String) -> String {
        switch sectionType.lowercased() {
        case "continue_watching", "in_progress": return "play.circle.fill"
        case "next_up": return "forward.end.fill"
        case "next_in_series": return "books.vertical.fill"
        case "watchlist": return "bookmark.fill"
        case "favorites": return "heart.fill"
        case "recently_added": return "sparkles"
        case "recently_released": return "calendar"
        case "new_to_library": return "calendar.badge.plus"
        case "returning_shows": return "arrow.clockwise.circle.fill"
        case "trending_on_server", "trending": return "chart.line.uptrend.xyaxis"
        case "most_watched", "popular": return "chart.bar.fill"
        case "trending_discover", "tmdb_trending": return "flame.fill"
        case "profile_activity_feed": return "person.2.fill"
        case "recommended_for_you", "for_you": return "wand.and.stars"
        case "because_you_watched": return "sparkles.tv"
        case "similar_users_liked": return "person.2.wave.2.fill"
        case "taste_match": return "star.circle.fill"
        case "mood_collection", "mood": return "theatermasks.fill"
        case "seasonal_themed", "seasonal", "seasonal_picks": return "leaf.fill"
        case "editorial_spotlight": return "film.stack.fill"
        case "format_showcase": return "4k.tv.fill"
        case "hidden_gems": return "diamond.fill"
        case "critically_acclaimed": return "trophy.fill"
        case "forgotten_favorites": return "clock.arrow.circlepath"
        case "genre_roulette": return "dice.fill"
        case "random": return "shuffle"
        case "short_watches": return "timer"
        case "anniversaries": return "gift.fill"
        case "collection", "user_collection", "library_collection":
            return "square.stack.fill"
        case "collection_posters":
            return "square.grid.2x2.fill"
        case "genre": return "tag.fill"
        default: return "rectangle.stack.fill"
        }
    }

    static func categoryTitle(for category: String) -> String {
        switch category.lowercased() {
        case "keep_watching", "personal", "watch_activity": return "Keep Watching"
        case "whats_new", "library_staples", "new", "fresh": return "What's New"
        case "popular", "trending", "community", "social": return "Popular"
        case "for_you", "personalized", "recommendations": return "For You"
        case "moods", "mood", "discovery", "curated", "seasonal", "editorial": return "Moods & Discovery"
        case "hand_picked": return "Collections"
        default:
            return category.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
