#if os(tvOS)
import SwiftUI

/// `Collections` pill content of a library tab: a vertical grid of every
/// collection in the scoped library (Skyline §6.3). Pressing a card pushes
/// the existing collection detail screen.
struct TVLibraryCollectionsView: View {
    let library: Library
    /// Focus hand-down token from the shell — claims the first card on
    /// tab entry when this pill is the restored destination.
    var focusRequest: Int = 0
    /// Whether the top menu currently holds focus; deferred entry claims
    /// are dropped while the user is up in the menu.
    var isTopMenuFocused: Bool = false
    /// Boundary hand-up toward the pill row for the first visual grid row.
    let onMoveUp: (() -> Void)?

    @State private var collectionSections: [LibraryCollectionSection] = []
    @State private var isLoadingCollections = true
    @State private var uiCustomization = UICustomizationPreferences.shared

    @State private var hasPendingFocusClaim = false
    @State private var lastShellFocusRequest = 0
    @State private var contentFocusToken = 0
    @FocusState private var isEmptyContentFocused: Bool

    @Environment(AppRouter.self) private var router
    @Namespace private var collectionsFocusNamespace

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 44, pinnedViews: []) {
                Color.clear
                    .frame(height: ContinuumTheme.Skyline.libraryContentTopInset)

                gridContent
            }
            .padding(.bottom, ContinuumTheme.largePadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            guard collectionSections.isEmpty else { return }
            await loadCollections()
        }
        .onAppear { noteShellFocusRequest(focusRequest) }
        .onChange(of: focusRequest) { _, request in noteShellFocusRequest(request) }
        .onChange(of: collectionSections.isEmpty) { _, isEmpty in
            if !isEmpty, hasPendingFocusClaim {
                claimContentFocusIfReady()
            }
        }
    }

    @ViewBuilder
    private var gridContent: some View {
        if collectionSections.isEmpty {
            emptyContent
        } else {
            // Only the very first card of the first NON-EMPTY section
            // claims default focus when the tab appears. Skipping empty
            // sections matters: grouped responses can include groups with
            // no collections, and falling back to `collectionSections.first`
            // would leave the Collections pill without an initial focus
            // target on tvOS.
            let focusTarget = collectionSections
                .first(where: { !$0.collections.isEmpty })
            let firstSectionId = focusTarget?.id
            let firstCardId = focusTarget?.collections.first?.id
            let firstVisualRowIds = Set(
                focusTarget?.collections.prefix(resolvedColumnCount).map(\.id) ?? []
            )

            VStack(alignment: .leading, spacing: 44) {
                ForEach(collectionSections) { section in
                    VStack(alignment: .leading, spacing: 20) {
                        if !section.name.isEmpty {
                            // §6.3 mono group header — same grammar as the
                            // cascade/dropdown section headers, at grid scale.
                            Text(section.name.uppercased())
                                .font(.system(
                                    size: ContinuumTheme.Skyline.collectionGridGroupHeaderSize,
                                    design: .monospaced
                                ))
                                .tracking(ContinuumTheme.Skyline.collectionGridGroupHeaderSize * 0.26)
                                .foregroundColor(.continuumOnSurface.opacity(0.38))
                                .lineLimit(1)
                                .padding(.leading, ContinuumTheme.safePadding)
                        }
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(
                                    .flexible(),
                                    spacing: ContinuumTheme.Skyline.collectionGridColumnSpacing,
                                    alignment: .top
                                ),
                                count: resolvedColumnCount
                            ),
                            alignment: .leading,
                            spacing: ContinuumTheme.Skyline.collectionGridRowSpacing
                        ) {
                            ForEach(section.collections) { collection in
                                let isFirstOverall =
                                    section.id == firstSectionId && collection.id == firstCardId
                                let isInFirstVisualRow =
                                    section.id == firstSectionId
                                    && firstVisualRowIds.contains(collection.id)
                                TVCollectionCard(
                                    collection: collection,
                                    prefersDefaultFocus: isFirstOverall,
                                    defaultFocusNamespace: collectionsFocusNamespace,
                                    focusRequest: isFirstOverall ? contentFocusToken : 0,
                                    onMoveUp: isInFirstVisualRow ? onMoveUp : nil,
                                    action: {
                                        router.navigate(to: .libraryCollection(
                                            libraryId: library.id,
                                            collectionId: collection.id,
                                            title: collection.name,
                                            kind: collection.kind
                                        ))
                                    }
                                )
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.horizontal, ContinuumTheme.safePadding)
                    }
                }
            }
            .focusScope(collectionsFocusNamespace)
            .focusSection()
        }
    }

    private var emptyContent: some View {
        ZStack {
            if isLoadingCollections {
                Color.clear
            } else {
                EmptyStateView(
                    icon: "square.stack",
                    title: "No collections yet",
                    subtitle: "Collections created on the server will appear here."
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: 400)
        .contentShape(Rectangle())
        .focusable(true)
        .focused($isEmptyContentFocused)
        .focusEffectDisabled()
        .accessibilityLabel(isLoadingCollections ? "Loading collections" : "No collections yet")
        .onMoveCommand { direction in
            if direction == .up {
                onMoveUp?()
            }
        }
        .task(id: focusRequest) {
            guard !isTopMenuFocused else { return }
            await Task.yield()
            guard collectionSections.isEmpty, !isTopMenuFocused else { return }
            isEmptyContentFocused = true
        }
    }

    // MARK: - Focus hand-down

    private func noteShellFocusRequest(_ request: Int) {
        guard request > 0, request != lastShellFocusRequest else { return }
        lastShellFocusRequest = request
        claimContentFocusIfReady()
    }

    private func claimContentFocusIfReady() {
        guard collectionSections.contains(where: { !$0.collections.isEmpty }) else {
            hasPendingFocusClaim = true
            return
        }
        if hasPendingFocusClaim, isTopMenuFocused {
            hasPendingFocusClaim = false
            return
        }
        hasPendingFocusClaim = false
        contentFocusToken += 1
    }

    // MARK: - Data

    private func loadCollections() async {
        isLoadingCollections = true
        do {
            let response = try await ContinuumAPI.shared.libraryCollections(libraryId: library.id)
            collectionSections = response.resolvedSections
        } catch {
            collectionSections = []
        }
        isLoadingCollections = false
    }

    private var resolvedColumnCount: Int {
        let standard = ContinuumTheme.Skyline.collectionGridColumnCount
        switch uiCustomization.cardPresentation.posterSize {
        case .compact: return standard + 1
        case .standard: return standard
        case .large: return max(3, standard - 1)
        }
    }
}

// MARK: - Collection card

/// Attaches an Up-move handler only when one is supplied, so lower grid rows
/// do not intercept the command the focus engine needs to move upward.
private struct TVCollectionCardMoveUpHandler: ViewModifier {
    let onMoveUp: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let onMoveUp {
            content.onMoveCommand { direction in
                if direction == .up {
                    onMoveUp()
                }
            }
        } else {
            content
        }
    }
}

