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
    let onSort: () -> Void
    let onFilter: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onSort) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text("Sort · \(sortLabel)")
                    Text(sortDirection)
                        .foregroundColor(.continuumSecondaryText)
                }
            }
            .buttonStyle(TVBrowseControlPillStyle())

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

            Spacer(minLength: 0)
        }
        .font(.system(size: 24, weight: .medium))
        .focusSection()
    }
}

// MARK: - Sort panel

struct TVBrowseSortPanel: View {
    let mediaType: BrowseMediaType
    let current: CatalogSortKey
    let order: CatalogSortOrder
    let onSelect: (CatalogSortKey) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SORT BY")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundColor(.continuumSecondaryText)
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
                                .foregroundColor(.continuumSecondaryText)
                            Image(systemName: order == .asc ? "arrow.up" : "arrow.down")
                        }
                    }
                    .font(.system(size: 26))
                }
                .buttonStyle(TVBrowsePanelRowStyle())
            }
        }
        .padding(14)
        .frame(width: 460)
        .modifier(TVSkylinePanelChrome())
        .onExitCommand(perform: onClose)
    }
}

// MARK: - Filter panel (two-pane: facet list → values)

struct TVBrowseFilterPanel: View {
    let mediaType: BrowseMediaType
    let facets: CatalogFacets
    let resultNoun: String
    let onPreview: (CatalogFilterState) async -> Int?
    let onApply: (CatalogFilterState) -> Void
    let onPreserveChange: (Bool) -> Void
    let onClose: () -> Void

    @State private var draft: CatalogFilterState
    @State private var preserve: Bool
    @State private var activeFacet: CatalogFacet
    @FocusState private var focusedFacet: CatalogFacet?
    @State private var liveCount: Int?
    @State private var previewTask: Task<Void, Never>?

    private let availableFacets: [CatalogFacet]

    init(mediaType: BrowseMediaType,
         facets: CatalogFacets,
         initial: CatalogFilterState,
         preserveEnabled: Bool,
         resultNoun: String,
         onPreview: @escaping (CatalogFilterState) async -> Int?,
         onApply: @escaping (CatalogFilterState) -> Void,
         onPreserveChange: @escaping (Bool) -> Void,
         onClose: @escaping () -> Void) {
        self.mediaType = mediaType
        self.facets = facets
        self.resultNoun = resultNoun
        self.onPreview = onPreview
        self.onApply = onApply
        self.onPreserveChange = onPreserveChange
        self.onClose = onClose
        let visible = CatalogFacet.available(for: mediaType)
            .filter { !facets.optionPairs(for: $0, hasProfile: Self.hasProfile).isEmpty }
        self.availableFacets = visible
        _draft = State(initialValue: initial)
        _preserve = State(initialValue: preserveEnabled)
        _activeFacet = State(initialValue: visible.first ?? .genre)
    }

