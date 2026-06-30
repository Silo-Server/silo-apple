import SwiftUI

/// Full-facet filter sheet. Edits a draft `CatalogFilterState`; the apply
/// button shows a live result count and commits the draft to the view model.
struct FilterView: View {
    let viewModel: BrowseViewModel

    @State private var draft: CatalogFilterState
    @State private var preserve: Bool
    @State private var liveCount: Int?
    @State private var isCounting = false
    @State private var previewTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    init(viewModel: BrowseViewModel) {
        self.viewModel = viewModel
        _draft = State(initialValue: viewModel.filterState)
        _preserve = State(initialValue: viewModel.preserveEnabled)
    }

    private var hasProfile: Bool { AuthService.shared.profileId?.isEmpty == false }

    private var resultNoun: String {
        switch viewModel.mediaType {
        case .audiobook: return "audiobooks"
        case .series: return "shows"
        case .movie: return "items"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ContinuumTheme.largePadding) {
                    matchSection
                    ForEach(CatalogFacet.available(for: viewModel.mediaType), id: \.self) { facet in
                        facetSection(facet)
                    }
                }
                .padding(ContinuumTheme.padding)
            }
            .continuumBackground()
            .navigationTitle("Filter")
            .continuumNavigationTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { draft.resetFilters() }
                        .foregroundColor(.continuumSecondaryText)
                        .disabled(draft.isDefault)
                }
            }
            .continuumNavigationBarSurfaceBackground()
            .safeAreaInset(edge: .bottom) { footer }
        }
        .presentationDetents([.medium, .large])
        .task {
            await viewModel.loadFacetsIfNeeded()
            schedulePreview()
        }
        .onChange(of: draft) { _, _ in schedulePreview() }
    }

    // MARK: - Match all/any

    private var matchSection: some View {
        HStack(spacing: 12) {
            Text("Match")
                .font(.continuumHeadline)
                .foregroundColor(.continuumOnSurface)
            HStack(spacing: 2) {
                matchOption("All", isOn: draft.matchAll) { draft.matchAll = true }
                matchOption("Any", isOn: !draft.matchAll) { draft.matchAll = false }
            }
            .padding(2)
            .background(Capsule().fill(Color.continuumSurfaceElevated))
            Spacer(minLength: 0)
        }
    }

    private func matchOption(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.continuumCaption)
                .foregroundColor(isOn ? .continuumBackground : .continuumSecondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(isOn ? Color.continuumOnSurface : Color.clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Facet section

    @ViewBuilder
    private func facetSection(_ facet: CatalogFacet) -> some View {
        let options = valueOptions(for: facet)
        if !options.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(facet.title)
                    .font(.continuumHeadline)
                    .foregroundColor(.continuumOnSurface)
                FlowLayout(spacing: 8) {
                    ForEach(options, id: \.value) { option in
                        chipButton(label: option.label, isSelected: draft.isSelected(facet, value: option.value)) {
                            draft.toggle(facet, value: option.value)
                        }
                    }
                }
            }
        }
    }

    /// (value, label) options for a facet — fixed vocab for derived facets,
    /// server vocab otherwise.
    private func valueOptions(for facet: CatalogFacet) -> [(value: String, label: String)] {
        (viewModel.facets ?? CatalogFacets()).optionPairs(for: facet, hasProfile: hasProfile)
    }

    // MARK: - Footer (preserve + apply)

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().background(Color.continuumDivider)
            preserveRow
                .padding(.horizontal, ContinuumTheme.padding)
                .padding(.top, 12)
            Button {
                let committed = draft
                dismiss()
                Task { await viewModel.apply(committed) }
            } label: {
                Text(applyTitle)
                    .font(.continuumBody.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.continuumOnSurface, in: RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius))
                    .foregroundColor(.continuumBackground)
            }
            .buttonStyle(.plain)
            .padding(ContinuumTheme.padding)
        }
        .background(.regularMaterial)
    }

    private var preserveRow: some View {
        Toggle(isOn: $preserve) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Preserve sort & filters")
                    .font(.continuumBody)
                    .foregroundColor(.continuumOnSurface)
                Text("Reopen this library exactly as you left it")
                    .font(.continuumCaption)
                    .foregroundColor(.continuumSecondaryText)
            }
        }
        .tint(Color.continuumOnSurface)
        .onChange(of: preserve) { _, newValue in
            viewModel.setPreserveEnabled(newValue)
        }
    }

    private var applyTitle: String {
        guard let liveCount else { return isCounting ? "Counting…" : "Show results" }
        return "Show \(liveCount.formatted()) \(resultNoun)"
    }

    // MARK: - Live count

    private func schedulePreview() {
        previewTask?.cancel()
        isCounting = true
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let count = await viewModel.resultCount(for: draft)
            guard !Task.isCancelled else { return }
            liveCount = count
            isCounting = false
        }
    }

    // MARK: - Chip

    private func chipButton(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.continuumCaption)
                .foregroundColor(isSelected ? Color.continuumBackground : .continuumSecondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.continuumOnSurface : Color.continuumSurfaceElevated)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - FlowLayout

/// Simple wrapping layout for filter chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private struct LayoutResult {
        var size: CGSize
        var positions: [CGPoint]
    }

    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return LayoutResult(
            size: CGSize(width: maxX, height: y + rowHeight),
            positions: positions
        )
    }
}
