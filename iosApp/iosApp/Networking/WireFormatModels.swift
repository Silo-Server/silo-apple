import Foundation

// MARK: - Profiles (server wire format)

/// Full profile payload as returned by the server.
///
/// Distinct from ``UserProfile`` (the reduced shape used by the UI): this
/// type maps every field the server sends. `ContinuumAPI.listProfiles()`
/// converts to `[UserProfile]` at the API boundary so call sites keep
/// their existing types.
struct Profile: Codable {
    let id: String
    let name: String
    let avatar: String?
    /// Server-resolved avatar URL (`avatar_url`). For uploads this is a
    /// short-lived presigned object-store URL that changes on every fetch, so
    /// it must not be persisted long-term. For presets it is a DiceBear URL or
    /// a server-relative `/profile-avatars/{id}.svg` path.
    let avatarUrl: String?
    /// `avatar_source`: "upload", "preset", or "none".
    let avatarSource: String?
    let hasPin: Bool?
    let isChild: Bool?
    let isPrimary: Bool?
    let maxContentRating: String?
    let qualityPreference: String?
    let language: String?
    let subtitleLanguage: String?
    let subtitleMode: String?
    let showForcedSubtitles: Bool?
    /// Preferred metadata language (ISO 639-1). `""`/nil = inherit the
    /// library default. Drives server-side translation of overviews and
    /// taglines in the normal detail/browse responses.
    let preferredMetadataLanguage: String?
    let autoSkipIntro: Bool?
    let autoSkipCredits: Bool?
    let autoSkipRecap: Bool?
    let libraryRestrictionsEnabled: Bool?
    let allowedLibraryIds: [Int]?
    let maxPlaybackQuality: String?
    let createdAt: String?
    let updatedAt: String?

    /// Convert to the reduced ``UserProfile`` shape used by the UI.
    var asUserProfile: UserProfile {
        UserProfile(
            id: id,
            name: name,
            avatarEmoji: avatar,
            avatarImageUrl: avatarUrl,
            hasPin: hasPin ?? false,
            isChild: isChild ?? false,
            isPrimary: isPrimary ?? false,
            subtitleLanguage: subtitleLanguage,
            subtitleMode: subtitleMode,
            showForcedSubtitles: showForcedSubtitles,
            preferredMetadataLanguage: preferredMetadataLanguage
        )
    }
}

/// PUT body for `/api/v1/profiles/{id}`. All fields are optional so the
/// caller can patch one or many at a time. Wire format mirrors the
/// server's `updateProfileRequest`.
struct UpdateProfileBody: Encodable {
    /// Streaming quality ceiling preset ("auto", "1080p", "4k"). Encodes as
    /// `quality_preference`. Written by the onboarding tour's quality step.
    var qualityPreference: String?
    var subtitleLanguage: String?
    var subtitleMode: String?
    var showForcedSubtitles: Bool?
    /// Preferred metadata language (ISO 639-1; `""` = inherit the library
    /// default). Encodes as `preferred_metadata_language`.
    var preferredMetadataLanguage: String?
    var autoSkipIntro: Bool?
    var autoSkipCredits: Bool?
    var autoSkipRecap: Bool?
}

struct ProfilesResponse: Codable {
    let profiles: [Profile]
}

struct VerifyPinRequest: Codable {
    let pin: String
}

struct VerifyPinResponse: Codable {
    let valid: Bool
    let profileToken: String?
    let expiresAt: String?
}

/// Wire-format body for POST /api/v1/profiles.
///
/// Mirrors Kotlin `CreateProfileRequest`. The UI-facing ``CreateProfileBody``
/// carries a subset; `ContinuumAPI.createProfile` expands it to this.
struct CreateProfileRequestBody: Codable {
    let name: String
    let avatar: String?
    let pin: String?
    let isChild: Bool?
    let maxContentRating: String?
    let libraryRestrictionsEnabled: Bool
    let allowedLibraryIds: [Int]
}

// MARK: - Recommendations (wire format for /discover)

struct DiscoverResponse: Codable {
    let rows: [DiscoverRow]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rows = try c.decodeIfPresent([DiscoverRow].self, forKey: .rows) ?? []
    }
}

