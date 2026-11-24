import SwiftUI

// MARK: - Collection Pin & Placement Controls (iOS + tvOS)

/// One-tap `Pin to Home` pill + `Where It Shows` menu shown right beside
/// `Shuffle` on `CollectionDetailView` and `LibraryCollectionDetailView`.
struct CollectionPinActionBar: View {
    let collectionId: String
    let title: String?
    let isUserCollection: Bool
    var sourceLibraryId: Int? = nil

    @State private var model: CollectionPlacementModel
    @State private var hapticCount = 0
    @Environment(\.locale) private var locale

    init(
        collectionId: String,
        title: String?,
        isUserCollection: Bool,
        sourceLibraryId: Int? = nil
    ) {
        self.collectionId = collectionId
        self.title = title
        self.isUserCollection = isUserCollection
        self.sourceLibraryId = sourceLibraryId
        _model = State(initialValue: CollectionPlacementModel(
            collectionId: collectionId,
            title: title,
            isUserCollection: isUserCollection,
            sourceLibraryId: sourceLibraryId
        ))
    }

    var body: some View {
        #if os(tvOS)
        tvControls
            .task(id: collectionId) { await model.load() }
            .alert(
                Text(.homeUpdateFailedTitle),
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.clearError() } }
                )
            ) {
                if model.hasFailedLoad {
                    Button(.commonRetry) {
                        Task { await model.load() }
                    }
                }
                Button(.homeUpdateFailedOk, role: .cancel) {}
            } message: {
                if let error = model.errorMessage {
                    Text(verbatim: error)
                }
            }
        #else
        iosControls
            .task(id: collectionId) { await model.load() }
            .alert(
                Text(.homeUpdateFailedTitle),
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.clearError() } }
                )
            ) {
                if model.hasFailedLoad {
                    Button(.commonRetry) {
                        Task { await model.load() }
                    }
                }
                Button(.homeUpdateFailedOk, role: .cancel) {}
            } message: {
                if let error = model.errorMessage {
                    Text(verbatim: error)
                }
            }
            #if os(iOS)
            .sensoryFeedback(.impact(weight: .light), trigger: hapticCount)
            #endif
        #endif
    }

    // MARK: - iOS / macOS

    #if !os(tvOS)
    private var iosControls: some View {
        HStack(spacing: 8) {
            Button {
                hapticCount += 1
                Task { await model.toggleHomePin() }
            } label: {
                HStack(spacing: 6) {
                    if model.isUpdatingHome {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(model.isPinnedOnHome ? .black : .white)
                    } else {
                        Image(systemName: model.isPinnedOnHome ? "pin.fill" : "pin")
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(model.isPinnedOnHome ? .collectionsPinOnHome : .collectionsPinPinToHome)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(model.isPinnedOnHome ? Color.black : Color.siloOnSurface)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Capsule().fill(
                        model.isPinnedOnHome
                            ? Color.white
                            : Color.white.opacity(0.12)
                    )
                )
                .overlay(
                    Capsule().strokeBorder(
                        Color.white.opacity(model.isPinnedOnHome ? 0 : 0.16),
                        lineWidth: 0.75
                    )
                )
            }
            .buttonStyle(.plain)
            .disabled(model.isLoading || !model.hasLoadedHome || model.isUpdatingHome)

            Menu {
                Section(.collectionsPinWhereItShows) {
                    Button {
                        hapticCount += 1
                        Task { await model.toggleHomePin() }
                    } label: {
                        Label(
                            .tabHome,
                            systemImage: model.isPinnedOnHome ? "checkmark.circle.fill" : "circle"
                        )
                    }
                    .disabled(model.isLoading || !model.hasLoadedHome || model.isUpdatingHome)

                    if model.hasFailedLoad && !model.isLoading {
                        Button {
                            Task { await model.load() }
                        } label: {
                            Label(.commonRetry, systemImage: "arrow.clockwise")
                        }
                    }

                    ForEach(model.libraryPlacements) { placement in
                        Button {
                            hapticCount += 1
                            Task { await model.toggleLibraryPin(libraryId: placement.libraryId) }
                        } label: {
                            Label(
                                placement.libraryName,
                                systemImage: placement.hasLoaded
                                    ? (placement.isPinned ? "checkmark.circle.fill" : "circle")
                                    : "exclamationmark.triangle"
                            )
                        }
                        .disabled(model.isLoading || !placement.hasLoaded || model.updatingLibraryIds.contains(placement.libraryId))
                    }
                }

                if model.isUserCollection && model.canToggleShare {
                    Section(.collectionsPinHousehold) {
                        Button {
                            hapticCount += 1
                            Task { await model.toggleShared() }
                        } label: {
                            Label(
                                .collectionsPinShareWithHousehold,
                                systemImage: model.isShared ? "checkmark.circle.fill" : "person.2"
                            )
                        }
                        .disabled(model.isLoading || model.isUpdatingShare)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.siloOnSurface)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75))
            }
            #if os(macOS)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            #endif
            .accessibilityLabel(.collectionsPinWhereItShows)
        }
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    private var tvControls: some View {
        HStack(spacing: 16) {
            Button {
                Task { await model.toggleHomePin() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: model.isPinnedOnHome ? "pin.fill" : "pin")
                        .font(.system(size: 20, weight: .semibold))
                    Text(model.isPinnedOnHome ? .collectionsPinOnHome : .collectionsPinPinToHome)
                        .font(.system(size: 22, weight: .semibold))
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .disabled(model.isLoading || !model.hasLoadedHome || model.isUpdatingHome)

            TVCircleMenuButton(
                icon: "ellipsis",
                title: AppLanguage.string(.collectionsPinWhereItShows, locale: locale),
                accessibilityLabel: AppLanguage.string(.collectionsPinWhereItShows, locale: locale),
                items: {
                    var items: [TVActionPopoverItem] = [
                        TVActionPopoverItem(
                            id: "home",
                            title: AppLanguage.string(.tabHome, locale: locale),
                            detail: AppLanguage.string(
                                model.isPinnedOnHome ? .collectionsPinPinnedOnHome : .collectionsPinNotOnHome,
                                locale: locale
                            ),
                            systemImage: "house",
                            isSelected: model.isPinnedOnHome,
                            isEnabled: !model.isLoading && model.hasLoadedHome && !model.isUpdatingHome
                        ),
                    ]
                    if model.hasFailedLoad && !model.isLoading {
                        items.append(TVActionPopoverItem(
                            id: "retry",
                            title: AppLanguage.string(.commonRetry, locale: locale),
                            systemImage: "arrow.clockwise"
                        ))
                    }
                    for placement in model.libraryPlacements {
                        items.append(TVActionPopoverItem(
                            id: "lib:\(placement.libraryId)",
                            title: placement.libraryName,
                            detail: placement.hasLoaded && placement.isPinned
                                ? AppLanguage.string(.collectionsPinPinnedOnLibrary, locale: locale)
                                : nil,
                            systemImage: placement.hasLoaded ? "film.stack" : "exclamationmark.triangle",
                            isSelected: placement.hasLoaded && placement.isPinned,
                            isEnabled: !model.isLoading && placement.hasLoaded && !model.updatingLibraryIds.contains(placement.libraryId)
                        ))
                    }
                    if model.isUserCollection && model.canToggleShare {
                        items.append(TVActionPopoverItem(
                            id: "share",
                            title: AppLanguage.string(.collectionsPinShareWithProfilesTv, locale: locale),
                            detail: AppLanguage.string(
                                model.isShared ? .collectionsPinVisibleToHousehold : .collectionsPinOnlyThisProfile,
                                locale: locale
                            ),
                            systemImage: "person.2",
                            isSelected: model.isShared,
                            isEnabled: !model.isLoading && !model.isUpdatingShare,
                            startsSection: true
                        ))
                    }
                    return items
                },
                onSelect: { item in
                    if item.id == "home" {
                        Task { await model.toggleHomePin() }
                    } else if item.id == "retry" {
                        Task { await model.load() }
                    } else if item.id == "share" {
                        Task { await model.toggleShared() }
                    } else if item.id.hasPrefix("lib:"),
                              let libId = Int(item.id.dropFirst(4)) {
                        Task { await model.toggleLibraryPin(libraryId: libId) }
                    }
                }
            )
        }
    }
    #endif
}

// MARK: - iOS Add to Collection Half-Sheet

#if !os(tvOS)
struct IOSAddToCollectionSheet: View {
    let contentId: String
    let itemTitle: String?

    @State private var model: AddToCollectionModel
    @State private var newCollectionName = ""
    @State private var nameEditGeneration = 0
    @State private var isFinishing = false
    @State private var hapticCount = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    init(contentId: String, itemTitle: String? = nil) {
        self.contentId = contentId
        self.itemTitle = itemTitle
        _model = State(initialValue: AddToCollectionModel(contentId: contentId))
    }

    var body: some View {
        NavigationStack {
            List {
                // Inline + New Collection creation row at the top
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                        TextField(AppLanguage.string(.collectionsCreateTitle, locale: locale), text: $newCollectionName)
                            .submitLabel(.done)
                            .onSubmit(createCollection)
                            .disabled(isFinishing || model.isCreating || model.hasUncertainCreation)
                        if !newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button(.collectionsGroupCreate, action: createCollection)
                                .font(.subheadline.weight(.semibold))
                                .disabled(isFinishing || model.isCreating || model.hasUncertainCreation)
                        }
                    }
                } header: {
                    if let itemTitle, !itemTitle.isEmpty {
                        Text(verbatim: itemTitle)
                    }
                }

                if let error = model.errorMessage {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(Color.siloSecondaryText)
                            if !model.hasLoaded || model.hasUncertainCreation || !model.unconfirmedCollectionIds.isEmpty {
                                Button(.commonRetry) {
                                    Task { await model.load() }
                                }
                                .font(.subheadline.weight(.semibold))
                                .disabled(isFinishing || model.hasPendingMutations || model.isLoading)
                            }
                        }
                    }
                }

                if model.isLoading || model.hasLoaded || !model.entries.isEmpty || model.errorMessage == nil {
                    Section(.homeAddRowSectionYourCollections) {
                        if model.isLoading && model.entries.isEmpty {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding(.vertical, 12)
                        } else if model.entries.isEmpty {
                            if model.hasLoaded {
                                Text(.collectionsAddToEmptyBody)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.siloSecondaryText)
                            } else {
                                Button(.commonRetry) {
                                    Task { await model.load() }
                                }
                                .disabled(isFinishing || model.hasPendingMutations || model.isLoading)
                            }
                        } else {
                            ForEach(model.entries) { entry in
                                let isUnconfirmed = model.unconfirmedCollectionIds.contains(entry.id)
                                let iconName: String = {
                                    if isUnconfirmed { return "exclamationmark.triangle" }
                                    switch entry.containsItem {
                                    case true?: return "checkmark.circle.fill"
                                    case false?: return "circle"
                                    case nil: return "plus.circle"
                                    }
                                }()
                                let iconColor: Color = {
                                    if isUnconfirmed { return .siloSecondaryText }
                                    switch entry.containsItem {
                                    case true?: return .green
                                    case false?: return .siloSecondaryText
                                    case nil: return .accentColor
                                    }
                                }()
                                Button {
                                    hapticCount += 1
                                    model.startToggle(collectionId: entry.id)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: iconName)
                                            .font(.title3)
                                            .foregroundStyle(iconColor)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(verbatim: entry.collection.name)
                                                .font(.body.weight(.medium))
                                                .foregroundStyle(Color.siloOnSurface)
                                            Text(.collectionsItemCount(count: entry.itemCount, LocaleFormat.groupedCount(entry.itemCount, locale: locale)))
                                                .font(.caption)
                                                .foregroundStyle(Color.siloSecondaryText)
                                        }

                                        Spacer()

                                        if model.busyCollectionIds.contains(entry.id) {
                                            ProgressView()
                                                .controlSize(.small)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .opacity(isUnconfirmed ? 0.55 : 1)
                                }
                                .buttonStyle(.plain)
                                .disabled(isFinishing || model.busyCollectionIds.contains(entry.id) || isUnconfirmed)
                                .accessibilityValue(
                                    isUnconfirmed
                                        ? Text(.detailUnknown)
                                        : (entry.containsItem.map { Text($0 ? LocalizedStringResource.detailActionOn : .detailActionOff) }
                                            ?? Text(.collectionsAddToMenuAction))
                                )
                                .accessibilityAddTraits(!isUnconfirmed && entry.containsItem == true ? [.isSelected] : [])
                            }
                            if !model.hasLoaded && !model.isLoading && model.errorMessage == nil {
                                Button(.commonRetry) {
                                    Task { await model.load() }
                                }
                                .disabled(isFinishing || model.hasPendingMutations)
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
            .navigationTitle(Text(.collectionsAddToTitle))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard !isFinishing else { return }
                        isFinishing = true
                        Task {
                            let settled = await model.waitForPendingMutations()
                            isFinishing = false
                            if settled {
                                dismiss()
                            }
                        }
                    } label: {
                        if isFinishing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(.commonDone)
                        }
                    }
                    .disabled(isFinishing)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(model.hasPendingMutations || isFinishing)
        .onChange(of: newCollectionName) { _, _ in
            nameEditGeneration += 1
        }
        .task {
            await model.load()
        }
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: hapticCount)
        #endif
    }

    private func createCollection() {
        guard !isFinishing else { return }
        let name = newCollectionName
        let capturedGeneration = nameEditGeneration
        let task = model.startCreateAndAdd(name: name)
        Task {
            let result = await task.value
            switch result {
            case .createdAndAdded:
                hapticCount += 1
                if nameEditGeneration == capturedGeneration {
                    newCollectionName = ""
                }
            case .createdOnly, .uncertain:
                // Either the collection now exists in the list below or the POST
                // outcome was uncertain and reconciled; clear the field so tapping
                // Create again cannot post a duplicate collection.
                if nameEditGeneration == capturedGeneration {
                    newCollectionName = ""
                }
            case .failed:
                break
            }
        }
    }
}
#endif
