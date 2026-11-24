import SwiftUI

// MARK: - Collection Pin & Placement Controls (iOS + tvOS)

/// One-tap `Pin to Home` pill + `Where It Shows` menu shown right beside
/// `Shuffle` on `CollectionDetailView` and `LibraryCollectionDetailView`.
struct CollectionPinActionBar: View {
    let collectionId: String
    let title: String
    let isUserCollection: Bool
    var sourceLibraryId: Int? = nil

    @State private var model: CollectionPlacementModel
    @State private var hapticCount = 0

    init(
        collectionId: String,
        title: String,
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
        #else
        iosControls
            .task(id: collectionId) { await model.load() }
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
                    Text(model.isPinnedOnHome ? "On Home" : "Pin to Home")
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
            .disabled(model.isUpdatingHome)

            Menu {
                Section("Where It Shows") {
                    Button {
                        hapticCount += 1
                        Task { await model.toggleHomePin() }
                    } label: {
                        Label(
                            "Home",
                            systemImage: model.isPinnedOnHome ? "checkmark.circle.fill" : "circle"
                        )
                    }

                    ForEach(model.libraryPlacements) { placement in
                        Button {
                            hapticCount += 1
                            Task { await model.toggleLibraryPin(libraryId: placement.libraryId) }
                        } label: {
                            Label(
                                placement.libraryName,
                                systemImage: placement.isPinned ? "checkmark.circle.fill" : "circle"
                            )
                        }
                    }
                }

                if model.isUserCollection && model.canToggleShare {
                    Section("Household") {
                        Button {
                            hapticCount += 1
                            Task { await model.toggleShared() }
                        } label: {
                            Label(
                                "Share with Household Profiles",
                                systemImage: model.isShared ? "checkmark.circle.fill" : "person.2"
                            )
                        }
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
            .accessibilityLabel("Where It Shows")
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
                    Text(model.isPinnedOnHome ? "On Home" : "Pin to Home")
                        .font(.system(size: 22, weight: .semibold))
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .disabled(model.isUpdatingHome)

            TVCircleMenuButton(
                icon: "ellipsis",
                title: "Where It Shows",
                accessibilityLabel: "Where It Shows",
                items: {
                    var items: [TVActionPopoverItem] = [
                        TVActionPopoverItem(
                            id: "home",
                            title: "Home",
                            detail: model.isPinnedOnHome ? "Pinned on Home" : "Not on Home",
                            systemImage: "house",
                            isSelected: model.isPinnedOnHome,
                            isEnabled: !model.isUpdatingHome
                        ),
                    ]
                    for placement in model.libraryPlacements {
                        items.append(TVActionPopoverItem(
                            id: "lib:\(placement.libraryId)",
                            title: placement.libraryName,
                            detail: placement.isPinned ? "Pinned on Library page" : nil,
                            systemImage: "film.stack",
                            isSelected: placement.isPinned,
                            isEnabled: !model.updatingLibraryIds.contains(placement.libraryId)
                        ))
                    }
                    if model.isUserCollection && model.canToggleShare {
                        items.append(TVActionPopoverItem(
                            id: "share",
                            title: "Share with Profiles",
                            detail: model.isShared ? "Visible to household profiles" : "Only this profile",
                            systemImage: "person.2",
                            isSelected: model.isShared,
                            isEnabled: !model.isUpdatingShare,
                            startsSection: true
                        ))
                    }
                    return items
                },
                onSelect: { item in
                    if item.id == "home" {
                        Task { await model.toggleHomePin() }
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
    @State private var hapticCount = 0
    @Environment(\.dismiss) private var dismiss

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
                        TextField("New Collection", text: $newCollectionName)
                            .submitLabel(.done)
                            .onSubmit(createCollection)
                        if !newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("Create", action: createCollection)
                                .font(.subheadline.weight(.semibold))
                                .disabled(model.isCreating)
                        }
                    }
                } header: {
                    if let itemTitle, !itemTitle.isEmpty {
                        Text(itemTitle)
                    }
                }

                if let error = model.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(Color.siloSecondaryText)
                    }
                }

                Section("Your Collections") {
                    if model.isLoading && model.entries.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 12)
                    } else if model.entries.isEmpty {
                        Text("No personal collections yet. Create one above.")
                            .font(.subheadline)
                            .foregroundStyle(Color.siloSecondaryText)
                    } else {
                        ForEach(model.entries) { entry in
                            Button {
                                hapticCount += 1
                                Task { await model.toggle(collectionId: entry.id) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: entry.containsItem ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(entry.containsItem ? Color.green : Color.siloSecondaryText)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.collection.name)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(Color.siloOnSurface)
                                        Text(entry.itemCount == 1 ? "1 item" : "\(entry.itemCount) items")
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
                            }
                            .buttonStyle(.plain)
                            .disabled(model.busyCollectionIds.contains(entry.id))
                        }
                    }
                }
            }
            #if os(macOS)
            .settingsListChrome()
            #else
            .siloGroupedListStyle()
            #endif
            .navigationTitle("Add to Collection")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            await model.load()
        }
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: hapticCount)
        #endif
    }

    private func createCollection() {
        let name = newCollectionName
        Task {
            let ok = await model.createAndAdd(name: name)
            if ok {
                hapticCount += 1
                newCollectionName = ""
            }
        }
    }
}
#endif