struct DiscoverRow: Codable {
    let type: String
    let label: String
    let items: [SectionItem]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        label = try c.decode(String.self, forKey: .label)
        items = try c.decodeIfPresent([SectionItem].self, forKey: .items) ?? []
    }
}

// MARK: - Recommendations (wire format for /similar/{id})

/// `/api/v1/recommendations/similar/{itemId}` returns a list of scored
/// item references. Each row carries only the media item ID, a relevance
/// score, and a short reason string — the client resolves each ID to a
/// catalog detail to render a poster card.
struct ScoredItemsResponse: Codable {
    let items: [ScoredItemRef]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([ScoredItemRef].self, forKey: .items) ?? []
    }
}

struct ScoredItemRef: Codable, Hashable, Identifiable {
    let mediaItemId: String
    let score: Double?
    let reason: String?
    var id: String { mediaItemId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaItemId = try c.decode(String.self, forKey: .mediaItemId)
        score = try c.decodeIfPresent(Double.self, forKey: .score)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }
}

// MARK: - Library collections (tolerant decoder)

/// One ordered section of a library tab response: either a named group
/// or the anonymous "Ungrouped" bucket. UI-side type — produced by
/// [LibraryCollectionsWireResponse] regardless of the server's shape.
struct LibraryCollectionSection: Identifiable, Hashable {
    /// Stable identifier — the group id for named sections, or
    /// `"__ungrouped__"` for the anonymous bucket.
    let id: String
    /// Display name. Empty for the anonymous Ungrouped bucket.
    let name: String
    /// Defaults to [LibraryCollectionKind.regular] for the flat-fallback
    /// and Ungrouped sections.
    let kind: LibraryCollectionKind
    let collections: [LibraryCollection]
}

/// Tolerant decoder for /api/v1/library/{id}/collections.
///
/// The server returns one of three shapes:
///  1. A bare JSON array of `LibraryCollection`s (legacy / mocks).
///  2. `{ "collections": [...] }` — flat, used when the deployment has
///     no `GroupRepo` configured.
///  3. `{ "groups": [...], "ungrouped": { "sort_order", "collections" } }`
///     — the modern grouped response.
///
/// Mirrors the Kotlin parser in
/// `SectionApi.parseLibraryCollectionsResponse`.
struct LibraryCollectionsWireResponse: Decodable {
    /// Flat list of all collections, retained for callers that don't
    /// care about grouping.
    let collections: [LibraryCollection]
    /// Ordered sections (groups + Ungrouped, interleaved by sort_order).
    /// Empty for flat responses with no grouping data.
    let sections: [LibraryCollectionSection]

    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            var parsed: [LibraryCollection] = []
            while !array.isAtEnd {
                // Skip elements that fail to decode rather than aborting
                // the whole array — mirrors the Kotlin parser's tolerance.
                // We try the typed decode first; on failure we still need
                // to advance the cursor, which we do by decoding into a
                // permissive placeholder type. Guard the loop with a
                // cursor-advance check so a pathological case where
                // neither decode advances the index cannot hang the app.
                let before = array.currentIndex
                if let item = try? array.decode(LibraryCollection.self) {
                    parsed.append(item)
                } else {
                    _ = try? array.decode(AnyDecodableValue.self)
                }
                if array.currentIndex == before { break }
            }
            self.collections = parsed
            self.sections = []
            return
        }

        let c = try decoder.container(keyedBy: CodingKeys.self)
        let groupsWire = decodeTolerantArray(LibraryTabGroupWire.self, from: c, forKey: .groups)
        let ungroupedWire = try? c.decodeIfPresent(LibraryTabUngroupedWire.self, forKey: .ungrouped)

        if !groupsWire.isEmpty || ungroupedWire != nil {
            // Modern grouped shape — synthesize a flat list for callers
            // that only want one and an ordered section list for the rest.
            var flat: [LibraryCollection] = []
            var slots: [(order: Int, section: LibraryCollectionSection)] = []

            for g in groupsWire {
                let items = g.collections.map { $0.toModel(kind: g.kind) }
                flat.append(contentsOf: items)
                slots.append((
                    order: g.sortOrder,
                    section: LibraryCollectionSection(
                        id: g.id,
                        name: g.name,
                        kind: g.kind,
                        collections: items
                    )
                ))
            }
            if let u = ungroupedWire, !u.collections.isEmpty {
                let items = u.collections.map { $0.toModel(kind: .regular) }
                slots.append((
                    order: u.sortOrder ?? .max,
                    section: LibraryCollectionSection(
                        id: "__ungrouped__",
                        name: "",
                        kind: .regular,
                        collections: items
                    )
                ))
            }

            self.collections = flat
            self.sections = slots.sorted { $0.order < $1.order }.map { $0.section }
            return
        }

        // Flat object shape: { collections: [...] }
        self.collections = decodeTolerantArray(LibraryCollection.self, from: c, forKey: .collections)
        self.sections = []
    }

    private enum CodingKeys: String, CodingKey {
        case collections
        case groups
        case ungrouped
    }
}

