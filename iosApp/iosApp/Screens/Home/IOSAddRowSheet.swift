#if !os(tvOS)
import SwiftUI

// MARK: - Native iOS Add Row Flow

/// Native inset-grouped Add Row sheet matching iOS Settings / Shortcuts / Health
/// drill-in patterns:
/// - Root searchable catalog grouping Collections and curated recipe families
/// - Push into native Configure Row form with variant selection, recipe-specific
///   controls, editable Row Name, Item Limit stepper, and Hero Banner toggle
/// - Push into native Collection Picker or multi-select Row of Collections builder
struct IOSAddRowSheet: View {
    @Bindable var editor: HomeSectionsEditorModel
    var pageTitle: String? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var searchText = ""

    private var pageLabel: String {
        if let pageTitle, !pageTitle.isEmpty { return pageTitle }
        return AppLanguage.string(editor.scope == .home ? .tabHome : .libraryLibraryTab, locale: locale)
    }

    private var totalCollectionCount: Int {
        editor.personalCollections.count + editor.serverCollections.count
    }

    private var catalogGroups: [AddRowGroup] {
        AddRowCatalog.groups(from: editor.recipeCatalog, locale: locale)
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !trimmedQuery.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if isSearching {
                    searchResultsSections
                } else {
                    collectionsSection
                    recipeGroupSections
                }
            }
            #if os(macOS)
            .settingsListChrome()
            #else
            .siloGroupedListStyle()
            #endif
            .scrollDismissesKeyboard(.interactively)
            #if os(iOS)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text(.homeAddRowSearchPrompt)
            )
            #else
            .searchable(text: $searchText, prompt: Text(.homeAddRowSearchPrompt))
            #endif
            .navigationTitle(Text(.homeCustomizeAddRow))
            .siloNavigationTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.commonCancel) { dismiss() }
                }
            }
        }
        .task {
            await editor.loadPickerCatalogIfNeeded(force: true)
        }
    }

    // MARK: - Collections Section

    private var collectionsSection: some View {
        Section {
            NavigationLink {
                IOSCollectionPickerView(
                    editor: editor,
                    pageLabel: pageLabel,
                    onFinished: { dismiss() }
                )
            } label: {
                AddRowCatalogCell(
                    symbol: "square.stack.fill",
                    title: AppLanguage.string(.homeAddRowACollectionTitle, locale: locale),
                    subtitle: AppLanguage.string(.homeAddRowACollectionSubtitle, locale: locale),
                    trailingValue: totalCollectionCount > 0 ? LocaleFormat.integer(totalCollectionCount, locale: locale) : nil
                )
            }

            NavigationLink {
                IOSCollectionPostersBuilderView(
                    editor: editor,
                    pageLabel: pageLabel,
                    onFinished: { dismiss() }
                )
            } label: {
                AddRowCatalogCell(
                    symbol: "square.grid.2x2.fill",
                    title: AppLanguage.string(.homeAddRowRowOfCollectionsTitle, locale: locale),
                    subtitle: AppLanguage.string(.homeAddRowRowOfCollectionsSubtitle, locale: locale),
                    trailingValue: nil
                )
            }
        } header: {
            Text(.collectionsTitle)
        }
    }

    // MARK: - Recipe Group Sections

    @ViewBuilder
    private var recipeGroupSections: some View {
        ForEach(catalogGroups) { group in
            Section {
                ForEach(group.entries) { entry in
                    NavigationLink {
                        IOSConfigureRecipeRowView(
                            editor: editor,
                            entry: entry,
                            initialPresetKey: nil,
                            pageLabel: pageLabel,
                            onFinished: { dismiss() }
                        )
                    } label: {
                        AddRowCatalogCell(
                            symbol: entry.symbol,
                            title: entry.title,
                            subtitle: entry.subtitle,
                            trailingValue: editor.isRecipeTypePresent(sectionType: entry.definition.type)
                                ? AppLanguage.string(.homeAddRowOnPageBadge(pageLabel), locale: locale)
                                : nil
                        )
                    }
                }
            } header: {
                Text(verbatim: group.title)
            }
        }
    }

    // MARK: - Search Results

    @ViewBuilder
    private var searchResultsSections: some View {
        let query = trimmedQuery
        let matchedRecipes = AddRowCatalog.search(groups: catalogGroups, query: query)
        let matchedPersonal = editor.personalCollections.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
        let matchedServer = editor.serverCollections.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.libraryName.localizedCaseInsensitiveContains(query)
        }

        if matchedRecipes.isEmpty && matchedPersonal.isEmpty && matchedServer.isEmpty {
            ContentUnavailableView.search(text: query)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            if !matchedRecipes.isEmpty {
                Section(.homeAddRowSectionRows) {
                    ForEach(matchedRecipes) { hit in
                        NavigationLink {
                            IOSConfigureRecipeRowView(
                                editor: editor,
                                entry: hit.entry,
                                initialPresetKey: hit.matchedPresetKey,
                                pageLabel: pageLabel,
                                onFinished: { dismiss() }
                            )
                        } label: {
                            AddRowCatalogCell(
                                symbol: hit.entry.symbol,
                                title: hit.matchedPresetTitle ?? hit.entry.title,
                                subtitle: hit.matchedPresetTitle != nil
                                    ? "\(hit.entry.title) · \(hit.matchedSubtitle)"
                                    : hit.entry.subtitle,
                                trailingValue: editor.isRecipeTypePresent(sectionType: hit.entry.definition.type)
                                    ? AppLanguage.string(.homeAddRowOnPageBadge(pageLabel), locale: locale)
                                    : nil
                            )
                        }
                    }
                }
            }

            if !matchedPersonal.isEmpty {
                Section(.homeAddRowSectionYourCollections) {
                    ForEach(matchedPersonal) { collection in
                        NavigationLink {
                            IOSConfigureCollectionRowView(
                                editor: editor,
                                collection: .personal(collection),
                                pageLabel: pageLabel,
                                onFinished: { dismiss() }
                            )
                        } label: {
                            CollectionListRowLabel(
                                title: collection.name,
                                subtitle: itemCountLabel(collection.itemCount, locale: locale),
                                posterUrl: collection.posterUrl,
                                posterThumbhash: collection.posterThumbhash,
                                badge: editor.isCollectionPresent(collectionId: collection.id, isUserCollection: true)
                                    ? AppLanguage.string(.homeAddRowOnPageBadge(pageLabel), locale: locale)
                                    : nil
                            )
                        }
                    }
                }
            }

            if !matchedServer.isEmpty {
                Section(.homeAddRowSectionServerCollections) {
                    ForEach(matchedServer) { collection in
                        NavigationLink {
                            IOSConfigureCollectionRowView(
                                editor: editor,
                                collection: .server(collection),
                                pageLabel: pageLabel,
                                onFinished: { dismiss() }
                            )
                        } label: {
                            CollectionListRowLabel(
                                title: collection.title,
                                subtitle: serverCollectionSubtitle(collection, locale: locale),
                                posterUrl: collection.posterUrl,
                                posterThumbhash: collection.posterThumbhash,
                                badge: editor.isCollectionPresent(collectionId: collection.id, isUserCollection: false)
                                    ? AppLanguage.string(.homeAddRowOnPageBadge(pageLabel), locale: locale)
                                    : nil
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Configure Recipe Row (Step 2)

private struct IOSConfigureRecipeRowView: View {
    @Bindable var editor: HomeSectionsEditorModel
    let entry: AddRowEntry
    let initialPresetKey: String?
    let pageLabel: String
    let onFinished: () -> Void

    @State private var selectedPresetKey: String
    @State private var rowName: String
    @State private var titleFollowsVariant = true
    @State private var itemLimit: Int = 20
    @State private var isHeroBanner = false

    // Recipe-specific native fields
    @State private var selectedLibraryIds: Set<Int> = []
    @State private var filterMediaType: String = "all"
    @State private var listSortOrder: String = "default"
    @State private var lookbackDays: Int = 30
    @State private var maxMinutes: Int = 95
    @State private var milestoneYears: Int = 5
    @State private var genreFilter: String = ""
    @State private var autoRotate: Bool = true
    @State private var rotationCadence: String = "weekly"
    @State private var pinnedSubject: String = ""
    @State private var enabledSeasonalThemes: Set<String> = Set(AddRowCatalog.defaultHolidayThemeKeys)

    @State private var selectionHaptic = 0
    @State private var confirmHaptic = 0

    init(
        editor: HomeSectionsEditorModel,
        entry: AddRowEntry,
        initialPresetKey: String?,
        pageLabel: String,
        onFinished: @escaping () -> Void
    ) {
        self.editor = editor
        self.entry = entry
        self.initialPresetKey = initialPresetKey
        self.pageLabel = pageLabel
        self.onFinished = onFinished

        let presets = entry.definition.presets
        let chosen = presets.first(where: { $0.key == initialPresetKey }) ?? presets.first
        let initialKey = chosen?.key ?? entry.definition.type
        let initialTitle = chosen?.displayName ?? entry.title

        _selectedPresetKey = State(initialValue: initialKey)
        _rowName = State(initialValue: initialTitle)

        // Seed recipe-specific defaults from chosen preset's params.
        let params = chosen?.defaultParams ?? [:]
        if let days = params["lookback_days"]?.intValue, days > 0 {
            _lookbackDays = State(initialValue: days)
        }
        if let mins = params["max_minutes"]?.intValue, mins > 0 {
            _maxMinutes = State(initialValue: mins)
        }
        if let years = params["milestone_years"]?.intValue, years > 0 {
            _milestoneYears = State(initialValue: years)
        }
        if let rotate = params["auto_rotate"]?.boolValue {
            _autoRotate = State(initialValue: rotate)
        } else if let subject = params["subject"]?.stringValue, !subject.isEmpty {
            _autoRotate = State(initialValue: false)
            _pinnedSubject = State(initialValue: subject)
        }
        if let cadence = params["rotation_cadence"]?.stringValue, !cadence.isEmpty {
            _rotationCadence = State(initialValue: cadence)
        }
        if let themes = params["enabled_themes"]?.arrayValue {
            let keys = themes.compactMap(\.stringValue)
            if !keys.isEmpty {
                _enabledSeasonalThemes = State(initialValue: Set(keys))
            }
        }
    }

    private var sectionType: String {
        entry.definition.type.lowercased()
    }

    private var activePreset: APIv2RecipePreset? {
        entry.definition.presets.first(where: { $0.key == selectedPresetKey })
            ?? entry.definition.presets.first
    }

    private var defaultRowName: String {
        activePreset?.displayName ?? entry.title
    }

    private var effectiveTitle: String {
        let trimmed = rowName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultRowName : trimmed
    }

    private var isSpotlightEraPreset: Bool {
        sectionType == "editorial_spotlight" && selectedPresetKey == "es_era_80s"
    }

    private var isSeasonalHolidaysPreset: Bool {
        sectionType == "seasonal_themed" && selectedPresetKey != "se_family_movie_night"
    }

    private var canSubmit: Bool {
        if sectionType == "editorial_spotlight", !isSpotlightEraPreset, !autoRotate {
            return !pinnedSubject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if isSeasonalHolidaysPreset {
            return !enabledSeasonalThemes.isEmpty
        }
        return true
    }

    private var builtConfig: [String: SettingJSONValue] {
        var config = activePreset?.defaultParams ?? [:]

        switch sectionType {
        case "recently_added", "recently_released":
            if editor.scope == .home, !selectedLibraryIds.isEmpty {
                let ids = selectedLibraryIds.sorted().map { SettingJSONValue.int($0) }
                config["filter_library_ids"] = .array(ids)
            }
        case "trending_discover":
            if filterMediaType != "all" {
                config["filter_type"] = .string(filterMediaType)
            } else {
                config.removeValue(forKey: "filter_type")
            }
        case "watchlist", "favorites":
            if filterMediaType != "all" {
                config["filter_type"] = .string(filterMediaType)
            } else {
                config.removeValue(forKey: "filter_type")
            }
            if editor.scope == .home, !selectedLibraryIds.isEmpty {
                let ids = selectedLibraryIds.sorted().map { SettingJSONValue.int($0) }
                config["filter_library_ids"] = .array(ids)
            }
            if listSortOrder != "default" {
                let parts = listSortOrder.split(separator: ":")
                if parts.count == 2 {
                    config["sort"] = .string(String(parts[0]))
                    config["order"] = .string(String(parts[1]))
                }
            }
        case "returning_shows":
            config["lookback_days"] = .int(lookbackDays)
        case "short_watches":
            config["max_minutes"] = .int(maxMinutes)
        case "anniversaries":
            config["milestone_years"] = .int(milestoneYears)
        case "taste_match":
            let genre = genreFilter.trimmingCharacters(in: .whitespacesAndNewlines)
            if !genre.isEmpty {
                config["genre"] = .string(genre)
            } else {
                config.removeValue(forKey: "genre")
            }
        case "editorial_spotlight":
            if !isSpotlightEraPreset {
                config["auto_rotate"] = .bool(autoRotate)
                if autoRotate {
                    config["rotation_cadence"] = .string(rotationCadence)
                    config.removeValue(forKey: "subject")
                } else {
                    config.removeValue(forKey: "rotation_cadence")
                    config["subject"] = .string(pinnedSubject.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        case "seasonal_themed":
            if isSeasonalHolidaysPreset {
                let ordered = AddRowCatalog.holidayThemes
                    .map(\.key)
                    .filter { enabledSeasonalThemes.contains($0) }
                config["enabled_themes"] = .array(ordered.map { .string($0) })
            }
        default:
            break
        }

        return config
    }

    private var alreadyOnPage: Bool {
        editor.isRecipePresent(sectionType: entry.definition.type, params: builtConfig)
    }

    private var hiddenOnPage: Bool {
        !alreadyOnPage && editor.hasHiddenMatchingRecipe(sectionType: entry.definition.type, params: builtConfig)
    }

    var body: some View {
        List {
            previewHeaderSection
            variantPickerSection
            recipeOptionsSection
            rowNameSection
            displayOptionsSection
        }
        #if os(macOS)
        .settingsListChrome()
        #else
        .siloGroupedListStyle()
        #endif
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(entry.title)
        .siloNavigationTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(.profilesAdd) {
                    confirmHaptic += 1
                    editor.addRecipeRow(
                        sectionType: entry.definition.type,
                        title: effectiveTitle,
                        config: builtConfig,
                        itemLimit: itemLimit,
                        featured: editor.scope == .home ? isHeroBanner : false
                    )
                    onFinished()
                }
                .fontWeight(.semibold)
                .disabled(!canSubmit)
            }
        }
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: selectionHaptic)
        .sensoryFeedback(.success, trigger: confirmHaptic)
        #endif
    }

    // MARK: - Preview Header

    private var previewHeaderSection: some View {
        Section {
            HStack(spacing: 14) {
                AddRowIconTile(symbol: activePresetSymbol, size: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: effectiveTitle)
                        .font(.headline)
                        .foregroundStyle(Color.siloOnSurface)
                        .lineLimit(2)

                    Text(verbatim: activeDescription)
                        .font(.footnote)
                        .foregroundStyle(Color.siloSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)

            if alreadyOnPage {
                Label(.homeAddRowAlreadyOnPageNote(pageLabel), systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(Color.siloSecondaryText)
            } else if hiddenOnPage {
                Label(.homeAddRowHiddenOnPageNote(pageLabel), systemImage: "eye")
                    .font(.footnote)
                    .foregroundStyle(Color.siloSecondaryText)
            }
        }
    }

    private var activePresetSymbol: String {
        if let presetKey = activePreset?.key,
           let customSymbol = AddRowCatalog.presetSymbol(for: presetKey) {
            return customSymbol
        }
        return entry.symbol
    }

    private var activeDescription: String {
        if let long = activePreset?.descriptionLong, !long.isEmpty {
            return long
        }
        if let short = activePreset?.descriptionShort, !short.isEmpty {
            return short
        }
        return entry.subtitle
    }

    // MARK: - Variant Picker

    @ViewBuilder
    private var variantPickerSection: some View {
        let presets = entry.definition.presets
        if presets.count > 1 {
            Section {
                ForEach(presets) { preset in
                    let isSelected = preset.key == selectedPresetKey
                    Button {
                        selectPreset(preset)
                    } label: {
                        HStack(spacing: 12) {
                            if let symbol = AddRowCatalog.presetSymbol(for: preset.key) {
                                Image(systemName: symbol)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(isSelected ? Color.siloPrimary : Color.siloSecondaryText)
                                    .frame(width: 22)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.displayName)
                                    .font(.body)
                                    .foregroundStyle(Color.siloOnSurface)
                                if !preset.descriptionShort.isEmpty {
                                    Text(preset.descriptionShort)
                                        .font(.caption)
                                        .foregroundStyle(Color.siloSecondaryText)
                                        .lineLimit(2)
                                }
                            }

                            Spacer(minLength: 8)

                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.siloPrimary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(AddRowCatalog.variantSectionTitle(for: sectionType))
            }
        }
    }

    private func selectPreset(_ preset: APIv2RecipePreset) {
        guard preset.key != selectedPresetKey else { return }
        selectionHaptic += 1
        selectedPresetKey = preset.key
        if titleFollowsVariant {
            rowName = preset.displayName
        }
        if sectionType == "editorial_spotlight" {
            if preset.key == "es_era_80s" {
                autoRotate = false
                pinnedSubject = "1980s"
            } else {
                autoRotate = true
                pinnedSubject = ""
            }
        }
        if sectionType == "seasonal_themed", preset.key != "se_family_movie_night" {
            if enabledSeasonalThemes.isEmpty {
                enabledSeasonalThemes = Set(AddRowCatalog.defaultHolidayThemeKeys)
            }
        }
    }

    // MARK: - Recipe-Specific Options

    @ViewBuilder
    private var recipeOptionsSection: some View {
        switch sectionType {
        case "recently_added", "recently_released":
            if editor.scope == .home && editor.availableLibraries.count > 1 {
                Section(.libraryLibraries) {
                    libraryFilterLink
                }
            }

        case "trending_discover":
            Section(.homeAddRowSectionInclude) {
                Picker(.searchMediaTypePicker, selection: $filterMediaType) {
                    Text(.settingsManifestUiCardQuickActionsOptionBoth).tag("all")
                    Text(.boxSetsMovies).tag("movie")
                    Text(.personalFilterTvShows).tag("series")
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            }

        case "watchlist", "favorites":
            Section(.homeAddRowSectionFilterSort) {
                Picker(.searchMediaTypePicker, selection: $filterMediaType) {
                    Text(.settingsManifestSearchMediaScopeOptionAll).tag("all")
                    Text(.boxSetsMovies).tag("movie")
                    Text(.homeAddRowMediaShows).tag("series")
                    Text(.libraryKindAudiobooks).tag("audiobook")
                }

                Picker(.homeAddRowSortOrder, selection: $listSortOrder) {
                    Text(.detailTrackDefault).tag("default")
                    Text(.homeSectionRecentlyAdded).tag("added_at:desc")
                    Text(.homeAddRowSortOldestAdded).tag("added_at:asc")
                    Text(.homeAddRowSortTitleAsc).tag("title:asc")
                    Text(.homeAddRowSortTitleDesc).tag("title:desc")
                    Text(.homeAddRowSortNewestRelease).tag("release_date:desc")
                    Text(.homeAddRowSortOldestRelease).tag("release_date:asc")
                    Text(.homeAddRowSortHighestImdb).tag("rating_imdb:desc")
                }

                if editor.scope == .home && editor.availableLibraries.count > 1 {
                    libraryFilterLink
                }
            }

        case "returning_shows":
            Section {
                Stepper(value: $lookbackDays, in: 7...180, step: 7) {
                    LabeledContent {
                        Text(.homeAddRowLookBackDays(lookbackDays))
                    } label: {
                        Text(.homeAddRowLookBack)
                    }
                }
            } header: {
                Text(.playerTracksTiming)
            } footer: {
                Text(.homeAddRowLookBackFooter)
            }

        case "short_watches":
            Section {
                Stepper(value: $maxMinutes, in: 30...180, step: 5) {
                    LabeledContent {
                        Text(.homeAddRowMaxRuntimeMinutes(LocaleFormat.integer(maxMinutes)))
                    } label: {
                        Text(.homeAddRowMaxRuntime)
                    }
                }
            } header: {
                Text(.detailFactsLength)
            }

        case "anniversaries":
            Section {
                Stepper(value: $milestoneYears, in: 1...25, step: 1) {
                    LabeledContent {
                        Text(.homeAddRowMilestoneInterval(count: milestoneYears))
                    } label: {
                        Text(.homeAddRowMilestone)
                    }
                }
            } header: {
                Text(.homeAddRowSectionSchedule)
            }

        case "taste_match":
            Section {
                HStack {
                    TextField(AppLanguage.string(.homeAddRowAnyGenrePlaceholder), text: $genreFilter)
                    if !genreFilter.isEmpty {
                        Button {
                            genreFilter = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.siloSecondaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text(.homeAddRowSectionGenreFilter)
            } footer: {
                Text(.homeAddRowGenreFilterFooter)
            }

        case "editorial_spotlight":
            if !isSpotlightEraPreset {
                Section(.homeAddRowSectionSpotlight) {
                    Toggle(.homeAddRowRotateAutomatically, isOn: $autoRotate)
                        .tint(Color.siloSwitchOn)

                    if autoRotate {
                        Picker(.homeAddRowHowOften, selection: $rotationCadence) {
                            Text(.homeAddRowCadenceDaily).tag("daily")
                            Text(.homeAddRowCadenceWeekly).tag("weekly")
                            Text(.homeAddRowCadenceMonthly).tag("monthly")
                        }
                    } else {
                        TextField(spotlightPlaceholder, text: $pinnedSubject)
                    }
                }
            }

        case "seasonal_themed":
            if isSeasonalHolidaysPreset {
                Section {
                    NavigationLink {
                        IOSSeasonalThemesPickerView(selectedKeys: $enabledSeasonalThemes)
                    } label: {
                        LabeledContent {
                            Text(verbatim: seasonalSummaryText)
                                .foregroundStyle(Color.siloSecondaryText)
                        } label: {
                            Text(.homeAddRowHolidays)
                        }
                    }
                } header: {
                    Text(.homeAddRowHolidays)
                } footer: {
                    Text(.homeAddRowHolidaysFooter)
                }
            }

        default:
            EmptyView()
        }
    }

    private var spotlightPlaceholder: String {
        switch selectedPresetKey {
        case "es_actor": AppLanguage.string(.homeAddRowActorNamePlaceholder)
        case "es_studio": AppLanguage.string(.homeAddRowStudioNamePlaceholder)
        default: AppLanguage.string(.homeAddRowDirectorNamePlaceholder)
        }
    }

    private var seasonalSummaryText: String {
        if enabledSeasonalThemes.count == AddRowCatalog.holidayThemes.count {
            return AppLanguage.string(.homeAddRowHolidaysAllCount(LocaleFormat.integer(enabledSeasonalThemes.count)))
        }
        if enabledSeasonalThemes.isEmpty {
            return AppLanguage.string(.accountDownloadsNone)
        }
        return "\(LocaleFormat.integer(enabledSeasonalThemes.count)) \(AppLanguage.string(.playerMenuSelected).lowercased())"
    }

    private var libraryFilterLink: some View {
        NavigationLink {
            IOSLibraryFilterPickerView(
                libraries: editor.availableLibraries,
                selectedIds: $selectedLibraryIds
            )
        } label: {
            LabeledContent {
                Text(verbatim: libraryFilterSummary)
                    .foregroundStyle(Color.siloSecondaryText)
                    .lineLimit(1)
            } label: {
                Text(.homeAddRowFromLibraries)
            }
        }
    }

    private var libraryFilterSummary: String {
        if selectedLibraryIds.isEmpty { return AppLanguage.string(.homeAddRowAllLibraries) }
        let names = editor.availableLibraries
            .filter { selectedLibraryIds.contains($0.id) }
            .map(\.name)
        if names.count <= 2 { return names.joined(separator: ", ") }
        return "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)"
    }

    // MARK: - Row Name & Display Options

    private var rowNameSection: some View {
        Section {
            HStack {
                TextField(defaultRowName, text: $rowName)
                    .onChange(of: rowName) { _, newValue in
                        if newValue != defaultRowName {
                            titleFollowsVariant = false
                        }
                        if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            titleFollowsVariant = true
                        }
                    }
                if !rowName.isEmpty {
                    Button {
                        rowName = ""
                        titleFollowsVariant = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.siloSecondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(.homeAddRowA11YClearRowName)
                }
            }
        } header: {
            Text(.homeAddRowRowName)
        } footer: {
            if entry.definition.presets.count > 1 && titleFollowsVariant {
                Text(.homeAddRowRowNameFooter)
            }
        }
    }

    private var displayOptionsSection: some View {
        Section {
            Stepper(value: $itemLimit, in: 5...50, step: 5) {
                LabeledContent {
                    Text(verbatim: LocaleFormat.integer(itemLimit))
                } label: {
                    Text(.homeAddRowItemsToShow)
                }
            }

            if editor.scope == .home {
                Toggle(.homeAddRowHeroBanner, isOn: $isHeroBanner)
                    .tint(Color.siloSwitchOn)
            }
        } header: {
            Text(.homeAddRowSectionDisplay)
        } footer: {
            if editor.scope == .home {
                Text(.homeAddRowHeroBannerRecipeFooter(pageLabel))
            }
        }
    }
}

// MARK: - Choose a Collection (Step 2B)

private struct IOSCollectionPickerView: View {
    @Bindable var editor: HomeSectionsEditorModel
    let pageLabel: String
    let onFinished: () -> Void

    @State private var searchText = ""
    @Environment(\.locale) private var locale

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredPersonal: [UserCollection] {
        guard !trimmedQuery.isEmpty else { return editor.personalCollections }
        return editor.personalCollections.filter {
            $0.name.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var filteredServer: [HomeSectionsEditorModel.ServerCollectionOption] {
        guard !trimmedQuery.isEmpty else { return editor.serverCollections }
        return editor.serverCollections.filter {
            $0.title.localizedCaseInsensitiveContains(trimmedQuery)
                || $0.libraryName.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    var body: some View {
        List {
            if editor.isLoadingPickerCatalog
                && editor.personalCollections.isEmpty
                && editor.serverCollections.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 24)
                .listRowBackground(Color.clear)
            } else if filteredPersonal.isEmpty && filteredServer.isEmpty {
                let loadError = editor.personalCollectionsError ?? editor.serverCollectionsError
                if let loadError, editor.personalCollections.isEmpty && editor.serverCollections.isEmpty {
                    ContentUnavailableView {
                        Label(.homeAddRowLoadCollectionsFailed, systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(verbatim: loadError)
                    } actions: {
                        Button(.commonRetry) {
                            Task { await editor.loadPickerCatalogIfNeeded(force: true) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else if !trimmedQuery.isEmpty {
                    ContentUnavailableView.search(text: trimmedQuery)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ContentUnavailableView(
                        .homeAddRowNoCollectionsTitle,
                        systemImage: "square.stack",
                        description: Text(.homeAddRowNoCollectionsBody)
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } else {
                if let error = editor.personalCollectionsError ?? editor.serverCollectionsError {
                    Section {
                        HStack(spacing: 10) {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(Color.siloSecondaryText)
                            Spacer()
                            Button(.commonRetry) {
                                Task { await editor.loadPickerCatalogIfNeeded(force: true) }
                            }
                            .font(.footnote.weight(.semibold))
                        }
                    }
                }
                if !filteredPersonal.isEmpty {
                    Section(.homeAddRowSectionYourCollections) {
                        ForEach(filteredPersonal) { collection in
                            NavigationLink {
                                IOSConfigureCollectionRowView(
                                    editor: editor,
                                    collection: .personal(collection),
                                    pageLabel: pageLabel,
                                    onFinished: onFinished
                                )
                            } label: {
                                CollectionListRowLabel(
                                    title: collection.name,
                                    subtitle: itemCountLabel(collection.itemCount, locale: locale),
                                    posterUrl: collection.posterUrl,
                                    posterThumbhash: collection.posterThumbhash,
                                    badge: editor.isCollectionPresent(collectionId: collection.id, isUserCollection: true)
                                        ? AppLanguage.string(.homeAddRowOnPageBadge(pageLabel), locale: locale)
                                        : nil
                                )
                            }
                        }
                    }
                }

                if !filteredServer.isEmpty {
                    Section(.homeAddRowSectionServerCollections) {
                        ForEach(filteredServer) { collection in
                            NavigationLink {
                                IOSConfigureCollectionRowView(
                                    editor: editor,
                                    collection: .server(collection),
                                    pageLabel: pageLabel,
                                    onFinished: onFinished
                                )
                            } label: {
                                CollectionListRowLabel(
                                    title: collection.title,
                                    subtitle: serverCollectionSubtitle(collection, locale: locale),
                                    posterUrl: collection.posterUrl,
                                    posterThumbhash: collection.posterThumbhash,
                                    badge: editor.isCollectionPresent(collectionId: collection.id, isUserCollection: false)
                                        ? AppLanguage.string(.homeAddRowOnPageBadge(pageLabel), locale: locale)
                                        : nil
                                )
                            }
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .settingsListChrome()
        #else
        .siloGroupedListStyle()
        #endif
        .scrollDismissesKeyboard(.interactively)
        #if os(iOS)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(.homeAddRowSearchCollectionsPrompt)
        )
        #else
        .searchable(text: $searchText, prompt: Text(.homeAddRowSearchCollectionsPrompt))
        #endif
        .navigationTitle(Text(.homeAddRowACollectionTitle))
        .siloNavigationTitleDisplayMode(.inline)
    }
}

// MARK: - Configure Single Collection Row (Step 3B)

private enum PickedCollectionTarget {
    case personal(UserCollection)
    case server(HomeSectionsEditorModel.ServerCollectionOption)

    var id: String {
        switch self {
        case .personal(let c): return c.id
        case .server(let c): return c.id
        }
    }

    var isUserCollection: Bool {
        if case .personal = self { return true }
        return false
    }

    var defaultTitle: String {
        switch self {
        case .personal(let c): return c.name
        case .server(let c): return c.title
        }
    }

    var subtitle: String {
        switch self {
        case .personal(let c):
            if let count = itemCountLabel(c.itemCount) {
                return AppLanguage.string(.homeAddRowPersonalWithCount(count))
            }
            return AppLanguage.string(.homeAddRowPersonalCollection)
        case .server(let c):
            return serverCollectionSubtitle(c)
        }
    }

    var posterUrl: String? {
        switch self {
        case .personal(let c): return c.posterUrl
        case .server(let c): return c.posterUrl
        }
    }

    var posterThumbhash: String? {
        switch self {
        case .personal(let c): return c.posterThumbhash
        case .server(let c): return c.posterThumbhash
        }
    }
}

private struct IOSConfigureCollectionRowView: View {
    @Bindable var editor: HomeSectionsEditorModel
    let collection: PickedCollectionTarget
    let pageLabel: String
    let onFinished: () -> Void

    @State private var rowName: String
    @State private var itemLimit: Int = 20
    @State private var isHeroBanner = false
    @State private var confirmHaptic = 0

    init(
        editor: HomeSectionsEditorModel,
        collection: PickedCollectionTarget,
        pageLabel: String,
        onFinished: @escaping () -> Void
    ) {
        self.editor = editor
        self.collection = collection
        self.pageLabel = pageLabel
        self.onFinished = onFinished
        _rowName = State(initialValue: collection.defaultTitle)
    }

    private var effectiveTitle: String {
        let trimmed = rowName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? collection.defaultTitle : trimmed
    }

    private var isAlreadyPinned: Bool {
        editor.isCollectionPresent(
            collectionId: collection.id,
            isUserCollection: collection.isUserCollection
        )
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    CollectionMiniPoster(
                        url: collection.posterUrl,
                        thumbhash: collection.posterThumbhash,
                        width: 44,
                        height: 66
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(effectiveTitle)
                            .font(.headline)
                            .foregroundStyle(Color.siloOnSurface)
                            .lineLimit(2)
                        Text(collection.subtitle)
                            .font(.footnote)
                            .foregroundStyle(Color.siloSecondaryText)
                    }
                }
                .padding(.vertical, 4)

                if isAlreadyPinned {
                    Label(.homeAddRowAlreadyPinnedNote(pageLabel), systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(Color.siloSecondaryText)
                }
            }

            Section(.homeAddRowRowName) {
                HStack {
                    TextField(collection.defaultTitle, text: $rowName)
                    if !rowName.isEmpty {
                        Button {
                            rowName = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.siloSecondaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section {
                Stepper(value: $itemLimit, in: 5...50, step: 5) {
                    LabeledContent {
                        Text(verbatim: LocaleFormat.integer(itemLimit))
                    } label: {
                        Text(.homeAddRowItemsToShow)
                    }
                }

                if editor.scope == .home {
                    Toggle(.homeAddRowHeroBanner, isOn: $isHeroBanner)
                        .tint(Color.siloSwitchOn)
                }
            } header: {
                Text(.homeAddRowSectionDisplay)
            } footer: {
                if editor.scope == .home {
                    Text(.homeAddRowHeroBannerCollectionFooter(pageLabel))
                }
            }
        }
        #if os(macOS)
        .settingsListChrome()
        #else
        .siloGroupedListStyle()
        #endif
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(Text(.homeAddRowCollectionRowTitle))
        .siloNavigationTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(.profilesAdd) {
                    confirmHaptic += 1
                    editor.addCollectionRow(
                        collectionId: collection.id,
                        title: effectiveTitle,
                        isUserCollection: collection.isUserCollection,
                        itemLimit: itemLimit,
                        featured: editor.scope == .home ? isHeroBanner : false
                    )
                    onFinished()
                }
                .fontWeight(.semibold)
            }
        }
        #if os(iOS)
        .sensoryFeedback(.success, trigger: confirmHaptic)
        #endif
    }
}

// MARK: - Row of Collections Builder (Step 2C)

private struct IOSCollectionPostersBuilderView: View {
    @Bindable var editor: HomeSectionsEditorModel
    let pageLabel: String
    let onFinished: () -> Void

    private struct SelectedRef: Identifiable, Hashable {
        let isUserCollection: Bool
        let collectionId: String
        var id: String { "\(isUserCollection ? "user" : "lib"):\(collectionId)" }
    }

    private let maxCollections = 30

    @State private var rowName = AppLanguage.string(.collectionsTitle)
    @State private var selectedRefs: [SelectedRef] = []
    @State private var searchText = ""
    @Environment(\.locale) private var locale
    @State private var selectionHaptic = 0
    @State private var confirmHaptic = 0

    private var selectedSet: Set<SelectedRef> { Set(selectedRefs) }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredPersonal: [UserCollection] {
        guard !trimmedQuery.isEmpty else { return editor.personalCollections }
        return editor.personalCollections.filter {
            $0.name.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var filteredServer: [HomeSectionsEditorModel.ServerCollectionOption] {
        guard !trimmedQuery.isEmpty else { return editor.serverCollections }
        return editor.serverCollections.filter {
            $0.title.localizedCaseInsensitiveContains(trimmedQuery)
                || $0.libraryName.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    var body: some View {
        List {
            if trimmedQuery.isEmpty {
                Section(.homeAddRowRowName) {
                    HStack {
                        TextField(AppLanguage.string(.collectionsTitle, locale: locale), text: $rowName)
                        if !rowName.isEmpty {
                            Button {
                                rowName = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color.siloSecondaryText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !selectedRefs.isEmpty {
                    Section {
                        ForEach(selectedRefs) { ref in
                            selectedRow(for: ref)
                        }
                        .onDelete { offsets in
                            selectedRefs.remove(atOffsets: offsets)
                        }
                    } header: {
                        HStack {
                            Text(.playerMenuSelected)
                            Spacer()
                            Text(.homeAddRowSelectedCountOfMax(
                                LocaleFormat.integer(selectedRefs.count, locale: locale),
                                LocaleFormat.integer(maxCollections, locale: locale)
                            ))
                                .font(.caption)
                                .foregroundStyle(Color.siloSecondaryText)
                        }
                    } footer: {
                        Text(.homeAddRowSelectedReorderFooter)
                    }
                }
            }

            if editor.isLoadingPickerCatalog
                && editor.personalCollections.isEmpty
                && editor.serverCollections.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 24)
                .listRowBackground(Color.clear)
            } else if filteredPersonal.isEmpty && filteredServer.isEmpty {
                let loadError = editor.personalCollectionsError ?? editor.serverCollectionsError
                if let loadError, editor.personalCollections.isEmpty && editor.serverCollections.isEmpty {
                    ContentUnavailableView {
                        Label(.homeAddRowLoadCollectionsFailed, systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(verbatim: loadError)
                    } actions: {
                        Button(.commonRetry) {
                            Task { await editor.loadPickerCatalogIfNeeded(force: true) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else if !trimmedQuery.isEmpty {
                    ContentUnavailableView.search(text: trimmedQuery)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ContentUnavailableView(
                        .homeAddRowNoCollectionsTitle,
                        systemImage: "square.grid.2x2",
                        description: Text(.homeAddRowNoCollectionsPostersBody)
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } else {
                if let error = editor.personalCollectionsError ?? editor.serverCollectionsError {
                    Section {
                        HStack(spacing: 10) {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(Color.siloSecondaryText)
                            Spacer()
                            Button(.commonRetry) {
                                Task { await editor.loadPickerCatalogIfNeeded(force: true) }
                            }
                            .font(.footnote.weight(.semibold))
                        }
                    }
                }
                if !filteredPersonal.isEmpty {
                    Section(.homeAddRowSectionYourCollections) {
                        ForEach(filteredPersonal) { collection in
                            let ref = SelectedRef(isUserCollection: true, collectionId: collection.id)
                            let isChosen = selectedSet.contains(ref)
                            selectableCollectionButton(
                                title: collection.name,
                                subtitle: itemCountLabel(collection.itemCount, locale: locale),
                                posterUrl: collection.posterUrl,
                                posterThumbhash: collection.posterThumbhash,
                                isChosen: isChosen,
                                isDisabled: !isChosen && selectedRefs.count >= maxCollections
                            ) {
                                toggle(ref)
                            }
                        }
                    }
                }

                if !filteredServer.isEmpty {
                    Section(.homeAddRowSectionServerCollections) {
                        ForEach(filteredServer) { collection in
                            let ref = SelectedRef(isUserCollection: false, collectionId: collection.id)
                            let isChosen = selectedSet.contains(ref)
                            selectableCollectionButton(
                                title: collection.title,
                                subtitle: serverCollectionSubtitle(collection, locale: locale),
                                posterUrl: collection.posterUrl,
                                posterThumbhash: collection.posterThumbhash,
                                isChosen: isChosen,
                                isDisabled: !isChosen && selectedRefs.count >= maxCollections
                            ) {
                                toggle(ref)
                            }
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .settingsListChrome()
        #else
        .siloGroupedListStyle()
        #endif
        .scrollDismissesKeyboard(.interactively)
        #if os(iOS)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(.homeAddRowSearchCollectionsPrompt)
        )
        #else
        .searchable(text: $searchText, prompt: Text(.homeAddRowSearchCollectionsPrompt))
        #endif
        .navigationTitle(Text(.homeAddRowRowOfCollectionsTitle))
        .siloNavigationTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(.profilesAdd) {
                    confirmHaptic += 1
                    editor.addCollectionPostersRow(
                        title: rowName,
                        refs: selectedRefs.map { ($0.isUserCollection, $0.collectionId) }
                    )
                    onFinished()
                }
                .fontWeight(.semibold)
                .disabled(selectedRefs.isEmpty)
            }
        }
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: selectionHaptic)
        .sensoryFeedback(.success, trigger: confirmHaptic)
        #endif
    }

    private func toggle(_ ref: SelectedRef) {
        selectionHaptic += 1
        withAnimation(.easeInOut(duration: 0.18)) {
            if let idx = selectedRefs.firstIndex(of: ref) {
                selectedRefs.remove(at: idx)
            } else if selectedRefs.count < maxCollections {
                selectedRefs.append(ref)
            }
        }
    }

    @ViewBuilder
    private func selectedRow(for ref: SelectedRef) -> some View {
        let index = selectedRefs.firstIndex(of: ref) ?? 0
        let info = resolveRefInfo(ref)
        HStack(spacing: 12) {
            CollectionMiniPoster(
                url: info.posterUrl,
                thumbhash: info.posterThumbhash,
                width: 28,
                height: 42
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                    .font(.body)
                    .foregroundStyle(Color.siloOnSurface)
                    .lineLimit(1)
                if let subtitle = info.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.siloSecondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if selectedRefs.count > 1 {
                HStack(spacing: 4) {
                    Button {
                        guard index > 0 else { return }
                        selectionHaptic += 1
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedRefs.swapAt(index, index - 1)
                        }
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.caption.weight(.semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(index > 0 ? Color.siloOnSurface : Color.siloSecondaryText.opacity(0.35))
                    .disabled(index == 0)

                    Button {
                        guard index < selectedRefs.count - 1 else { return }
                        selectionHaptic += 1
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedRefs.swapAt(index, index + 1)
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(index < selectedRefs.count - 1 ? Color.siloOnSurface : Color.siloSecondaryText.opacity(0.35))
                    .disabled(index >= selectedRefs.count - 1)
                }
            }
        }
    }

    private func resolveRefInfo(_ ref: SelectedRef) -> (title: String, subtitle: String?, posterUrl: String?, posterThumbhash: String?) {
        if ref.isUserCollection,
           let col = editor.personalCollections.first(where: { $0.id == ref.collectionId }) {
            return (col.name, AppLanguage.string(.homeAddRowPersonalCollection, locale: locale), col.posterUrl, col.posterThumbhash)
        }
        if !ref.isUserCollection,
           let col = editor.serverCollections.first(where: { $0.id == ref.collectionId }) {
            return (col.title, col.libraryName, col.posterUrl, col.posterThumbhash)
        }
        return (AppLanguage.string(.collectionsCollection, locale: locale), nil, nil, nil)
    }

    private func selectableCollectionButton(
        title: String,
        subtitle: String?,
        posterUrl: String?,
        posterThumbhash: String?,
        isChosen: Bool,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                CollectionMiniPoster(
                    url: posterUrl,
                    thumbhash: posterThumbhash,
                    width: 32,
                    height: 48
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(Color.siloOnSurface)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Color.siloSecondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isChosen ? Color.siloPrimary : Color.siloSecondaryText.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
    }
}

// MARK: - Native Sub-Pickers (Libraries & Holidays)

private struct IOSLibraryFilterPickerView: View {
    let libraries: [Library]
    @Binding var selectedIds: Set<Int>
    @State private var hapticCount = 0

    var body: some View {
        List {
            Section {
                Button {
                    hapticCount += 1
                    selectedIds.removeAll()
                } label: {
                    HStack {
                        Text(.homeAddRowAllLibraries)
                            .foregroundStyle(Color.siloOnSurface)
                        Spacer()
                        if selectedIds.isEmpty {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.siloPrimary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Section(.homeAddRowSpecificLibraries) {
                ForEach(libraries) { library in
                    let isSelected = selectedIds.contains(library.id)
                    Button {
                        hapticCount += 1
                        if isSelected {
                            selectedIds.remove(library.id)
                        } else {
                            selectedIds.insert(library.id)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: symbol(for: library))
                                .foregroundStyle(Color.siloSecondaryText)
                                .frame(width: 22)
                            Text(verbatim: library.name)
                                .foregroundStyle(Color.siloOnSurface)
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.siloPrimary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        #if os(macOS)
        .settingsListChrome()
        #else
        .siloGroupedListStyle()
        #endif
        .navigationTitle(Text(.libraryLibraries))
        .siloNavigationTitleDisplayMode(.inline)
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: hapticCount)
        #endif
    }

    private func symbol(for library: Library) -> String {
        if library.isAudiobookLibrary { return "book.closed.fill" }
        if library.isSeriesLibrary { return "tv.fill" }
        return "film.stack.fill"
    }
}

private struct IOSSeasonalThemesPickerView: View {
    @Binding var selectedKeys: Set<String>
    @State private var hapticCount = 0

    var body: some View {
        List {
            Section {
                ForEach(AddRowCatalog.holidayThemes, id: \.key) { theme in
                    let isSelected = selectedKeys.contains(theme.key)
                    Button {
                        hapticCount += 1
                        if isSelected {
                            selectedKeys.remove(theme.key)
                        } else {
                            selectedKeys.insert(theme.key)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: theme.symbol)
                                .foregroundStyle(Color.siloSecondaryText)
                                .frame(width: 22)
                            Text(theme.title)
                                .foregroundStyle(Color.siloOnSurface)
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.siloPrimary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text(.homeAddRowHolidaysPickerFooter)
            }
        }
        #if os(macOS)
        .settingsListChrome()
        #else
        .siloGroupedListStyle()
        #endif
        .navigationTitle(Text(.homeAddRowHolidays))
        .siloNavigationTitleDisplayMode(.inline)
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: hapticCount)
        #endif
    }
}

// MARK: - Shared Native Row Cells

private struct AddRowCatalogCell: View {
    let symbol: String
    let title: String
    let subtitle: String
    let trailingValue: String?

    var body: some View {
        HStack(spacing: 13) {
            AddRowIconTile(symbol: symbol, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Color.siloOnSurface)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Color.siloSecondaryText)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            if let trailingValue {
                Text(trailingValue)
                    .font(.footnote)
                    .foregroundStyle(Color.siloSecondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AddRowIconTile: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Color.siloIconTile,
                in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

private struct CollectionListRowLabel: View {
    let title: String
    let subtitle: String?
    let posterUrl: String?
    let posterThumbhash: String?
    let badge: String?

    var body: some View {
        HStack(spacing: 12) {
            CollectionMiniPoster(
                url: posterUrl,
                thumbhash: posterThumbhash,
                width: 34,
                height: 50
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Color.siloOnSurface)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Color.siloSecondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let badge {
                Text(badge)
                    .font(.footnote)
                    .foregroundStyle(Color.siloSecondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct CollectionMiniPoster: View {
    let url: String?
    let thumbhash: String?
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        if let url, !url.isEmpty {
            AsyncImageView(
                url: url,
                thumbhash: thumbhash,
                targetSize: CGSize(width: width, height: height),
                contentMode: .fill,
                placeholderStyle: .artwork
            )
            .frame(width: width, height: height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.siloIconTile)
                Image(systemName: "square.stack.fill")
                    .font(.system(size: width * 0.42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(width: width, height: height)
        }
    }
}

private func itemCountLabel(_ count: Int?, locale: Locale? = nil) -> String? {
    guard let count, count > 0 else { return nil }
    let formatted = locale.map { LocaleFormat.groupedCount(count, locale: $0) } ?? LocaleFormat.groupedCount(count)
    if let locale {
        return AppLanguage.string(.collectionsItemCount(count: count, formatted), locale: locale)
    }
    return AppLanguage.string(.collectionsItemCount(count: count, formatted))
}

private func serverCollectionSubtitle(_ collection: HomeSectionsEditorModel.ServerCollectionOption, locale: Locale? = nil) -> String {
    if let items = itemCountLabel(collection.itemCount, locale: locale) {
        return "\(collection.libraryName) · \(items)"
    }
    return collection.libraryName
}

// MARK: - Curated Catalog Presentation & Grouping

private struct AddRowGroup: Identifiable {
    let id: String
    let title: String
    let entries: [AddRowEntry]
}

private struct AddRowEntry: Identifiable {
    let definition: APIv2RecipeDefinition
    let title: String
    let subtitle: String
    let symbol: String

    var id: String { definition.type }
}

private struct AddRowSearchHit: Identifiable {
    let entry: AddRowEntry
    let matchedPresetKey: String?
    let matchedPresetTitle: String?
    let matchedSubtitle: String

    var id: String { "\(entry.id):\(matchedPresetKey ?? "")" }
}

private enum AddRowCatalog {
    struct KindMeta {
        let groupId: String
        let order: Int
        let titleResource: LocalizedStringResource
        let subtitleResource: LocalizedStringResource

        var title: String { AppLanguage.string(titleResource) }
        var subtitle: String { AppLanguage.string(subtitleResource) }
    }

    struct HolidayTheme {
        let key: String
        let titleResource: LocalizedStringResource
        let symbol: String

        var title: String { AppLanguage.string(titleResource) }
    }

    static let holidayThemes: [HolidayTheme] = [
        HolidayTheme(key: "halloween", titleResource: .homeAddRowHolidayHalloween, symbol: "moon.stars.fill"),
        HolidayTheme(key: "christmas", titleResource: .homeAddRowHolidayChristmas, symbol: "snowflake"),
        HolidayTheme(key: "new_year", titleResource: .homeAddRowHolidayNewYear, symbol: "sparkles"),
        HolidayTheme(key: "valentines", titleResource: .homeAddRowHolidayValentines, symbol: "heart.fill"),
        HolidayTheme(key: "st_patricks", titleResource: .homeAddRowHolidayStPatricks, symbol: "leaf.fill"),
        HolidayTheme(key: "easter", titleResource: .homeAddRowHolidayEaster, symbol: "sun.max.fill"),
        HolidayTheme(key: "thanksgiving", titleResource: .homeAddRowHolidayThanksgiving, symbol: "fork.knife"),
        HolidayTheme(key: "summer_blockbuster", titleResource: .homeSectionSeasonalSummerBlockbusters, symbol: "sun.horizon.fill"),
        HolidayTheme(key: "saturday_morning", titleResource: .homeAddRowHolidaySaturdayMorning, symbol: "tv.fill"),
    ]

    static let defaultHolidayThemeKeys: [String] = holidayThemes.map(\.key)

    private static let excludedTypes: Set<String> = [
        "admin_curated_list",
        "collection",
        "collection_posters",
        "custom_filter",
        "genre",
        "award_winners",
        "next_up",
    ]

    private static let groupOrder: [(id: String, titleResource: LocalizedStringResource)] = [
        ("keep", .homeAddRowGroupKeepWatching),
        ("new", .homeAddRowGroupWhatsNew),
        ("popular", .homeAddRowGroupPopular),
        ("picked", .homeAddRowGroupForYou),
        ("moods", .homeAddRowGroupMoodsDiscovery),
        ("other", .homeAddRowGroupMore),
    ]

    private static let kindMeta: [String: KindMeta] = [
        // Keep Watching
        "continue_watching": KindMeta(
            groupId: "keep", order: 0,
            titleResource: .homeSectionContinueWatching,
            subtitleResource: .homeAddRowSubContinueWatching
        ),
        "next_in_series": KindMeta(
            groupId: "keep", order: 1,
            titleResource: .homeRecipeNextInSeriesDefaultName,
            subtitleResource: .homeAddRowSubNextInSeries
        ),
        "watchlist": KindMeta(
            groupId: "keep", order: 2,
            titleResource: .detailWatchlist,
            subtitleResource: .homeAddRowSubWatchlist
        ),
        "favorites": KindMeta(
            groupId: "keep", order: 3,
            titleResource: .homeRecipeFavoritesDefaultName,
            subtitleResource: .homeAddRowSubFavorites
        ),

        // What's New
        "recently_added": KindMeta(
            groupId: "new", order: 0,
            titleResource: .homeSectionRecentlyAdded,
            subtitleResource: .homeAddRowSubRecentlyAdded
        ),
        "recently_released": KindMeta(
            groupId: "new", order: 1,
            titleResource: .homeRecipeRecentlyReleasedDefaultName,
            subtitleResource: .homeAddRowSubNewReleases
        ),
        "new_to_library": KindMeta(
            groupId: "new", order: 2,
            titleResource: .homeAddRowRecipeNewThisMonth,
            subtitleResource: .homeAddRowSubNewThisMonth
        ),
        "returning_shows": KindMeta(
            groupId: "new", order: 3,
            titleResource: .homeSectionReturningShows,
            subtitleResource: .homeAddRowSubReturningShows
        ),

        // Popular
        "trending_on_server": KindMeta(
            groupId: "popular", order: 0,
            titleResource: .homeSectionTrendingOnServer,
            subtitleResource: .homeAddRowSubTrendingOnServer
        ),
        "most_watched": KindMeta(
            groupId: "popular", order: 1,
            titleResource: .homeAddRowRecipeMostWatched,
            subtitleResource: .homeAddRowSubMostWatched
        ),
        "trending_discover": KindMeta(
            groupId: "popular", order: 2,
            titleResource: .homeAddRowRecipeTrendingWorldwide,
            subtitleResource: .homeAddRowSubTrendingWorldwide
        ),
        "profile_activity_feed": KindMeta(
            groupId: "popular", order: 3,
            titleResource: .homeRecipePaHouseholdName,
            subtitleResource: .homeAddRowSubWhatOthersWatched
        ),

        // For You
        "recommended_for_you": KindMeta(
            groupId: "picked", order: 0,
            titleResource: .homeSectionRecommendedForYou,
            subtitleResource: .homeAddRowSubRecommendedForYou
        ),
        "because_you_watched": KindMeta(
            groupId: "picked", order: 1,
            titleResource: .homeSectionBecauseYouWatched,
            subtitleResource: .homeAddRowSubBecauseYouWatched
        ),
        "similar_users_liked": KindMeta(
            groupId: "picked", order: 2,
            titleResource: .homeSectionProfilesLikeYouEnjoyed,
            subtitleResource: .homeAddRowSubProfilesLikeYou
        ),
        "taste_match": KindMeta(
            groupId: "picked", order: 3,
            titleResource: .homeSectionTopPicksToday,
            subtitleResource: .homeAddRowSubTopPicksToday
        ),

        // Moods & Discovery
        "mood_collection": KindMeta(
            groupId: "moods", order: 0,
            titleResource: .homeAddRowRecipeMoodPicks,
            subtitleResource: .homeAddRowSubMoodPicks
        ),
        "seasonal_themed": KindMeta(
            groupId: "moods", order: 1,
            titleResource: .homeSectionSeasonalPicks,
            subtitleResource: .homeAddRowSubSeasonalPicks
        ),
        "editorial_spotlight": KindMeta(
            groupId: "moods", order: 2,
            titleResource: .homeAddRowRecipeSpotlight,
            subtitleResource: .homeAddRowSubSpotlight
        ),
        "format_showcase": KindMeta(
            groupId: "moods", order: 3,
            titleResource: .homeAddRowRecipeFormatShowcase,
            subtitleResource: .homeAddRowSubFormatShowcase
        ),
        "hidden_gems": KindMeta(
            groupId: "moods", order: 4,
            titleResource: .homeSectionHiddenGems,
            subtitleResource: .homeAddRowSubHiddenGems
        ),
        "critically_acclaimed": KindMeta(
            groupId: "moods", order: 5,
            titleResource: .homeRecipeCaImdbName,
            subtitleResource: .homeAddRowSubCriticallyAcclaimed
        ),
        "forgotten_favorites": KindMeta(
            groupId: "moods", order: 6,
            titleResource: .homeRecipeFfDefaultName,
            subtitleResource: .homeAddRowSubForgottenFavorites
        ),
        "genre_roulette": KindMeta(
            groupId: "moods", order: 7,
            titleResource: .homeRecipeGenreRouletteWeeklyName,
            subtitleResource: .homeAddRowSubGenreRoulette
        ),
        "random": KindMeta(
            groupId: "moods", order: 8,
            titleResource: .homeRecipeRandomDefaultName,
            subtitleResource: .homeAddRowSubSurpriseMe
        ),
        "short_watches": KindMeta(
            groupId: "moods", order: 9,
            titleResource: .homeRecipeShortWatchesDefaultName,
            subtitleResource: .homeAddRowSubShortAndSweet
        ),
        "anniversaries": KindMeta(
            groupId: "moods", order: 10,
            titleResource: .homeRecipeAnniversariesDefaultName,
            subtitleResource: .homeAddRowSubAnniversaries
        ),
    ]

    static func groups(from catalog: APIv2RecipeCatalog, locale: Locale = .current) -> [AddRowGroup] {
        let definitions = catalog.categories
            .flatMap(\.recipes)
            .filter { def in
                let type = def.type.lowercased()
                return !def.adminOnly && !excludedTypes.contains(type) && !def.presets.isEmpty
            }

        var bucket: [String: [(order: Int, entry: AddRowEntry)]] = [:]
        var seenTypes = Set<String>()

        for def in definitions {
            let typeKey = def.type.lowercased()
            guard seenTypes.insert(typeKey).inserted else { continue }

            let meta = kindMeta[typeKey]
            let groupId = meta?.groupId ?? "other"
            let order = meta?.order ?? 999
            let title = meta.map { AppLanguage.string($0.titleResource, locale: locale) }
                ?? def.presets.first?.displayName
                ?? typeKey.replacingOccurrences(of: "_", with: " ").capitalized
            let subtitle = meta.map { AppLanguage.string($0.subtitleResource, locale: locale) }
                ?? def.presets.first?.descriptionShort
                ?? ""

            let entry = AddRowEntry(
                definition: def,
                title: title,
                subtitle: subtitle,
                symbol: SectionRecipePresentation.symbol(for: def.type)
            )
            bucket[groupId, default: []].append((order, entry))
        }

        return groupOrder.compactMap { group in
            guard let items = bucket[group.id], !items.isEmpty else { return nil }
            let sorted = items.sorted {
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.entry.title.localizedCaseInsensitiveCompare($1.entry.title) == .orderedAscending
            }.map(\.entry)
            return AddRowGroup(
                id: group.id,
                title: AppLanguage.string(group.titleResource, locale: locale),
                entries: sorted
            )
        }
    }

    static func search(groups: [AddRowGroup], query: String) -> [AddRowSearchHit] {
        var hits: [AddRowSearchHit] = []
        for group in groups {
            for entry in group.entries {
                if entry.title.localizedCaseInsensitiveContains(query)
                    || group.title.localizedCaseInsensitiveContains(query) {
                    hits.append(AddRowSearchHit(
                        entry: entry,
                        matchedPresetKey: nil,
                        matchedPresetTitle: nil,
                        matchedSubtitle: entry.subtitle
                    ))
                    continue
                }
                let matchingPresets = entry.definition.presets.filter {
                    $0.displayName.localizedCaseInsensitiveContains(query)
                        || $0.descriptionShort.localizedCaseInsensitiveContains(query)
                }
                if !matchingPresets.isEmpty {
                    for preset in matchingPresets {
                        hits.append(AddRowSearchHit(
                            entry: entry,
                            matchedPresetKey: preset.key,
                            matchedPresetTitle: entry.definition.presets.count > 1 ? preset.displayName : nil,
                            matchedSubtitle: preset.descriptionShort.isEmpty ? entry.subtitle : preset.descriptionShort
                        ))
                    }
                    continue
                }
                if entry.subtitle.localizedCaseInsensitiveContains(query) {
                    hits.append(AddRowSearchHit(
                        entry: entry,
                        matchedPresetKey: nil,
                        matchedPresetTitle: nil,
                        matchedSubtitle: entry.subtitle
                    ))
                }
            }
        }
        return hits
    }

    static func variantSectionTitle(for sectionType: String) -> String {
        switch sectionType.lowercased() {
        case "continue_watching": AppLanguage.string(.homeAddRowControlKind)
        case "trending_on_server": AppLanguage.string(.homeAddRowControlTimeWindow)
        case "most_watched", "trending_discover": AppLanguage.string(.homeAddRowControlPeriod)
        case "mood_collection": AppLanguage.string(.homeAddRowControlMood)
        case "seasonal_themed": AppLanguage.string(.settingsManifestUiThemeLabel)
        case "editorial_spotlight": AppLanguage.string(.homeAddRowControlSpotlightOn)
        case "format_showcase": AppLanguage.string(.detailFactsFormat)
        default: AppLanguage.string(.homeCustomizeOptionsTitle)
        }
    }

    static func presetSymbol(for presetKey: String) -> String? {
        switch presetKey {
        case "continue_watching_default": return "play.circle.fill"
        case "continue_listening_default": return "headphones"
        case "fs_4k", "fs_4k_recent": return "4k.tv.fill"
        case "fs_dv": return "sparkles.tv.fill"
        case "fs_hdr": return "sun.max.fill"
        case "es_director_auto": return "film.fill"
        case "es_actor": return "person.fill"
        case "es_studio": return "building.columns.fill"
        case "es_era_80s": return "clock.fill"
        case "mood_feel_good": return "face.smiling.fill"
        case "mood_mind_bending": return "sparkles"
        case "mood_comfort": return "cup.and.saucer.fill"
        case "mood_edge_of_seat": return "bolt.fill"
        case "mood_tearjerker": return "drop.fill"
        case "mood_quiet_sunday": return "book.closed.fill"
        case "mood_date_night": return "heart.fill"
        case "mood_after_midnight": return "moon.stars.fill"
        case "se_auto": return "calendar"
        case "se_family_movie_night": return "popcorn.fill"
        default: return nil
        }
    }
}
#endif