    private static var hasProfile: Bool { AuthService.shared.profileId?.isEmpty == false }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                facetList
                    .frame(width: 300)
                    .focusSection()
                Divider().overlay(Color.continuumDivider)
                valuesPane
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .focusSection()
            }
            footer
                .focusSection()
        }
        .padding(20)
        .frame(width: 1140, height: 560)
        .modifier(TVSkylinePanelChrome())
        .onExitCommand(perform: onClose)
        .onChange(of: focusedFacet) { _, new in
            if let new { activeFacet = new }
        }
        .onChange(of: draft) { _, _ in schedulePreview() }
        .task { schedulePreview() }
    }

    // MARK: Panes

    private var facetList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("FILTER BY")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(.continuumSecondaryText)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)

                ForEach(availableFacets, id: \.self) { facet in
                    Button {} label: {
                        HStack(spacing: 12) {
                            Text(facet.title)
                            Spacer(minLength: 0)
                            Text(facetSummary(facet))
                                .foregroundColor(.continuumSecondaryText)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 16))
                                .opacity(0.6)
                        }
                        .font(.system(size: 22))
                    }
                    .buttonStyle(TVBrowsePanelRowStyle())
                    .focused($focusedFacet, equals: facet)
                }
            }
        }
    }

    private var valuesPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(activeFacet.title.uppercased())
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(.continuumSecondaryText)

                TVBrowseChipCloud(
                    options: facets.optionPairs(for: activeFacet, hasProfile: Self.hasProfile),
                    isSelected: { draft.isSelected(activeFacet, value: $0) },
                    toggle: { draft.toggle(activeFacet, value: $0) }
                )
            }
            .padding(.trailing, 8)
        }
    }

    private var footer: some View {
        HStack(spacing: 24) {
            Button { preserve.toggle(); onPreserveChange(preserve) } label: {
                HStack(spacing: 12) {
                    Image(systemName: preserve ? "checkmark.square.fill" : "square")
                    Text("Preserve sort & filters")
                }
                .font(.system(size: 20))
            }
            .buttonStyle(TVBrowsePanelRowStyle())

            Spacer(minLength: 0)

            Text(countLabel)
                .font(.system(size: 18, design: .monospaced))
                .foregroundColor(.continuumSecondaryText)

            Button {
                onApply(draft)
                onClose()
            } label: {
                Text(applyTitle)
                    .font(.system(size: 22, weight: .semibold))
                    .padding(.horizontal, 28)
            }
            .buttonStyle(TVBrowseApplyStyle())
        }
        .padding(.top, 16)
    }

    // MARK: Helpers

    private func facetSummary(_ facet: CatalogFacet) -> String {
        let values = draft.selectedValues(facet)
        guard !values.isEmpty else { return "Any" }
        if values.count == 1, let only = values.first {
            return CatalogFilterState.chipLabel(facet: facet, value: only)
        }
        return "\(values.count) selected"
    }

    private var countLabel: String {
        guard let liveCount else { return "" }
        return "\(liveCount.formatted()) \(resultNoun.uppercased())"
    }

    private var applyTitle: String {
        guard let liveCount else { return "Apply" }
        return "Show \(liveCount.formatted())"
    }

    private func schedulePreview() {
        previewTask?.cancel()
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let count = await onPreview(draft)
            guard !Task.isCancelled else { return }
            liveCount = count
        }
    }
}

/// Wrapping multi-select chip cloud for the values pane.
private struct TVBrowseChipCloud: View {
    let options: [(value: String, label: String)]
    let isSelected: (String) -> Bool
    let toggle: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 320), spacing: 12, alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(options, id: \.value) { option in
                Button { toggle(option.value) } label: {
                    Text(option.label)
                        .font(.system(size: 20))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TVBrowseChipStyle(selected: isSelected(option.value)))
            }
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
            .foregroundColor(isFocused ? .continuumBackground : .continuumOnSurface)
            .background(
                Capsule().fill(
                    isFocused ? Color.continuumOnSurface
                        : (active ? Color.continuumChromeSelectedFill : Color.continuumChromeRestingFill)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    isFocused ? Color.clear : Color.continuumChromeRestingBorder,
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
            .foregroundColor(isFocused ? .continuumBackground : .continuumOnSurface)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isFocused ? Color.continuumOnSurface : Color.clear)
            )
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

struct TVBrowseChipStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        TVBrowseChipBody(configuration: configuration, selected: selected)
    }
}

private struct TVBrowseChipBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .foregroundColor(foreground)
            .background(
                Capsule().fill(selected ? Color.continuumOnSurface : Color.continuumSurfaceElevated)
            )
            .overlay(
                Capsule().strokeBorder(Color.white, lineWidth: isFocused ? 3 : 0)
            )
            .scaleEffect(isFocused ? 1.05 : 1)
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }

    private var foreground: Color {
        selected ? .continuumBackground : .continuumOnSurface
    }
}

struct TVBrowseApplyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVBrowseApplyBody(configuration: configuration)
    }
}

private struct TVBrowseApplyBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(.vertical, 14)
            .foregroundColor(.continuumBackground)
            .background(Capsule().fill(Color.continuumOnSurface))
            .overlay(Capsule().strokeBorder(Color.white, lineWidth: isFocused ? 4 : 0))
            .scaleEffect(isFocused ? 1.05 : 1)
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}
#endif
