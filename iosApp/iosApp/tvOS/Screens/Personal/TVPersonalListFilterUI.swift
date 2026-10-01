#if os(tvOS)
import SwiftUI

/// Which saved-list panel is open over the grid.
enum TVPersonalListPanel: Hashable {
    case sort
    case filter
}

/// Focus targets for the Sort and Filter pills. The host screen owns the
/// `@FocusState` so it can seed entry focus and restore the opener when a
/// panel closes.
enum TVPersonalListControl: Hashable {
    case sort
    case filter
}

// MARK: - Control pills

/// Sort and Filter pills for Favorites and Watchlist. Rendered inside the
/// host's existing control row so the row stays one native focus section.
struct TVPersonalListControls: View {
    let filter: PersonalListFilter
    let focusedControl: FocusState<TVPersonalListControl?>.Binding
    let onOpen: (TVPersonalListPanel) -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button { onOpen(.sort) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text("Sort · \(filter.sort.label)")
                }
            }
            .buttonStyle(TVBrowseControlPillStyle())
            .focused(focusedControl, equals: .sort)

            Button { onOpen(.filter) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text("Filter")
                    if filter.activeFilterCount > 0 {
                        Text("\(filter.activeFilterCount)")
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.25)))
                    }
                }
            }
            .buttonStyle(TVBrowseControlPillStyle(active: filter.hasActiveFilters))
            .focused(focusedControl, equals: .filter)
            .accessibilityLabel(
                filter.hasActiveFilters
                    ? "Filter, \(filter.activeFilterCount) active"
                    : "Filter"
            )
        }
        .font(.system(size: 24, weight: .medium))
    }
}

/// Shown when a saved list has titles but none pass the active filters.
/// Not focusable: the Sort and Filter pills above it stay the focus owner.
struct TVPersonalListNoMatchesView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Color.siloOnSurface.opacity(0.34))

            Text("No matches")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.siloOnSurface)

            Text("No saved titles match these filters.")
                .font(.system(size: 22))
                .foregroundStyle(Color.siloSecondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 430)
    }
}

// MARK: - Panel host

extension View {
    /// Dims and disables the page while a saved-list panel is open, then
    /// hands focus back to the pill that opened it.
    func tvPersonalListPanels(
        openPanel: Binding<TVPersonalListPanel?>,
        filter: Binding<PersonalListFilter>,
        availableGenres: [String],
        focusedControl: FocusState<TVPersonalListControl?>.Binding
    ) -> some View {
        modifier(TVPersonalListPanelHost(
            openPanel: openPanel,
            filter: filter,
            availableGenres: availableGenres,
            focusedControl: focusedControl
        ))
    }
}

private struct TVPersonalListPanelHost: ViewModifier {
    @Binding var openPanel: TVPersonalListPanel?
    @Binding var filter: PersonalListFilter
    let availableGenres: [String]
    let focusedControl: FocusState<TVPersonalListControl?>.Binding

