#if os(iOS)
import SwiftUI

/// Sort and Filter menus shown under the media-type picker on Favorites and
/// Watchlist. Styled to match the Browse control bar.
struct IOSPersonalListFilterBar: View {
    @Binding var filter: PersonalListFilter
    let availableGenres: [String]

    var body: some View {
        HStack(spacing: 9) {
            sortMenu
            filterMenu
            Spacer(minLength: 0)
            if filter.hasActiveFilters {
                Button("Clear") {
                    withAnimation { filter.clearFilters() }
                }
                .font(.siloBody)
                .foregroundColor(.siloSecondaryText)
                .accessibilityLabel("Clear filters")
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $filter.sort) {
                ForEach(PersonalListSort.allCases) { sort in
                    Text(sort.label).tag(sort)
                }
            }
        } label: {
            chip(icon: "arrow.up.arrow.down", text: filter.sort.label)
        }
        .accessibilityLabel("Sort, \(filter.sort.label)")
    }

    private var filterMenu: some View {
        Menu {
            Picker("Watch Status", selection: $filter.watch) {
                ForEach(PersonalListWatchFilter.allCases) { watch in
                    Text(watch.label).tag(watch)
                }
            }
            .pickerStyle(.inline)

            if !availableGenres.isEmpty {
                Section("Genre") {
                    ForEach(availableGenres, id: \.self) { genre in
                        Toggle(genre, isOn: genreBinding(genre))
                    }
                }
            }

            if filter.hasActiveFilters {
                Section {
                    Button("Clear Filters", role: .destructive) {
                        filter.clearFilters()
                    }
                }
            }
        } label: {
            chip(
                icon: "line.3.horizontal.decrease",
                text: "Filter",
                badge: filter.activeFilterCount
            )
        }
        .menuActionDismissBehavior(.disabled)
        .accessibilityLabel(
            filter.hasActiveFilters
                ? "Filter, \(filter.activeFilterCount) active"
                : "Filter"
        )
    }

    private func genreBinding(_ genre: String) -> Binding<Bool> {
        Binding(
            get: { filter.genres.contains(genre) },
            set: { _ in filter.toggleGenre(genre) }
        )
    }

    private func chip(icon: String, text: String, badge: Int = 0) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(.siloBody)
            if badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.siloBackground)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.siloOnSurface))
            }
        }
        .foregroundColor(.siloOnSurface)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .siloGlass(in: .capsule)
    }
}

/// Shown when the list has titles in the selected media type but none pass
/// the active filters.
struct IOSPersonalListNoMatchesView: View {
    let onClear: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Matches", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("No saved titles match these filters.")
        } actions: {
            Button("Clear Filters", action: onClear)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }
}
#endif
