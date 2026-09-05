#if os(tvOS)
import SwiftUI

/// Which browse panel is open over the grid.
enum TVBrowsePanel: Hashable {
    case sort
    case filter
}

// MARK: - Control row

/// Sort + Filter pills above the grid. A single `.focusSection()` so the grid
/// below it is reachable with d-pad Down and the top bar with Up.
struct TVBrowseControlRow: View {
    let sortLabel: String
    let sortDirection: String
    let filterCount: Int
    var focusRequest: Int = 0
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil
    let onSort: () -> Void
    let onFilter: () -> Void

    @FocusState private var focusedControl: TVBrowseControlFocus?
    @State private var lastAppliedFocusRequest = 0

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onSort) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text("Sort · \(sortLabel)")
                    Text(sortDirection)
                        .foregroundColor(.siloSecondaryText)
                }
            }
            .buttonStyle(TVBrowseControlPillStyle())
            .focused($focusedControl, equals: .sort)
            .onMoveCommand { direction in
                handleMove(from: .sort, direction)
            }

            Button(action: onFilter) {
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text("Filter")
                    if filterCount > 0 {
                        Text("\(filterCount)")
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.25)))
                    }
                }
            }
            .buttonStyle(TVBrowseControlPillStyle(active: filterCount > 0))
            .focused($focusedControl, equals: .filter)
            .onMoveCommand { direction in
                handleMove(from: .filter, direction)
            }

            Spacer(minLength: 0)
        }
        .font(.system(size: 24, weight: .medium))
        .focusSection()
        .onAppear { applyFocusRequest(focusRequest) }
        .onChange(of: focusRequest) { _, request in applyFocusRequest(request) }
    }

    private func applyFocusRequest(_ request: Int) {
        guard request > 0, request != lastAppliedFocusRequest else { return }
        lastAppliedFocusRequest = request
        focusedControl = .sort
    }

    private func handleMove(from control: TVBrowseControlFocus, _ direction: MoveCommandDirection) {
        switch direction {
        case .up:
            onMoveUp?()
        case .down:
            onMoveDown?()
        case .left where control == .filter:
            focusedControl = .sort
        case .right where control == .sort:
            focusedControl = .filter
        default:
            break
        }
    }
}

private enum TVBrowseControlFocus: Hashable {
    case sort
    case filter
}

// MARK: - Sort panel

struct TVBrowseSortPanel: View {
    let mediaType: BrowseMediaType
    let current: CatalogSortKey
    let order: CatalogSortOrder
    let onSelect: (CatalogSortKey) -> Void
    let onClose: () -> Void

    @Environment(\.resetFocus) private var resetFocus
    @Namespace private var sortFocusScope
    @FocusState private var focusedSort: CatalogSortKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SORT BY")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundColor(.siloSecondaryText)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)

            ForEach(CatalogSortKey.available(for: mediaType), id: \.self) { key in
                Button { onSelect(key) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "checkmark")
                            .opacity(key == current ? 1 : 0)
                        Text(key.label)
                        Spacer(minLength: 0)
                        if key == current {
                            Text(key.directionLabel(for: order))
                                .foregroundColor(.siloSecondaryText)
                            Image(systemName: order == .asc ? "arrow.up" : "arrow.down")
                        }
                    }
                    .font(.system(size: 26))
                }
                .buttonStyle(TVBrowsePanelRowStyle())
                .focused($focusedSort, equals: key)
            }
        }
        .padding(14)
        .frame(width: 460)
        .modifier(TVSkylinePanelChrome())
        .focusScope(sortFocusScope)
        .focusSection()
        .onExitCommand(perform: onClose)
        .onAppear { claimFocus() }
        .onChange(of: current) { _, _ in claimFocus() }
    }

    private var focusTarget: CatalogSortKey? {
        let keys = CatalogSortKey.available(for: mediaType)
        if keys.contains(current) { return current }
        return keys.first
    }

    private func claimFocus() {
        focusedSort = focusTarget
        Task { @MainActor in
            await Task.yield()
            resetFocus(in: sortFocusScope)
            focusedSort = focusTarget
        }
    }
}

// MARK: - Filter panel (list → values)

struct TVBrowseFilterPanel: View {
    let mediaType: BrowseMediaType
    let facets: CatalogFacets
    let onApply: (CatalogFilterState) -> Void
    let onPreserveChange: (Bool) -> Void
    let onClose: () -> Void

    private enum Screen: Hashable {
        case filters
        case values(CatalogFacet)
    }

    private enum FocusTarget: Hashable {
        case facet(CatalogFacet)
        case back
        case value(CatalogFacet, String)
        case clear(CatalogFacet)
        case matchAll
        case matchAny
        case preserve
        case reset
        case done
    }