    func body(content: Content) -> some View {
        ZStack {
            content
                // While a panel is open the page is inert, so focus can only
                // move inside the panel.
                .disabled(openPanel != nil)

            if let panel = openPanel {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()

                switch panel {
                case .sort:
                    TVPersonalListSortPanel(
                        current: filter.sort,
                        onSelect: { sort in
                            filter.sort = sort
                            close(panel)
                        },
                        onClose: { close(panel) }
                    )
                case .filter:
                    TVPersonalListFilterPanel(
                        filter: $filter,
                        availableGenres: availableGenres,
                        onClose: { close(panel) }
                    )
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: openPanel)
    }

    private func close(_ panel: TVPersonalListPanel) {
        openPanel = nil
        let opener: TVPersonalListControl = panel == .sort ? .sort : .filter
        // The pills are disabled until this render pass finishes; focus them
        // on the next turn so the claim isn't dropped.
        Task { @MainActor in
            await Task.yield()
            focusedControl.wrappedValue = opener
        }
    }
}

// MARK: - Sort panel

private struct TVPersonalListSortPanel: View {
    let current: PersonalListSort
    let onSelect: (PersonalListSort) -> Void
    let onClose: () -> Void

    @Environment(\.resetFocus) private var resetFocus
    @Namespace private var sortFocusScope
    @FocusState private var focusedSort: PersonalListSort?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SORT BY")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundColor(.siloSecondaryText)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)

            ForEach(PersonalListSort.allCases) { sort in
                Button { onSelect(sort) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "checkmark")
                            .opacity(sort == current ? 1 : 0)
                        Text(sort.label)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 26))
                }
                .buttonStyle(TVBrowsePanelRowStyle())
                .focused($focusedSort, equals: sort)
                .accessibilityAddTraits(sort == current ? .isSelected : [])
            }
        }
        .padding(14)
        .frame(width: 460)
        .modifier(TVSkylinePanelChrome())
        .focusScope(sortFocusScope)
        .focusSection()
        .onExitCommand(perform: onClose)
        .onAppear(perform: claimFocus)
    }

    private func claimFocus() {
        focusedSort = current
        Task { @MainActor in
            await Task.yield()
            resetFocus(in: sortFocusScope)
            focusedSort = current
        }
    }
}

// MARK: - Filter panel

/// Watch status and genre filters. Changes apply as they are made; Done or
/// Menu/Back closes the panel.
private struct TVPersonalListFilterPanel: View {
    @Binding var filter: PersonalListFilter
    let availableGenres: [String]
    let onClose: () -> Void

    private enum FocusTarget: Hashable {
        case watch(PersonalListWatchFilter)
        case genre(String)
        case clear
        case done
    }

    @Environment(\.resetFocus) private var resetFocus
    @Namespace private var panelFocusScope
    @FocusState private var focusedTarget: FocusTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("FILTER BY")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(.siloSecondaryText)

                Text("Filters")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(.siloOnSurface)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .overlay(Color.siloDivider)
                .padding(.vertical, 12)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    sectionHeader("WATCH STATUS")
                    ForEach(PersonalListWatchFilter.allCases) { watch in
                        optionRow(
                            title: watch.label,
                            isSelected: filter.watch == watch,
                            focus: .watch(watch)
                        ) {
                            filter.watch = watch
                        }
                    }

                    if !availableGenres.isEmpty {
                        sectionHeader("GENRE")
                        ForEach(availableGenres, id: \.self) { genre in
                            optionRow(
                                title: genre,
                                isSelected: filter.genres.contains(genre),
                                focus: .genre(genre)
                            ) {
                                filter.toggleGenre(genre)
                            }
                        }
                    }

                    sectionHeader("OPTIONS")
                    clearRow
                    doneRow
                }
                .padding(.vertical, 4)
            }
        }
        .padding(22)
        .frame(width: 680, height: 680, alignment: .topLeading)
        .modifier(TVSkylinePanelChrome())
        .focusScope(panelFocusScope)
        .focusSection()
        .onExitCommand(perform: onClose)
        .onAppear { claimFocus(.watch(filter.watch)) }
    }

    private func optionRow(
        title: String,
        isSelected: Bool,
        focus: FocusTarget,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .font(.system(size: 24))
        }
        .buttonStyle(TVBrowsePanelRowStyle())
        .focused($focusedTarget, equals: focus)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var clearRow: some View {
        Button {
            filter.clearFilters()
            claimFocus(.done)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 22, weight: .semibold))
                Text("Clear filters")
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 23))
        }
        .buttonStyle(TVBrowsePanelRowStyle())
        .focused($focusedTarget, equals: .clear)
        .disabled(!filter.hasActiveFilters)
        .opacity(filter.hasActiveFilters ? 1 : 0.45)
    }

    private var doneRow: some View {
        Button(action: onClose) {
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

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .tracking(2)
            .foregroundColor(.siloSecondaryText)
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 6)
    }

    private func claimFocus(_ target: FocusTarget) {
        focusedTarget = target
        Task { @MainActor in
            await Task.yield()
            resetFocus(in: panelFocusScope)
            focusedTarget = target
        }
    }
}
#endif