/// Wire shape of one element in `LibraryTabResponse.groups`.
private struct LibraryTabGroupWire: Decodable {
    let id: String
    let name: String
    let kind: LibraryCollectionKind
    let sortOrder: Int
    let collections: [LibraryTabCollectionWire]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case sortOrder
        case collections
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Group"
        // Default unknown / missing raw values to .regular instead of
        // aborting the whole group decode.
        let rawKind = try c.decodeIfPresent(String.self, forKey: .kind)
        kind = rawKind.flatMap(LibraryCollectionKind.init(rawValue:)) ?? .regular
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        collections = decodeTolerantArray(LibraryTabCollectionWire.self, from: c, forKey: .collections)
    }
}

/// Wire shape of `LibraryTabResponse.ungrouped`.
private struct LibraryTabUngroupedWire: Decodable {
    let sortOrder: Int?
    let collections: [LibraryTabCollectionWire]

    enum CodingKeys: String, CodingKey {
        case sortOrder
        case collections
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder)
        collections = decodeTolerantArray(LibraryTabCollectionWire.self, from: c, forKey: .collections)
    }
}

/// Per-collection payload inside a group or the ungrouped bucket. Same
/// JSON shape as a regular library collection but the keys are a subset.
private struct LibraryTabCollectionWire: Decodable {
    let id: String
    let title: String
    let posterUrl: String?
    let posterThumbhash: String?
    let itemCount: Int?
    let creatorProfileId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case posterUrl
        case posterThumbhash
        case itemCount
        case creatorProfileId
    }

    func toModel(kind: LibraryCollectionKind) -> LibraryCollection {
        LibraryCollection(
            id: id,
            name: title,
            collectionType: nil,
            itemCount: itemCount,
            posterUrl: posterUrl,
            posterThumbhash: posterThumbhash,
            kind: kind,
            creatorProfileId: creatorProfileId
        )
    }
}


/// Cursor-advancing placeholder used to skip malformed elements inside
/// an unkeyed JSON container without aborting the whole decode.
private struct AnyDecodableValue: Decodable {
    init(from decoder: Decoder) throws {
        if let c = try? decoder.singleValueContainer() {
            _ = try? c.decode(String.self)
            return
        }
    }
}

/// Decode an array field element-by-element, skipping any element that
/// fails to decode. Mirrors the Kotlin parser's `mapNotNull` tolerance:
/// one bad entry should not abort the whole library tab response.
private func decodeTolerantArray<T: Decodable, K: CodingKey>(
    _ type: T.Type,
    from container: KeyedDecodingContainer<K>,
    forKey key: K
) -> [T] {
    guard var arr = try? container.nestedUnkeyedContainer(forKey: key) else { return [] }
    var out: [T] = []
    while !arr.isAtEnd {
        // See `LibraryCollectionsWireResponse.init`: guard against the
        // pathological case where neither the primary nor the fallback
        // decode advances the cursor, which would hang the decode in an
        // infinite loop.
        let before = arr.currentIndex
        if let item = try? arr.decode(T.self) {
            out.append(item)
        } else {
            _ = try? arr.decode(AnyDecodableValue.self)
        }
        if arr.currentIndex == before { break }
    }
    return out
}