    @Environment(\.resetFocus) private var resetFocus
    @Namespace private var panelFocusScope

    @State private var draft: CatalogFilterState
    @State private var preserve: Bool
    @State private var screen: Screen = .filters
    @State private var lastFacet: CatalogFacet?
    @FocusState private var focusedTarget: FocusTarget?

    private let availableFacets: [CatalogFacet]

    init(mediaType: BrowseMediaType,
         facets: CatalogFacets,
         initial: CatalogFilterState,
         preserveEnabled: Bool,
         onApply: @escaping (CatalogFilterState) -> Void,
         onPreserveChange: @escaping (Bool) -> Void,
         onClose: @escaping () -> Void) {
        self.mediaType = mediaType
        self.facets = facets
        self.onApply = onApply
        self.onPreserveChange = onPreserveChange
        self.onClose = onClose
        let visible = CatalogFacet.available(for: mediaType)
            .filter { !facets.optionPairs(for: $0, hasProfile: Self.hasProfile).isEmpty }
        self.availableFacets = visible
        _draft = State(initialValue: initial)
        _preserve = State(initialValue: preserveEnabled)
        _lastFacet = State(initialValue: visible.first)
    }

    private static var hasProfile: Bool { AuthService.shared.profileId?.isEmpty == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader

            Divider()
                .overlay(Color.siloDivider)
                .padding(.vertical, 12)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    switch screen {
                    case .filters:
                        filterList
                    case .values(let facet):
                        valueList(for: facet)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(22)
        .frame(width: 680, height: 680, alignment: .topLeading)
        .modifier(TVSkylinePanelChrome())
        .focusScope(panelFocusScope)
        .focusSection()
        .onExitCommand(perform: handleExit)
        .onMoveCommand { direction in
            if direction == .left, case .values = screen {
                showFilterList()
            }
        }
        .onChange(of: screen) { _, _ in claimFocus(defaultFocusTarget) }
        .onAppear { claimFocus(defaultFocusTarget) }
    }

    // MARK: Header

    private var panelHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headerEyebrow)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundColor(.siloSecondaryText)

            Text(headerTitle)
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.siloOnSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerEyebrow: String {
        switch screen {
        case .filters: return "FILTER BY"
        case .values: return "FILTER"
        }
    }

    private var headerTitle: String {
        switch screen {
        case .filters: return "Filters"
        case .values(let facet): return facet.title
        }
    }

    // MARK: Filter list

