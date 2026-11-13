import SwiftUI

func libraryCollectionAccessibilityLabel(
    _ collection: LibraryCollection,
    showItemCount: Bool = true,
    locale: Locale
) -> String {
    let type = collection.kind == .userCollections
        ? AppLanguage.string(.collectionsUserCollection, locale: locale)
        : collection.collectionType?.capitalized ?? AppLanguage.string(.collectionsCollection, locale: locale)
    let count = if let itemCount = collection.itemCount {
        AppLanguage.string(.collectionsItemCount(count: itemCount, LocaleFormat.integer(itemCount, locale: locale)), locale: locale)
    } else {
        AppLanguage.string(.collectionsTypeSmart, locale: locale)
    }
    return (showItemCount ? [collection.name, type, count] : [collection.name, type]).joined(separator: ", ")
}

/// List of user-created collections, grouped into named buckets +
/// "Ungrouped". Mirrors the web app's `Collections` page.
struct CollectionsView: View {
    @State private var viewModel = CollectionsViewModel()
    @Environment(AppRouter.self) private var router
    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            if !viewModel.collections.isEmpty || !viewModel.groups.isEmpty {
                sectionedList
            } else if let error = viewModel.error {
                ErrorView(state: error, onRetry: { Task { await viewModel.loadCollections() } })
            } else if viewModel.isLoading {
                Color.clear
            } else {
                EmptyStateView(
                    icon: "square.stack",
                    title: AppLanguage.string(.collectionsNone, locale: locale),
                    subtitle: AppLanguage.string(.collectionsNoneBody, locale: locale)
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if case .unknown(let message) = viewModel.groupSupport {
                groupSupportNotice(message)
            }
        }
        .siloPageBackground()
        .navigationTitle(Text(.collectionsTitle))
        .siloNavigationTitleDisplayMode(.large)
        .toolbar {
            #if os(macOS)
            if viewModel.canManageGroups {
                ToolbarItem {
                    Button {
                        viewModel.pendingGroupAction = .create
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .foregroundColor(.siloPrimary)
                    }
                }
            }
            ToolbarItem {
                Button {
                    viewModel.showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundColor(.siloPrimary)
                }
            }
            #else
            if viewModel.canManageGroups {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.pendingGroupAction = .create
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .foregroundColor(.siloPrimary)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundColor(.siloPrimary)
                }
            }
            #endif
        }
        .sheet(isPresented: $viewModel.showCreateSheet) {
            createSheet
        }
        .sheet(item: $viewModel.pendingGroupAction) { action in
            GroupActionSheet(action: action, viewModel: viewModel)
        }
        .task {
            await viewModel.loadCollections()
        }
        .refreshable {
            await viewModel.loadCollections()
        }
    }

    // MARK: - Sectioned list

    private var sectionedList: some View {
        List {
            ForEach(viewModel.sections) { section in
                Section {
                    if section.collections.isEmpty {
                        Text(emptyGroupHint)
                            .font(.siloSmall)
                            .foregroundColor(.siloSecondaryText)
                            .listRowBackground(Color.siloSurface)
                    } else {
                        ForEach(section.collections) { collection in
                            collectionRow(collection)
                                .listRowBackground(Color.siloSurface)
                                #if !os(tvOS)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        viewModel.pendingGroupAction = .deleteCollection(collection)
                                    } label: {
                                        Label(.collectionsDelete, systemImage: "trash")
                                    }
                                    if viewModel.canManageGroups {
                                        Button {
                                            viewModel.pendingGroupAction = .move(collection)
                                        } label: {
                                            Label(.collectionsMove, systemImage: "folder")
                                        }
                                        .tint(.siloPrimary)
                                    }
                                }
                                #endif
                        }
                    }
                } header: {
                    sectionHeader(section)
                }
            }
        }
        #if os(tvOS) || os(macOS)
        .listStyle(.plain)
        #else
        .listStyle(.insetGrouped)
        #endif
        .siloScrollContentBackgroundHidden()
    }

    /// tvOS has no Move action, so it only notes the group is empty.
    private var emptyGroupHint: LocalizedStringResource {
        #if os(tvOS)
        .collectionsGroupEmpty
        #else
        .collectionsGroupEmptyHint
        #endif
    }

    @ViewBuilder
    private func sectionHeader(_ section: UserCollectionSection) -> some View {
        HStack {
            Group {
                if let name = section.name {
                    Text(name)
                } else {
                    Text(.collectionsUngrouped)
                }
            }
                .font(.siloCaption)
                .foregroundColor(.siloSecondaryText)
            Spacer()
            if viewModel.canManageGroups, let groupId = section.groupId,
               let group = viewModel.groups.first(where: { $0.id == groupId }) {
                Menu {
                    Button {
                        viewModel.pendingGroupAction = .rename(group)
                    } label: {
                        Label(.collectionsGroupRename, systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        viewModel.pendingGroupAction = .delete(group)
                    } label: {
                        Label(.collectionsGroupDelete, systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.siloSecondaryText)
                }
            }
        }
    }

    /// The capability read failed: groups can't be managed until it is
    /// retried, but nothing concludes they are unsupported.
    private func groupSupportNotice(_ message: String) -> some View {
        HStack(spacing: SiloTheme.padding) {
            Text(message)
                .font(.siloCaption)
                .foregroundColor(.siloSecondaryText)
            Spacer()
            Button(.commonRetry) {
                Task { await viewModel.retryGroupSupport() }
            }
            .foregroundColor(.siloPrimary)
        }
        .padding(.horizontal, SiloTheme.padding)
        .padding(.vertical, 8)
        .background(Color.siloSurface)
    }

    private func collectionRow(_ collection: UserCollection) -> some View {
        Button {
            router.navigate(to: .collectionDetail(collectionId: collection.id))
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(collection.name)
                        .font(.siloBody)
                        .foregroundColor(.siloOnSurface)

                    Text(rowSubtitle(for: collection))
                        .font(.siloCaption)
                        .foregroundColor(.siloSecondaryText)
                }

                Spacer()

                Image(systemName: "chevron.forward")
                    .font(.siloCaption)
                    .foregroundColor(.siloSecondaryText)
            }
            .padding(.vertical, 4)
        }
    }

    /// The kind is the server's collection type; a collection without one
    /// reads as Custom.
    private func rowSubtitle(for collection: UserCollection) -> String {
        let kind = collection.collectionType?.capitalized
            ?? AppLanguage.string(.collectionsTypeCustom, locale: locale)
        if let count = collection.itemCount, count > 0 {
            return AppLanguage.string(.collectionsRowKindCount(count: count, LocaleFormat.integer(count, locale: locale), kind), locale: locale)
        }
        return kind
    }

    // MARK: - Create Sheet

    private var createSheet: some View {
        NavigationStack {
            VStack(spacing: SiloTheme.largePadding) {
                TextField(text: $viewModel.newCollectionName) { Text(.collectionsCreateNameLabel) }
                    .textFieldStyle(SiloTextFieldStyle())

                if let message = viewModel.createError {
                    Text(message)
                        .font(.siloCaption)
                        .foregroundColor(.siloError)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(.collectionsCreateAction) {
                    Task { await viewModel.createCollection() }
                }
                .siloPrimaryButton()
                .disabled(viewModel.isSaving
                    || viewModel.newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()
            }
            .padding(SiloTheme.padding)
            .siloSheetBackground()
            .navigationTitle(Text(.collectionsCreateTitle))
            .siloNavigationTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.commonCancel) {
                        viewModel.showCreateSheet = false
                    }
                    .foregroundColor(.siloSecondaryText)
                }
            }
            .siloNavigationBarSurfaceBackground()
        }
        .presentationDetents([.medium])
    }
}