/// Grid wrapper around `TVCollectionPosterCard` (§6.3) that carries the
/// Collections pill's focus machinery: the programmatic entry kick, the
/// first-row hand-up to the pill row, and the recycle guard. The visual
/// is the shared poster card; this struct owns only focus plumbing.
private struct TVCollectionCard: View {
    let collection: LibraryCollection
    var prefersDefaultFocus: Bool = false
    var defaultFocusNamespace: Namespace.ID? = nil
    /// Programmatic focus kick: when this becomes non-zero (the Collections
    /// pill was restored on tab entry) focus jumps to this card, since
    /// `prefersDefaultFocus` alone doesn't fire when the scope isn't being
    /// entered by the engine.
    var focusRequest: Int = 0
    /// Supplied to every card in the first visual grid row: Up returns focus
    /// to the pill row. Lower rows omit it so native grid movement still walks
    /// through every intervening collection row.
    var onMoveUp: (() -> Void)? = nil
    let action: () -> Void

    /// Drives the programmatic entry kick through the poster card's external
    /// focus binding. A single-card binding keyed on the collection id is
    /// enough — only the first card is ever handed a non-zero token.
    @FocusState private var focusedId: String?
    /// Last hand-down token applied, so each token claims focus exactly once.
    /// The card lives in a `LazyVGrid`; without the guard, `onAppear` re-fires
    /// when the first card is recycled back into view on scroll-up and would
    /// yank focus away from the row the user was navigating.
    @State private var lastAppliedFocusRequest = 0

    var body: some View {
        TVCollectionPosterCard(
            collection: collection,
            action: action,
            prefersDefaultFocus: prefersDefaultFocus,
            defaultFocusNamespace: defaultFocusNamespace,
            focusBinding: $focusedId,
            focusContentId: collection.id
        )
        .onAppear { applyFocusRequest(focusRequest) }
        .onChange(of: focusRequest) { _, request in applyFocusRequest(request) }
        .modifier(TVCollectionCardMoveUpHandler(onMoveUp: onMoveUp))
    }

    private func applyFocusRequest(_ request: Int) {
        guard request > 0, request != lastAppliedFocusRequest else { return }
        lastAppliedFocusRequest = request
        focusedId = collection.id
    }
}
#endif
