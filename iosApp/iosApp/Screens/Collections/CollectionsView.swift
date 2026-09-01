import SwiftUI

func libraryCollectionAccessibilityLabel(_ collection: LibraryCollection) -> String {
    let type = collection.kind == .userCollections
        ? "User collection"
        : collection.collectionType?.capitalized ?? "Collection"
    let count = if let itemCount = collection.itemCount {
        "\(itemCount) item\(itemCount == 1 ? "" : "s")"
    } else {
        "Smart"
    }
    return [collection.name, type, count].joined(separator: ", ")
}

/// List of user-created collections, grouped into named buckets +
/// "Ungrouped". Mirrors the web app's `Collections` page.
struct CollectionsView: View {
    @State private var viewModel = CollectionsViewModel()
    @Environment(AppRouter.self) private var router

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
                    title: "No collections",
                    subtitle: "Create a collection to organize your media"
                )
            }
        }
        .continuumBackground()
        .navigationTitle("Collections")
        .continuumNavigationTitleDisplayMode(.large)
        .toolbar {
            #if os(macOS)
            ToolbarItem {
                Button {
                    viewModel.pendingGroupAction = .create
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .foregroundColor(.continuumPrimary)
                }
            }
            ToolbarItem {
                Button {
                    viewModel.showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundColor(.continuumPrimary)
                }
            }
            #else
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.pendingGroupAction = .create
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .foregroundColor(.continuumPrimary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundColor(.continuumPrimary)
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
                        Text("Drop collections here to add them to this group.")
                            .font(.continuumSmall)
                            .foregroundColor(.continuumSecondaryText)
                            .listRowBackground(Color.continuumSurface)
                    } else {
                        ForEach(section.collections) { collection in
                            collectionRow(collection)
                                .listRowBackground(Color.continuumSurface)
                                #if !os(tvOS)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        Task { await viewModel.deleteCollection(id: collection.id) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        viewModel.pendingGroupAction = .move(collection)
                                    } label: {
                                        Label("Move", systemImage: "folder")
                                    }
                                    .tint(.continuumPrimary)
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
        .continuumScrollContentBackgroundHidden()
    }

    @ViewBuilder
    private func sectionHeader(_ section: UserCollectionSection) -> some View {
        HStack {
            Text(section.name)
                .font(.continuumCaption)
                .foregroundColor(.continuumSecondaryText)
            Spacer()
            if let groupId = section.groupId,
               let group = viewModel.groups.first(where: { $0.id == groupId }) {
                Menu {
                    Button {
                        viewModel.pendingGroupAction = .rename(group)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        viewModel.pendingGroupAction = .delete(group)
                    } label: {
                        Label("Delete group", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.continuumSecondaryText)
                }
            }
        }
    }

    private func collectionRow(_ collection: UserCollection) -> some View {
        Button {
            router.navigate(to: .collectionDetail(collectionId: collection.id))
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(collection.name)
                        .font(.continuumBody)
                        .foregroundColor(.continuumOnSurface)

                    Text(rowSubtitle(for: collection))
                        .font(.continuumCaption)
                        .foregroundColor(.continuumSecondaryText)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.continuumCaption)
                    .foregroundColor(.continuumSecondaryText)
            }
            .padding(.vertical, 4)
        }
    }

    private func rowSubtitle(for collection: UserCollection) -> String {
        let kind = (collection.collectionType ?? "custom").capitalized
        if let count = collection.itemCount, count > 0 {
            return "\(kind) · \(count) item\(count == 1 ? "" : "s")"
        }
        return kind
    }

    // MARK: - Create Sheet

    private var createSheet: some View {
        NavigationStack {
            VStack(spacing: ContinuumTheme.largePadding) {
                TextField("Collection name", text: $viewModel.newCollectionName)
                    .textFieldStyle(ContinuumTextFieldStyle())

                Button("Create Collection") {
                    Task { await viewModel.createCollection() }
                }
                .siloPrimaryButton()
                .disabled(viewModel.newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()
            }
            .padding(ContinuumTheme.padding)
            .continuumBackground()
            .navigationTitle("New Collection")
            .continuumNavigationTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.showCreateSheet = false
                    }
                    .foregroundColor(.continuumSecondaryText)
                }
            }
            .continuumNavigationBarSurfaceBackground()
        }
        .presentationDetents([.medium])
    }
}