/// Modal for create-group / rename-group / delete-group / move-collection /
/// delete-collection. Edits of an existing item read its current version when
/// the sheet opens and send that version; after a conflict or an unknown
/// outcome the sheet offers Reload instead of resending.
private struct GroupActionSheet: View {
    let action: CollectionsViewModel.GroupAction
    let viewModel: CollectionsViewModel

    @State private var name: String = ""
    @State private var pendingMoveTarget: String? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    var body: some View {
        NavigationStack {
            content
                .siloSheetBackground()
                .siloNavigationTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(.commonCancel) { dismiss() }
                            .foregroundColor(.siloSecondaryText)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(confirmLabel) { Task { await confirm() } }
                            .foregroundColor(.siloPrimary)
                            .disabled(!canConfirm)
                    }
                }
                .siloNavigationBarSurfaceBackground()
        }
        .presentationDetents([.medium])
        .task {
            await viewModel.loadEditor()
        }
        .onAppear {
            switch action {
            case .rename(let g): name = g.name
            case .move(let c): pendingMoveTarget = c.groupId
            default: break
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch action {
        case .create:
            nameForm(title: .collectionsGroupNewTitle, prompt: .collectionsGroupNamePrompt)
        case .rename(let group):
            nameForm(title: .collectionsGroupRenameTitle(group.name), prompt: .collectionsGroupNamePrompt)
        case .delete(let group):
            VStack(spacing: SiloTheme.padding) {
                Text(.collectionsDeleteNamed(group.name))
                    .font(.siloTitle)
                    .foregroundStyle(Color.siloOnSurface)
                Text(.collectionsGroupDeleteBody)
                    .font(.siloBody)
                    .foregroundStyle(Color.siloSecondaryText)
                    .multilineTextAlignment(.center)
                errorBanner
                Spacer()
            }
            .padding(SiloTheme.padding)
            .navigationTitle(Text(.collectionsGroupDelete))
        case .deleteCollection(let collection):
            VStack(spacing: SiloTheme.padding) {
                Text(.collectionsDeleteNamed(collection.name))
                    .font(.siloTitle)
                    .foregroundStyle(Color.siloOnSurface)
                Text(.collectionsDeleteBody)
                    .font(.siloBody)
                    .foregroundStyle(Color.siloSecondaryText)
                    .multilineTextAlignment(.center)
                errorBanner
                Spacer()
            }
            .padding(SiloTheme.padding)
            .navigationTitle(Text(.collectionsDeleteTitle))
        case .move(let collection):
            VStack(spacing: 0) {
                List {
                    Section {
                        Button {
                            pendingMoveTarget = nil
                        } label: {
                            moveOptionRow(
                                label: AppLanguage.string(.collectionsUngrouped, locale: locale),
                                selected: pendingMoveTarget == nil
                            )
                        }
                        .listRowBackground(Color.siloSurface)
                        ForEach(viewModel.groups) { group in
                            Button {
                                pendingMoveTarget = group.id
                            } label: {
                                moveOptionRow(label: group.name, selected: pendingMoveTarget == group.id)
                            }
                            .listRowBackground(Color.siloSurface)
                        }
                    } header: {
                        Text(.collectionsMoveTo(collection.name))
                    }
                }
                #if os(tvOS) || os(macOS)
                .listStyle(.plain)
                #else
                .listStyle(.insetGrouped)
                #endif
                .siloScrollContentBackgroundHidden()
                errorBanner
                    .padding(.horizontal, SiloTheme.padding)
                    .padding(.bottom, SiloTheme.padding)
            }
            .navigationTitle(Text(.collectionsMoveTitle))
        }
    }

    private func nameForm(title: LocalizedStringResource, prompt: LocalizedStringResource) -> some View {
        VStack(spacing: SiloTheme.largePadding) {
            TextField(text: $name) { Text(prompt) }
                .textFieldStyle(SiloTextFieldStyle())
            errorBanner
            Spacer()
        }
        .padding(SiloTheme.padding)
        .navigationTitle(Text(title))
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = viewModel.groupError {
            Text(message)
                .font(.siloCaption)
                .foregroundColor(.siloError)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if viewModel.editorNeedsReload {
            Button(.collectionsReload) {
                Task { await viewModel.loadEditor() }
            }
            .foregroundColor(.siloPrimary)
            .disabled(viewModel.isLoadingEditor)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func moveOptionRow(label: String, selected: Bool) -> some View {
        HStack {
            Text(label)
                .font(.siloBody)
                .foregroundColor(.siloOnSurface)
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .foregroundColor(.siloPrimary)
            }
        }
    }

    private var confirmLabel: LocalizedStringResource {
        switch action {
        case .create: return .collectionsGroupCreate
        case .rename: return .commonSave
        case .delete, .deleteCollection: return .collectionsDelete
        case .move: return .collectionsMove
        }
    }

    private var canConfirm: Bool {
        guard viewModel.canSubmitGroupAction else { return false }
        switch action {
        case .create, .rename:
            return !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .delete, .move, .deleteCollection:
            return true
        }
    }

    private func confirm() async {
        switch action {
        case .create:
            await viewModel.createGroup(name: name)
        case .rename:
            await viewModel.renameGroup(name: name)
        case .delete(let group):
            await viewModel.deleteGroup(id: group.id)
        case .move:
            await viewModel.moveCollection(toGroupId: pendingMoveTarget)
        case .deleteCollection(let collection):
            await viewModel.deleteCollection(id: collection.id)
        }
        // The view model clears `pendingGroupAction` only on success;
        // keep the sheet open on error so the failure and any Reload
        // action show in the sheet, with the draft intact.
        if viewModel.pendingGroupAction == nil {
            dismiss()
        }
    }
}

@Observable
@MainActor
private class LibraryCollectionsViewModel {
    /// Ordered render sections — either named groups from the server or
    /// a single anonymous section synthesized from a flat response.
    var sections: [LibraryCollectionSection] = []
    var isLoading = false
    var isRefreshing = false
    var error: ErrorState?

    var isEmpty: Bool { sections.allSatisfy { $0.collections.isEmpty } }

    func loadCollections(libraryId: Int) async {
        let key = "library:\(libraryId):collections"
        if sections.isEmpty,
           let cached: [LibraryCollectionSection] = ResponseCache.shared.get(key) {
            sections = cached
        }
        if sections.isEmpty {
            isLoading = true
        } else {
            isRefreshing = true
        }
        error = nil

        do {
            let response = try await SiloAPI.shared.libraryCollections(libraryId: libraryId)
            let resolved = response.resolvedSections
            ResponseCache.shared.set(resolved, for: key)
            sections = resolved
        } catch let err {
            if sections.isEmpty {
                error = ErrorState(err)
            }
        }

        isLoading = false
        isRefreshing = false
    }
}

struct LibraryCollectionsView: View {
    let libraryId: Int
    var mediaScope: LibraryVideoScope? = nil

    @State private var viewModel = LibraryCollectionsViewModel()
    @State private var uiCustomization = UICustomizationPreferences.shared
    @State private var gridWidth: CGFloat = 0
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.locale) private var locale

    private var columns: [GridItem] {
        if let fit = widePhonePosterFit {
            return fit.columns
        }
        if usesThreeColumnPhoneLayout {
            return Array(
                repeating: GridItem(.flexible(), spacing: 8),
                count: 3
            )
        }
        return AdaptiveColumns.posters(
            for: hSize,
            posterSize: uiCustomization.cardPresentation.posterSize
        )
    }

    var body: some View {
        Group {
            if !viewModel.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: SiloTheme.padding) {
                        ForEach(viewModel.sections) { section in
                            sectionView(section)
                        }
                    }
                    .padding(SiloTheme.padding)
                    .padding(.bottom, SiloTheme.largePadding)
                }
                .reportsPageChromeScroll()
                .scrollsToTopOnLibraryDockRequest()
            } else if let error = viewModel.error {
                ErrorView(state: error, onRetry: { Task { await viewModel.loadCollections(libraryId: libraryId) } })
            } else if viewModel.isLoading {
                Color.clear
            } else {
                EmptyStateView(
                    icon: "square.stack.3d.up.fill",
                    title: AppLanguage.string(.collectionsEmpty, locale: locale),
                    subtitle: AppLanguage.string(.collectionsEmptyLibraryHint, locale: locale)
                )
            }
        }
        .siloPageBackground()
        .task(id: libraryId) {
            await viewModel.loadCollections(libraryId: libraryId)
        }
        .refreshable {
            await viewModel.loadCollections(libraryId: libraryId)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: LibraryCollectionSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !section.name.isEmpty {
                Text(section.name)
                    .font(.siloTitle)
                    .foregroundColor(.siloOnSurface)
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(section.collections) { collection in
                    // Through the router, not NavigationLink(value:), so the
                    // router's record of pushed routes stays in step with the
                    // stack: the Mac sidebar highlights from it, and closing
                    // Requests screens reads it.
                    Button {
                        router.navigate(to: .libraryCollection(
                            libraryId: libraryId,
                            collectionId: collection.id,
                            title: collection.name,
                            kind: collection.kind,
                            mediaScope: mediaScope
                        ))
                    } label: {
                        LibraryCollectionCard(
                            collection: collection,
                            cardWidthOverride: libraryCollectionCardWidthOverride,
                            showItemCount: mediaScope == nil
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(libraryCollectionAccessibilityLabel(
                        collection, showItemCount: mediaScope == nil, locale: locale
                    ))
                }
            }
            #if os(iOS)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                guard abs(width - gridWidth) >= 0.5 else { return }
                gridWidth = width
            }
            #endif
        }
    }

    private var usesThreeColumnPhoneLayout: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    /// A phone window too wide for three-up cards (the iPhone Duo's inner
    /// display) fills the row with more columns.
    private var widePhonePosterFit: AdaptiveColumns.PosterGridFit? {
        guard usesThreeColumnPhoneLayout else { return nil }
        return AdaptiveColumns.widePhonePosterFit(
            containerWidth: gridWidth,
            posterSize: uiCustomization.cardPresentation.posterSize,
            verticalSizeClass: vSize
        )
    }

    private var libraryCollectionCardWidthOverride: CGFloat? {
        if let fit = widePhonePosterFit { return fit.cardWidth }
        guard usesThreeColumnPhoneLayout else { return nil }
        return AdaptiveColumns.fittedPosterWidth(
            containerWidth: gridWidth,
            columnCount: 3,
            spacing: 8
        )
    }
}