    @ViewBuilder
    private var filterList: some View {
        if availableFacets.isEmpty {
            Text("No filters available")
                .font(.system(size: 24))
                .foregroundColor(.siloSecondaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
        } else {
            ForEach(availableFacets, id: \.self) { facet in
                filterRow(for: facet)
            }
        }

        sectionHeader("MATCH")
        matchRow(title: "All selected filters", isSelected: draft.matchAll, focus: .matchAll) {
            draft.matchAll = true
        }
        matchRow(title: "Any selected filter", isSelected: !draft.matchAll, focus: .matchAny) {
            draft.matchAll = false
        }

        sectionHeader("OPTIONS")
        preserveRow
        resetRow
        doneRow
    }

    private func filterRow(for facet: CatalogFacet) -> some View {
        Button { showValues(for: facet) } label: {
            HStack(spacing: 14) {
                Text(facet.title)
                    .lineLimit(1)

                Spacer(minLength: 16)

                Text(facetSummary(facet))
                    .opacity(0.68)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .semibold))
                    .opacity(0.55)
            }
            .font(.system(size: 25))
        }
        .buttonStyle(TVBrowsePanelRowStyle())
        .focused($focusedTarget, equals: .facet(facet))
    }

    private func matchRow(title: String, isSelected: Bool, focus: FocusTarget, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 23))
        }
        .buttonStyle(TVBrowsePanelRowStyle())
        .focused($focusedTarget, equals: focus)
    }

    private var preserveRow: some View {
        Button {
            preserve.toggle()
            onPreserveChange(preserve)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: preserve ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22, weight: .semibold))
                Text("Preserve sort & filters")
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 23))
        }
        .buttonStyle(TVBrowsePanelRowStyle())
        .focused($focusedTarget, equals: .preserve)
    }

    private var resetRow: some View {
        Button {
            draft.resetFilters()
            claimFocus(.done)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 22, weight: .semibold))
                Text("Reset filters")
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 23))
        }
        .buttonStyle(TVBrowsePanelRowStyle())
        .focused($focusedTarget, equals: .reset)
        .disabled(!draft.canResetFilters)
        .opacity(draft.canResetFilters ? 1 : 0.45)
    }

    private var doneRow: some View {
        Button(action: commitAndClose) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .semibold))
                Text("Done")
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 25, weight: .semibold))
        }
        .buttonStyle(TVBrowsePanelRowStyle())
        .focused($focusedTarget, equals: .done)
    }

    // MARK: Value list

    @ViewBuilder
    private func valueList(for facet: CatalogFacet) -> some View {
        Button(action: showFilterList) {
            HStack(spacing: 14) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                Text("All filters")
                Spacer(minLength: 0)
            }
            .font(.system(size: 24))
        }
        .buttonStyle(TVBrowsePanelRowStyle())
        .focused($focusedTarget, equals: .back)

        if !draft.selectedValues(facet).isEmpty {
            clearRow(for: facet)
        }

        ForEach(valueOptions(for: facet), id: \.value) { option in
            valueRow(for: facet, option: option)
        }
    }

    private func clearRow(for facet: CatalogFacet) -> some View {
        Button {
            draft.clear(facet)
            claimFocus(defaultValueFocus(for: facet))
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 22, weight: .semibold))
                Text("Clear \(facet.title)")
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 23))
        }
        .buttonStyle(TVBrowsePanelRowStyle())
        .focused($focusedTarget, equals: .clear(facet))
    }

    private func valueRow(for facet: CatalogFacet, option: (value: String, label: String)) -> some View {
        let isSelected = draft.isSelected(facet, value: option.value)
        return Button {
            draft.toggle(facet, value: option.value)
            claimFocus(.value(facet, option.value))
        } label: {
            HStack(spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                Text(option.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .font(.system(size: 24))
        }
        .buttonStyle(TVBrowsePanelRowStyle())
        .focused($focusedTarget, equals: .value(facet, option.value))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .tracking(2)
            .foregroundColor(.siloSecondaryText)
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 6)
    }

    // MARK: Actions

    private func facetSummary(_ facet: CatalogFacet) -> String {
        let values = draft.selectedValues(facet)
        guard !values.isEmpty else { return "Any" }
        if values.count == 1, let only = values.first {
            return CatalogFilterState.chipLabel(facet: facet, value: only)
        }
        return "\(values.count) selected"
    }

    private func valueOptions(for facet: CatalogFacet) -> [(value: String, label: String)] {
        facets.optionPairs(for: facet, hasProfile: Self.hasProfile)
    }

    private var defaultFocusTarget: FocusTarget? {
        switch screen {
        case .filters:
            if let lastFacet, availableFacets.contains(lastFacet) {
                return .facet(lastFacet)
            }
            return availableFacets.first.map(FocusTarget.facet) ?? .done
        case .values(let facet):
            return defaultValueFocus(for: facet)
        }
    }

    private func defaultValueFocus(for facet: CatalogFacet) -> FocusTarget {
        let selected = draft.selectedValues(facet)
        let options = valueOptions(for: facet)
        if let selectedOption = options.first(where: { selected.contains($0.value) }) {
            return .value(facet, selectedOption.value)
        }
        if let first = options.first {
            return .value(facet, first.value)
        }
        return .back
    }

    private func showValues(for facet: CatalogFacet) {
        lastFacet = facet
        screen = .values(facet)
    }

    private func showFilterList() {
        screen = .filters
    }

    private func handleExit() {
        switch screen {
        case .filters:
            commitAndClose()
        case .values:
            showFilterList()
        }
    }

    private func commitAndClose() {
        onApply(draft)
        onClose()
    }

    private func claimFocus(_ target: FocusTarget?) {
        focusedTarget = target
        Task { @MainActor in
            await Task.yield()
            resetFocus(in: panelFocusScope)
            focusedTarget = target
        }
    }
}

// MARK: - Button styles

struct TVBrowseControlPillStyle: ButtonStyle {
    var active: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        TVBrowseControlPillBody(configuration: configuration, active: active)
    }
}

private struct TVBrowseControlPillBody: View {
    let configuration: ButtonStyleConfiguration
    let active: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .foregroundColor(isFocused ? .siloBackground : .siloOnSurface)
            .background(
                Capsule().fill(
                    isFocused ? Color.siloOnSurface
                        : (active ? Color.siloChromeSelectedFill : Color.siloChromeRestingFill)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    isFocused ? Color.clear : Color.siloChromeRestingBorder,
                    lineWidth: 1
                )
            )
            .scaleEffect(isFocused ? 1.04 : 1)
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

struct TVBrowsePanelRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVBrowsePanelRowBody(configuration: configuration)
    }
}

private struct TVBrowsePanelRowBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundColor(isFocused ? .siloBackground : .siloOnSurface)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isFocused ? Color.siloOnSurface : Color.clear)
            )
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}
#endif