/// Modal for create-group / rename-group / delete-group / move-collection.
private struct GroupActionSheet: View {
    let action: CollectionsViewModel.GroupAction
    let viewModel: CollectionsViewModel

    @State private var name: String = ""
    @State private var pendingMoveTarget: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .continuumBackground()
                .continuumNavigationTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .foregroundColor(.continuumSecondaryText)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(confirmLabel) { Task { await confirm() } }
                            .foregroundColor(.continuumPrimary)
                            .disabled(!canConfirm)
                    }
                }
                .continuumNavigationBarSurfaceBackground()
        }
        .presentationDetents([.medium])
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
            nameForm(title: "New group", prompt: "Group name")
        case .rename(let group):
            nameForm(title: "Rename “\(group.name)”", prompt: "Group name")
        case .delete(let group):
            VStack(spacing: ContinuumTheme.padding) {
                Text("Delete “\(group.name)”?")
                    .font(.continuumTitle)
                    .foregroundStyle(Color.continuumOnSurface)
                Text("Collections in this group will move to Ungrouped. This cannot be undone.")
                    .font(.continuumBody)
                    .foregroundStyle(Color.continuumSecondaryText)
                    .multilineTextAlignment(.center)
                errorBanner
                Spacer()
            }
            .padding(ContinuumTheme.padding)
            .navigationTitle("Delete group")
        case .move(let collection):
            VStack(spacing: 0) {
                List {
                    Section("Move “\(collection.name)” to") {
                        Button {
                            pendingMoveTarget = nil
                        } label: {
                            moveOptionRow(label: "Ungrouped", selected: pendingMoveTarget == nil)
                        }
                        .listRowBackground(Color.continuumSurface)
                        ForEach(viewModel.groups) { group in
                            Button {
                                pendingMoveTarget = group.id
                            } label: {
                                moveOptionRow(label: group.name, selected: pendingMoveTarget == group.id)
                            }
                            .listRowBackground(Color.continuumSurface)
                        }
                    }
                }
                #if os(tvOS) || os(macOS)
                .listStyle(.plain)
                #else
                .listStyle(.insetGrouped)
                #endif
                .continuumScrollContentBackgroundHidden()
                errorBanner
                    .padding(.horizontal, ContinuumTheme.padding)
                    .padding(.bottom, ContinuumTheme.padding)
            }
            .navigationTitle("Move collection")
        }
    }

    private func nameForm(title: String, prompt: String) -> some View {
        VStack(spacing: ContinuumTheme.largePadding) {
            TextField(prompt, text: $name)
                .textFieldStyle(ContinuumTextFieldStyle())
            errorBanner
            Spacer()
        }
        .padding(ContinuumTheme.padding)
        .navigationTitle(title)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = viewModel.groupError {
            Text(message)
                .font(.continuumCaption)
                .foregroundColor(.continuumError)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func moveOptionRow(label: String, selected: Bool) -> some View {
        HStack {
            Text(label)
                .font(.continuumBody)
                .foregroundColor(.continuumOnSurface)
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .foregroundColor(.continuumPrimary)
            }
        }
    }

    private var confirmLabel: String {
        switch action {
        case .create: return "Create"
        case .rename: return "Save"
        case .delete: return "Delete"
        case .move: return "Move"
        }
    }

    private var canConfirm: Bool {
        switch action {
        case .create, .rename:
            return !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .delete, .move:
            return true
        }
    }

    private func confirm() async {
        switch action {
        case .create:
            await viewModel.createGroup(name: name)
        case .rename(let group):
            await viewModel.renameGroup(id: group.id, name: name)
        case .delete(let group):
            await viewModel.deleteGroup(id: group.id)
        case .move(let collection):
            await viewModel.moveCollection(id: collection.id, toGroupId: pendingMoveTarget)
        }
        // The view model clears `pendingGroupAction` only on success;
        // keep the sheet open on error so the user sees the failure
        // surfaced on the main view.
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
            let response = try await ContinuumAPI.shared.libraryCollections(libraryId: libraryId)
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

    @State private var viewModel = LibraryCollectionsViewModel()
    @State private var uiCustomization = UICustomizationPreferences.shared
    @Environment(\.horizontalSizeClass) private var hSize

    private var columns: [GridItem] {
        AdaptiveColumns.posters(
            for: hSize,
            posterSize: uiCustomization.cardPresentation.posterSize
        )
    }

    var body: some View {
        Group {
            if !viewModel.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: ContinuumTheme.padding) {
                        ForEach(viewModel.sections) { section in
                            sectionView(section)
                        }
                    }
                    .padding(ContinuumTheme.padding)
                    .padding(.bottom, ContinuumTheme.largePadding)
                }
            } else if let error = viewModel.error {
                ErrorView(state: error, onRetry: { Task { await viewModel.loadCollections(libraryId: libraryId) } })
            } else if viewModel.isLoading {
                Color.clear
            } else {
                EmptyStateView(
                    icon: "square.stack.3d.up.fill",
                    title: "No collections yet",
                    subtitle: "Create library collections in the web app to feature curated shelves here."
                )
            }
        }
        .continuumBackground()
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
                    .font(.continuumTitle)
                    .foregroundColor(.continuumOnSurface)
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(section.collections) { collection in
                    NavigationLink(
                        value: Route.libraryCollection(
                            libraryId: libraryId,
                            collectionId: collection.id,
                            title: collection.name,
                            kind: collection.kind
                        )
                    ) {
                        LibraryCollectionCard(collection: collection)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(libraryCollectionAccessibilityLabel(collection))
                }
            }
        }
    }
}