private struct LibraryCollectionCard: View {
    let collection: LibraryCollection
    let cardWidthOverride: CGFloat?
    var showItemCount = true
    @State private var uiCustomization = UICustomizationPreferences.shared
    @Environment(\.locale) private var locale

    private var cardWidth: CGFloat {
        cardWidthOverride
            ?? (SiloTheme.posterCardWidth * uiCustomization.cardPresentation.posterSize.scale)
    }
    private var cardHeight: CGFloat {
        cardWidth * (SiloTheme.posterCardHeight / SiloTheme.posterCardWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                poster

                if showItemCount {
                    Text(countLabel)
                        .font(.siloSmall)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.65))
                        .clipShape(Capsule())
                        .padding(8)
                }
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius))

            Text(collection.name)
                .font(.siloCaption)
                .foregroundStyle(Color.siloOnSurface)
                #if os(iOS)
                // One line, like the 2:3 cards in the other iOS grids.
                .lineLimit(1)
                #else
                .lineLimit(2, reservesSpace: true)
                #endif

            Text(typeLabel)
                .font(.siloSmall)
                .foregroundStyle(Color.siloSecondaryText)
                .lineLimit(1)
        }
        .frame(width: cardWidth, alignment: .leading)
    }

    @ViewBuilder
    private var poster: some View {
        if let posterUrl = collection.posterUrl, !posterUrl.isEmpty {
            AsyncImageView(
                url: posterUrl,
                thumbhash: collection.posterThumbhash,
                targetSize: CGSize(width: cardWidth, height: cardHeight),
                contentMode: .fill
            )
            .frame(width: cardWidth, height: cardHeight)
        } else {
            ZStack {
                Color.siloSurfaceVariant
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.siloSecondaryText)
            }
            .frame(width: cardWidth, height: cardHeight)
        }
    }

    private var countLabel: String {
        if let itemCount = collection.itemCount {
            return "\(itemCount)"
        }
        return AppLanguage.string(.collectionsTypeSmart, locale: locale)
    }

    private var typeLabel: String {
        if collection.kind == .userCollections {
            return AppLanguage.string(.collectionsUserCollection, locale: locale)
        }
        return collection.collectionType?.capitalized ?? AppLanguage.string(.collectionsCollection, locale: locale)
    }
}

