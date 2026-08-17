import SwiftUI

/// Plex-style filter sheet. The top level is a compact, instantly-rendered
/// list: quick one-tap toggles (watch status, dynamic range) followed by
/// drill-in category rows. Each category pushes a lazy value picker so the
/// sheet never has to lay out every facet's values up front. Edits a draft
/// `CatalogFilterState` and commits it to the view model when the sheet is
/// dismissed — no apply button, the results just update on close.
struct FilterView: View {
    let viewModel: BrowseViewModel

    @State private var draft: CatalogFilterState
    @State private var preserve: Bool

    init(viewModel: BrowseViewModel) {
        self.viewModel = viewModel
        _draft = State(initialValue: viewModel.filterState)
        _preserve = State(initialValue: viewModel.preserveEnabled)
    }

    private var hasProfile: Bool { AuthService.shared.profileId?.isEmpty == false }

    var body: some View {
        NavigationStack {
            List {
                quickSection
                categoriesSection
                matchSection
                preserveSection
            }
            .listStyle(.plain)
            .filterScrollContentBackgroundHidden()
            .environment(\.defaultMinListRowHeight, 50)
            .siloBackground()
            .navigationTitle("Filter")
            .siloNavigationTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { draft.resetFilters() }
                        .foregroundColor(.siloSecondaryText)
                        .disabled(!draft.canResetFilters)
                }
            }
            .siloNavigationBarSurfaceBackground()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await viewModel.loadFacetsIfNeeded() }
        .onDisappear { commitIfChanged() }
    }

    /// Apply the accumulated draft once, when the sheet closes. Skipped when
    /// nothing changed so we don't trigger a redundant reload.
    private func commitIfChanged() {
        guard draft != viewModel.filterState else { return }
        let committed = draft
        Task { await viewModel.apply(committed) }
    }

    // MARK: - Quick toggles (watch status + dynamic range)

    /// One-tap boolean/single-select rows, surfaced as a flat group at the top
    /// like Plex's "Unwatched / HDR" cluster.
    private struct QuickToggle: Identifiable {
        let facet: CatalogFacet
        let value: String
        let label: String
        var id: String { "\(facet.rawValue):\(value)" }
    }

    private var quickToggles: [QuickToggle] {
        let available = CatalogFacet.available(for: viewModel.mediaType)
        var result: [QuickToggle] = []
        for facet in [CatalogFacet.watchStatus, .dynamicRange] where available.contains(facet) {
            for pair in valueOptions(for: facet) {
                result.append(QuickToggle(facet: facet, value: pair.value, label: pair.label))
            }
        }
        return result
    }

    @ViewBuilder
    private var quickSection: some View {
        let toggles = quickToggles
        if !toggles.isEmpty {
            Section {
                ForEach(toggles) { toggle in
                    checkRow(label: toggle.label,
                             isOn: draft.isSelected(toggle.facet, value: toggle.value)) {
                        draft.toggle(toggle.facet, value: toggle.value)
                    }
                }
            }
        }
    }

    // MARK: - Categories (drill-in value pickers)

    /// Multi-value facets that get their own pushed picker. Excludes the quick
    /// facets and any facet whose option list resolves empty.
    private var categoryFacets: [CatalogFacet] {
        CatalogFacet.available(for: viewModel.mediaType)
            .filter { $0 != .watchStatus && $0 != .dynamicRange }
            .filter { !valueOptions(for: $0).isEmpty }
    }

    @ViewBuilder
    private var categoriesSection: some View {
        let facets = categoryFacets
        if !facets.isEmpty {
            Section {
                ForEach(facets, id: \.self) { facet in
                    categoryRow(facet)
                }
            }
        }
    }

    private func categoryRow(_ facet: CatalogFacet) -> some View {
        NavigationLink {
            FacetValuePicker(facet: facet, options: valueOptions(for: facet), draft: $draft)
        } label: {
            HStack {
                Text(facet.title)
                    .font(.siloBody)
                    .foregroundColor(.siloOnSurface)
                Spacer(minLength: 12)
                if let summary = selectionSummary(facet) {
                    Text(summary)
                        .font(.siloCaption)
                        .foregroundColor(.siloSecondaryText)
                        .lineLimit(1)
                }
            }
        }
        .listRowBackground(Color.clear)
        .filterListRowSeparatorTint(.siloDivider)
    }

    /// Trailing summary for a category row: the single value's label, or
    /// "First +N" once several are selected.
    private func selectionSummary(_ facet: CatalogFacet) -> String? {
        let selected = draft.selectedValues(facet)
        guard !selected.isEmpty else { return nil }
        let labels = selected.sorted().map { CatalogFilterState.chipLabel(facet: facet, value: $0) }
        guard let first = labels.first else { return nil }
        return labels.count == 1 ? first : "\(first) +\(labels.count - 1)"
    }

    // MARK: - Match all/any

    private var matchSection: some View {
        Section {
            HStack {
                Text("Match")
                    .font(.siloBody)
                    .foregroundColor(.siloOnSurface)
                Spacer(minLength: 12)
                HStack(spacing: 2) {
                    matchOption("All", isOn: draft.matchAll) { draft.matchAll = true }
                    matchOption("Any", isOn: !draft.matchAll) { draft.matchAll = false }
                }
                .padding(2)
                .background(Capsule().fill(Color.siloSurfaceElevated))
            }
            .listRowBackground(Color.clear)
            .filterListRowSeparatorHidden()
        } footer: {
            Text(draft.matchAll
                 ? "Results match every selected filter."
                 : "Results match any selected filter.")
                .font(.siloCaption)
                .foregroundColor(.siloSecondaryText)
        }
    }

    private func matchOption(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.siloCaption)
                .foregroundColor(isOn ? .siloBackground : .siloSecondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(isOn ? Color.siloOnSurface : Color.clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Preserve

    private var preserveSection: some View {
        Section {
            Toggle(isOn: $preserve) {
                Text("Preserve sort & filters")
                    .font(.siloBody)
                    .foregroundColor(.siloOnSurface)
            }
            .tint(Color.siloAccent)
            .listRowBackground(Color.clear)
            .filterListRowSeparatorHidden()
            .onChange(of: preserve) { _, newValue in
                viewModel.setPreserveEnabled(newValue)
            }
        } footer: {
            Text("Reopen this library exactly as you left it")
                .font(.siloCaption)
                .foregroundColor(.siloSecondaryText)
        }
    }

    // MARK: - Rows

    /// A tappable row that shows a trailing checkmark when active. Used for the
    /// quick toggles and inside the value picker.
    private func checkRow(label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.siloBody)
                    .foregroundColor(.siloOnSurface)
                Spacer(minLength: 12)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.siloBody.weight(.semibold))
                        .foregroundColor(.siloOnSurface)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .filterListRowSeparatorTint(.siloDivider)
    }

    /// (value, label) options for a facet — fixed vocab for derived facets,
    /// server vocab otherwise.
    private func valueOptions(for facet: CatalogFacet) -> [(value: String, label: String)] {
        (viewModel.facets ?? CatalogFacets()).optionPairs(for: facet, hasProfile: hasProfile)
    }
}