private struct LibraryCollectionCard: View {
    let collection: LibraryCollection
    @State private var uiCustomization = UICustomizationPreferences.shared

    private var cardWidth: CGFloat {
        ContinuumTheme.posterCardWidth * uiCustomization.cardPresentation.posterSize.scale
    }
    private var cardHeight: CGFloat {
        cardWidth * (ContinuumTheme.posterCardHeight / ContinuumTheme.posterCardWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                poster

                Text(countLabel)
                    .font(.continuumSmall)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.65))
                    .clipShape(Capsule())
                    .padding(8)
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: ContinuumTheme.smallCornerRadius))

            if uiCustomization.cardPresentation.caption.showsTitle {
                Text(collection.name)
                    .font(.continuumCaption)
                    .foregroundStyle(Color.continuumOnSurface)
                    .lineLimit(2, reservesSpace: true)
            }

            if uiCustomization.cardPresentation.caption.showsMetadata {
                Text(typeLabel)
                    .font(.continuumSmall)
                    .foregroundStyle(Color.continuumSecondaryText)
                    .lineLimit(1)
            }
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
            .clipped()
        } else {
            ZStack {
                Color.continuumSurfaceVariant
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.continuumSecondaryText)
            }
            .frame(width: cardWidth, height: cardHeight)
        }
    }

    private var countLabel: String {
        if let itemCount = collection.itemCount {
            return "\(itemCount)"
        }
        return "Smart"
    }

    private var typeLabel: String {
        if collection.kind == .userCollections {
            return "User collection"
        }
        return collection.collectionType?.capitalized ?? "Collection"
    }
}