struct LibraryCollectionDetailView: View {
    let libraryId: Int
    let collectionId: String
    let title: String?
    let kind: LibraryCollectionKind?
    var mediaScope: LibraryVideoScope? = nil

    @State private var viewModel = LibraryCollectionDetailViewModel()
    @State private var shuffleLauncher = ShuffleLauncher()
    @Environment(AppRouter.self) private var router
    @Environment(\.locale) private var locale

    private var shuffleKind: ShuffleScopeKind {
        (kind ?? .regular).shuffleScopeKind
    }

    /// A shuffle scope has no media type, so a Movies or Series view of a
    /// mixed library's collection would shuffle titles of both types.
    private var offersShuffle: Bool {
        mediaScope == nil && ShuffleFeatureStore.shared.supports(shuffleKind)
    }

    var body: some View {
        Group {
            if !viewModel.items.isEmpty {
                content
            } else if let error = viewModel.error {
                ErrorView(state: error, onRetry: { Task { await loadItems(reset: true) } })
            } else if viewModel.isLoading {
                Color.clear
            } else {
                EmptyStateView(
                    icon: "square.stack.3d.up.fill",
                    title: AppLanguage.string(.collectionsEmptyItemsTitle, locale: locale),
                    subtitle: AppLanguage.string(.collectionsEmptyItemsBody, locale: locale)
                )
            }
        }
        .siloPageBackground()
        // Collection items can live in other libraries, and a library-scoped
        // item read 404s for those. Keep cards and play actions unscoped, like
        // the web client.
        .environment(\.browseLibraryId, nil)
        .navigationTitle(title.map { Text($0) } ?? Text(.collectionsCollection))
        .siloNavigationTitleDisplayMode(.large)
        .task(id: "\(libraryId)-\(collectionId)-\(mediaScope?.rawValue ?? "all")-\(kind?.rawValue ?? "regular")") {
            await loadItems(reset: true)
        }
        .shuffleFailureAlert(shuffleLauncher)
        .refreshable {
            await loadItems(reset: true)
        }
    }

