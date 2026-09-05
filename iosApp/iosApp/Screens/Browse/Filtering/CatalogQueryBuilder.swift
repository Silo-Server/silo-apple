import Foundation

/// Builds typed v2 queries shared by the phone and TV filters.
enum CatalogQueryBuilder {
    static func build(
        _ state: CatalogFilterState,
        libraryId: Int?,
        mediaType: BrowseMediaType,
        limit: Int,
        /// Whether to emit the `type` media-scope param. iOS omits it — a
        /// `library_id`-scoped query is already homogeneous, and resolving
        /// the wrong scope (e.g. `movie` for an audiobook library) would
        /// filter every item out. tvOS sends it (it knows the library type).
        includeType: Bool = true
    ) -> APIv2CatalogQuery {
        var q = APIv2CatalogQuery()
        q.limit = limit
        q.sort = state.sort.field
        q.order = state.effectiveOrder.rawValue
        q.match = state.matchAll ? "all" : "any"
        q.libraryId = libraryId.map(String.init)
        if state.mediaScope == nil, includeType { q.type = mediaType.catalogTypeParam }
        q.namePrefix = state.namePrefix

        var groups = GroupAccumulator()
        // A user-chosen Type facet (mixed libraries) is a filter facet, not an
        // unconditional media_scope. Keep it inside the grouped filter logic so
        // top-level Match All / Match Any applies consistently across facets.
        if let scope = state.mediaScope {
            groups.add(field: "type", op: "is", value: scope)
        }
        // Array columns accept `contains`; scalar columns accept `is`.
        groups.add(field: "genre", op: "contains", values: state.genres)
        groups.add(field: "studio", op: "is", values: state.studios)
        groups.add(field: "network", op: "is", values: state.networks)
        groups.add(field: "country", op: "is", values: state.countries)
        groups.add(field: "content_rating", op: "is", values: state.contentRatings)
        groups.add(field: "resolution", op: "is", values: state.resolutions)
        groups.add(field: "audio_language", op: "is", values: state.audioLanguages)
        groups.add(field: "subtitle_language", op: "is", values: state.subtitleLanguages)
        groups.add(field: "original_language", op: "is", values: state.originalLanguages)
        groups.add(field: "author", op: "is", values: state.authors)
        groups.add(field: "narrator", op: "is", values: state.narrators)
        groups.add(field: "series", op: "is", values: state.seriesNames)
        groups.addYearRanges(state.decades)
        groups.addDynamicRange(hdr: state.hdr, dolbyVision: state.dolbyVision)
        if let status = state.watchStatus { groups.addWatchStatus(status) }
        q.groups = groups.encoded()

        return q
    }
}

/// Accumulates typed groups with scalar booleans and numeric year ranges.
private struct GroupAccumulator {
    private struct Rule {
        let field: String
        let op: String
        /// One element → scalar value; two → an ordered range (for `between`).
        let values: [String]
    }
    private var groups: [(match: String, rules: [Rule])] = []

    /// One group per facet: a rule per value, OR'd within the facet.
    mutating func add(field: String, op: String, values: Set<String>) {
        guard !values.isEmpty else { return }
        let rules = values.sorted().map { Rule(field: field, op: op, values: [$0]) }
        groups.append((match: "any", rules: rules))
    }

    mutating func add(field: String, op: String, value: String) {
        groups.append((match: "all", rules: [Rule(field: field, op: op, values: [value])]))
    }

    mutating func addDynamicRange(hdr: Bool, dolbyVision: Bool) {
        var rules: [Rule] = []
        if hdr { rules.append(Rule(field: "hdr", op: "is", values: ["true"])) }
        if dolbyVision { rules.append(Rule(field: "dolby_vision", op: "is", values: ["true"])) }
        guard !rules.isEmpty else { return }
        groups.append((match: "any", rules: rules))
    }

    mutating func addWatchStatus(_ status: WatchStatusFilter) {
        let rule: Rule
        switch status {
        case .unwatched: rule = Rule(field: "watched", op: "is", values: ["false"])
        case .watched: rule = Rule(field: "watched", op: "is", values: ["true"])
        case .inProgress: rule = Rule(field: "in_progress", op: "is", values: ["true"])
        case .favorited: rule = Rule(field: "favorited", op: "is", values: ["true"])
        case .watchlist: rule = Rule(field: "in_watchlist", op: "is", values: ["true"])
        }
        groups.append((match: "all", rules: [rule]))
    }

    /// Each decade becomes a `year between [start, start+9]` rule, OR'd.
    mutating func addYearRanges(_ decades: Set<Int>) {
        guard !decades.isEmpty else { return }
        let rules = decades.sorted().map { start in
            Rule(field: "year", op: "between", values: [String(start), String(start + 9)])
        }
        groups.append((match: "any", rules: rules))
    }

    func encoded() -> [APIv2CatalogGroup] {
        groups.map { group in
            APIv2CatalogGroup(match: group.match, rules: group.rules.map { rule in
                let value: APIv2CatalogRuleValue
                if rule.field == "year" {
                    value = .numbers(rule.values.compactMap(Double.init))
                } else if ["hdr", "dolby_vision", "watched", "in_progress", "favorited", "in_watchlist"].contains(rule.field) {
                    value = .bool(rule.values.first == "true")
                } else {
                    value = .string(rule.values[0])
                }
                return APIv2CatalogRule(field: rule.field, op: rule.op, value: value)
            })
        }
    }
}