struct LibraryCollectionDetailView: View {
    let libraryId: Int
    let collectionId: String
    let title: String?
    let kind: LibraryCollectionKind?

    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var error: ErrorState?
    @State private var hasMore = true
    @State private var totalItems: Int?
    @State private var nextOffset = 0
    @State private var snapshot: String?

    @Environment(AppRouter.self) private var router

    private let pageSize = 60

    var body: some View {
        Group {
            if !items.isEmpty {
                content
            } else if let error {
                ErrorView(state: error, onRetry: { Task { await loadItems(reset: true) } })
            } else if isLoading {
                Color.clear
            } else {
                EmptyStateView(
                    icon: "square.stack.3d.up.fill",
                    title: "Collection is empty",
                    subtitle: "This collection does not have any items yet."
                )
            }
        }
        .continuumBackground()
        .navigationTitle(title ?? "Collection")
        .continuumNavigationTitleDisplayMode(.large)
        .task(id: "\(libraryId)-\(collectionId)") {
            await loadItems(reset: true)
        }
        .refreshable {
            await loadItems(reset: true)
        }
    }

    private var content: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: ContinuumTheme.padding) {
                Text(countLabel)
                    .font(.continuumCaption)
                    .foregroundColor(.continuumSecondaryText)

                CatalogGrid(
                    items: items,
                    isLoading: isLoading,
                    hasMore: hasMore,
                    onItemTap: { item in
                        router.navigate(to: .itemDetail(browseItem: item))
                    },
                    onLoadMore: {
                        Task { await loadMoreIfNeeded() }
                    }
                )
            }
            .padding(.horizontal, ContinuumTheme.padding)
            .padding(.top, ContinuumTheme.smallPadding)
            .padding(.bottom, ContinuumTheme.largePadding)
        }
    }

    private var countLabel: String {
        if let totalItems, !hasMore {
            return "\(totalItems) item\(totalItems == 1 ? "" : "s")"
        }
        let suffix = hasMore ? "+" : ""
        return "\(items.count)\(suffix) item\(items.count == 1 && !hasMore ? "" : "s")"
    }

    private func loadMoreIfNeeded() async {
        guard hasMore, !isLoading else { return }
        await loadItems(reset: false)
    }

    private func loadItems(reset: Bool) async {
        guard !isLoading else { return }
        if reset {
            // Surface the cached page-1 snapshot instantly so the grid
            // doesn't blank out while the network call runs.
            if items.isEmpty,
               let cached: CatalogResponse = ResponseCache.shared.get(
                   CacheKey.collectionItems(collectionId)
               ) {
                items = cached.items
                hasMore = cached.hasMore ?? false
                totalItems = cached.totalExact == false ? nil : cached.total
                nextOffset = cached.items.count
                snapshot = cached.snapshot
            } else {
                items = []
                hasMore = true
                totalItems = nil
                nextOffset = 0
                snapshot = nil
            }
        }
        guard hasMore else { return }

        isLoading = true
        error = nil

        do {
            let response: CatalogResponse
            if kind == .userCollections {
                response = try await ContinuumAPI.shared.userCollectionItems(
                    collectionId: collectionId,
                    offset: nextOffset,
                    limit: pageSize,
                    snapshot: snapshot
                )
            } else {
                response = try await ContinuumAPI.shared.libraryCollectionItems(
                    libraryId: libraryId,
                    collectionId: collectionId,
                    offset: nextOffset,
                    limit: pageSize,
                    snapshot: snapshot
                )
            }
            if reset {
                items = response.items
                ResponseCache.shared.set(response, for: CacheKey.collectionItems(collectionId))
            } else {
                items.append(contentsOf: response.items)
            }
            totalItems = response.totalExact == false ? nil : response.total
            hasMore = response.hasMore ?? false
            nextOffset += response.items.count
            if snapshot == nil {
                snapshot = response.snapshot
            }
        } catch let err {
            if items.isEmpty {
                error = ErrorState(err)
            }
        }

        isLoading = false
    }
}