    private var content: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: SiloTheme.padding) {
                HStack(spacing: SiloTheme.padding) {
                    if offersShuffle {
                        ShuffleButton(isStarting: shuffleLauncher.isStarting) {
                            shuffleLauncher.start(ShuffleScopeRequest(kind: shuffleKind, id: collectionId), router: router)
                        }
                    }
                    Text(countLabel)
                        .font(.siloCaption)
                        .foregroundColor(.siloSecondaryText)
                }
                #if os(tvOS)
                // Up from any grid column reaches the Shuffle button.
                .focusSection()
                #endif

                CatalogGrid(
                    items: viewModel.items,
                    isLoading: viewModel.isLoading,
                    hasMore: viewModel.hasMore,
                    forcesThreeColumnsOnPhone: true,
                    onItemTap: { item in
                        router.navigate(to: .itemDetail(browseItem: item))
                    },
                    onLoadMore: {
                        Task { await loadMoreIfNeeded() }
                    }
                )
            }
            .padding(.horizontal, SiloTheme.padding)
            .padding(.top, SiloTheme.smallPadding)
            .padding(.bottom, SiloTheme.largePadding)
        }
    }

    private var countLabel: LocalizedStringResource {
        if viewModel.hasMore {
            return .collectionsItemCountMore(count: viewModel.items.count, LocaleFormat.integer(viewModel.items.count))
        }
        let count = viewModel.totalItems ?? viewModel.items.count
        return .collectionsItemCount(count: count, LocaleFormat.integer(count))
    }

    private func loadMoreIfNeeded() async {
        guard viewModel.hasMore, !viewModel.isLoading else { return }
        await loadItems(reset: false)
    }

    private func loadItems(reset: Bool) async {
        await viewModel.load(libraryId: libraryId, collectionId: collectionId,
                             kind: kind ?? .regular, mediaScope: mediaScope, reset: reset)
    }
}