// MARK: - Facet value picker

/// Pushed list of a single facet's values, multi-select with checkmarks. Long
/// vocabularies (genres, studios, languages) get an inline search field. Edits
/// the shared draft binding so the parent commits the combined result on close.
private struct FacetValuePicker: View {
    let facet: CatalogFacet
    let options: [(value: String, label: String)]
    @Binding var draft: CatalogFilterState
    @State private var query = ""

    private var filtered: [(value: String, label: String)] {
        guard !query.isEmpty else { return options }
        return options.filter { $0.label.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            ForEach(filtered, id: \.value) { option in
                Button {
                    draft.toggle(facet, value: option.value)
                } label: {
                    HStack {
                        Text(option.label)
                            .font(.siloBody)
                            .foregroundColor(.siloOnSurface)
                        Spacer(minLength: 12)
                        if draft.isSelected(facet, value: option.value) {
                            Image(systemName: "checkmark")
                                .font(.siloBody.weight(.semibold))
                                .foregroundColor(.siloOnSurface)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .filterListRowSeparatorTint(.siloDivider)
            }
        }
        .listStyle(.plain)
        .filterScrollContentBackgroundHidden()
        .environment(\.defaultMinListRowHeight, 50)
        .siloBackground()
        .navigationTitle(facet.title)
        .siloNavigationTitleDisplayMode(.inline)
        .siloNavigationBarSurfaceBackground()
        .toolbar {
            if !draft.selectedValues(facet).isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear") { draft.clear(facet) }
                        .foregroundColor(.siloSecondaryText)
                }
            }
        }
        .modifier(ConditionalSearchable(text: $query, isActive: options.count > 12))
    }
}

/// Adds a search field only for long value lists, so short fixed-vocab facets
/// (decade, content rating) don't carry a needless search bar.
private struct ConditionalSearchable: ViewModifier {
    @Binding var text: String
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
#if os(tvOS)
            content
#elseif os(macOS)
            // `.navigationBarDrawer` doesn't exist on macOS; the toolbar
            // placement is the native equivalent.
            content.searchable(text: $text, placement: .toolbar)
#else
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always))
#endif
        } else {
            content
        }
    }
}

private extension View {
    @ViewBuilder
    func filterScrollContentBackgroundHidden() -> some View {
#if os(tvOS)
        self
#else
        scrollContentBackground(.hidden)
#endif
    }

    @ViewBuilder
    func filterListRowSeparatorTint(_ color: Color) -> some View {
#if os(tvOS)
        self
#else
        listRowSeparatorTint(color)
#endif
    }

    @ViewBuilder
    func filterListRowSeparatorHidden() -> some View {
#if os(tvOS)
        self
#else
        listRowSeparator(.hidden)
#endif
    }
}

// MARK: - FlowLayout

/// Simple wrapping layout for filter chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let result = computeLayout(maxWidth: maxWidth, subviews: subviews)
        // Never report wider than we were offered — otherwise the single-row
        // intrinsic width inflates the enclosing ScrollView and pushes the
        // sheet past the screen edges.
        return CGSize(width: min(result.size.width, maxWidth), height: result.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(maxWidth: bounds.width, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private struct LayoutResult {
        var size: CGSize
        var positions: [CGPoint]
    }

    private func computeLayout(maxWidth: CGFloat, subviews: Subviews) -> LayoutResult {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                widestRow = max(widestRow, x - spacing) // x carries trailing spacing
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        widestRow = max(widestRow, x - spacing) // last row

        return LayoutResult(
            size: CGSize(width: max(0, widestRow), height: y + rowHeight),
            positions: positions
        )
    }
}
