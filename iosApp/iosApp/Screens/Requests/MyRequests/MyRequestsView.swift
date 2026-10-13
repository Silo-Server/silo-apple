import SwiftUI

/// Request management. On iOS/macOS: the signed-in user's requests as an
/// inset-grouped list in the Downloads manager's shape — a stage track on
/// every row, swipe to cancel, Open once a title lands, and a filter menu in
/// the navigation bar. Request administration (approve, decline, retry)
/// stays in the web admin. tvOS renders the same data as a Skyline page
/// (`TVRequestsPage`).
struct MyRequestsView: View {
    var body: some View {
        #if os(tvOS)
        TVRequestsPage(mode: .mine)
        #else
        PhoneMyRequestsView()
        #endif
    }
}

#if !os(tvOS)
private struct PhoneMyRequestsView: View {
    @State private var viewModel = MyRequestsViewModel()
    @State private var filter: MyRequestsBucket?
    @Environment(AppRouter.self) private var router

    var body: some View {
        List {
            mineContent
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .siloPageBackground()
        .navigationTitle("My Requests")
        .siloNavigationTitleDisplayMode(.large)
        .siloToolbarColorSchemeDark()
        .toolbar {
            if viewModel.buckets.count > 1 {
                ToolbarItem(placement: .primaryAction) { filterMenu }
            }
        }
        .task {
            await viewModel.load()
        }
        .refreshable {
            await viewModel.load()
        }
        .onChange(of: RequestsEventBus.shared.lastUpdate) { _, update in
            if let update { viewModel.applyRequestUpdate(update) }
        }
        .onChange(of: viewModel.buckets.map(\.bucket)) { _, buckets in
            // A filter whose last request moved on would leave a blank list.
            if let filter, !buckets.contains(filter) { self.filter = nil }
        }
    }

    // MARK: - Filter

    /// One control in the navigation bar instead of a chip row that repeats
    /// the section headers. The icon fills while a filter is on.
    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $filter) {
                Label("All Requests", systemImage: "tray.full")
                    .tag(MyRequestsBucket?.none)
                ForEach(viewModel.buckets, id: \.bucket) { entry in
                    Label("\(entry.bucket.title) (\(entry.requests.count))", systemImage: entry.bucket.systemImage)
                        .tag(Optional(entry.bucket))
                }
            }
        } label: {
            Image(systemName: filter == nil
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel(filter.map { "Filter: \($0.title)" } ?? "Filter")
        .sensoryFeedback(.selection, trigger: filter)
    }

    // MARK: - Mine

    @ViewBuilder
    private var mineContent: some View {
        if let error = viewModel.error, viewModel.buckets.isEmpty {
            fullRow { ErrorView(state: error, onRetry: { Task { await viewModel.load() } }).padding(.top, 60) }
        } else if viewModel.isLoading && viewModel.buckets.isEmpty {
            fullRow { MyRequestsSkeleton().padding(.horizontal, -16) }
        } else if viewModel.isEmpty {
            fullRow {
                EmptyStateView(
                    icon: "tray",
                    title: "No requests yet",
                    subtitle: "Movies and series you request will show up here"
                )
                .padding(.top, 80)
            }
        } else {

            if let message = viewModel.actionErrorMessage {
                fullRow {
                    Text(message)
                        .font(.siloCaption)
                        .foregroundColor(.siloSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            ForEach(visibleBuckets, id: \.bucket) { entry in
                Section {
                    ForEach(entry.requests) { record in
                        MyRequestRow(
                            record: record,
                            isBusy: viewModel.cancellingId == record.id,
                            isDimmed: viewModel.cancellingId == record.id,
                            onOpen: { router.openRequestRecord(record) },
                            onOpenInLibrary: record.libraryContentId.map { id in
                                { router.navigate(to: .itemDetail(contentId: id)) }
                            }
                        )
                        .listRowBackground(Color.siloGroupedCell)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if isCancelable(record) {
                                Button(role: .destructive) {
                                    Task { await viewModel.cancel(record) }
                                } label: {
                                    Label("Cancel", systemImage: "xmark")
                                }
                            }
                        }
                        .contextMenu {
                            if isCancelable(record) {
                                Button(role: .destructive) {
                                    Task { await viewModel.cancel(record) }
                                } label: {
                                    Label("Cancel Request", systemImage: "xmark.circle")
                                }
                            }
                        }
                    }
                } header: {
                    sectionHeader(entry.bucket.title, count: entry.requests.count)
                }
            }
        }
    }

    private var visibleBuckets: [(bucket: MyRequestsBucket, requests: [MediaRequest])] {
        guard let filter else { return viewModel.buckets }
        return viewModel.buckets.filter { $0.bucket == filter }
    }

    private func isCancelable(_ record: MediaRequest) -> Bool {
        RequestDisplayState(record: record).isCancelable && !viewModel.isCancelUnconfirmed(record)
    }

    // MARK: - Helpers

    private func fullRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)")
        }
        .font(.subheadline.weight(.medium))
        .foregroundColor(.siloSecondaryText)
        .textCase(nil)
    }
}

// MARK: - Rows

/// One request in the grouped list: poster, title, meta line, the stage
/// track, and a status line. The trailing slot is Open (in the library) or
/// a disclosure chevron.
struct MyRequestRow: View {
    let record: MediaRequest
    /// Takes no taps while another action is in flight.
    var isBusy = false
    /// Fades the row's content, e.g. while it's being cancelled.
    var isDimmed = false
    let onOpen: () -> Void
    var onOpenInLibrary: (() -> Void)? = nil

    var body: some View {
        let progress = RequestProgress(record: record)
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    RequestRowPoster(path: record.posterPath)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(record.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.siloOnSurface)
                            .lineLimit(1)
                        Text(RequestRowCopy.meta(record, progress: progress))
                            .font(.caption)
                            .foregroundColor(.siloSecondaryText)
                            .lineLimit(1)
                            .padding(.top, 2)
                        RequestStageTrack(progress: progress)
                            .padding(.top, 9)
                        RequestStatusLabel(
                            progress: progress,
                            text: RequestRowCopy.status(record, progress: progress),
                            font: .caption.weight(.semibold),
                            color: .siloOnSurface,
                            lineLimit: 2
                        )
                        .padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isDimmed ? 0.45 : 1)

            trailing(progress: progress)
        }
        .padding(.vertical, 4)
        .disabled(isBusy)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func trailing(progress: RequestProgress) -> some View {
        if let onOpenInLibrary, progress.display == .inLibrary {
            RequestRowCapsuleButton(title: "Open", systemImage: "arrow.up.right", action: onOpenInLibrary)
        } else {
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundColor(.siloSecondaryText.opacity(0.7))
        }
    }
}

private struct RequestRowPoster: View {
    let path: String?

    var body: some View {
        Group {
            if let url = RequestImageURL.build(path, size: .poster) {
                AsyncImageView(url: url, targetSize: CGSize(width: 46, height: 69), contentMode: .fill)
            } else {
                Color.siloSurfaceElevated
            }
        }
        .frame(width: 46, height: 69)
        .clipShape(RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous))
    }
}

private struct RequestRowCapsuleButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.siloOnSurface)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.siloChromeSelectedFill))
        }
        .buttonStyle(.borderless)
    }
}

#endif

/// Row copy shared by the phone list and the tvOS marquee.
enum RequestRowCopy {
    /// "Movie · Requested Sep 24", or "Movie · Added Sep 13" once it landed.
    static func meta(_ record: MediaRequest, progress: RequestProgress) -> String {
        let kind = record.mediaType.displayName
        if progress.display == .inLibrary, let completed = record.completedAt {
            return "\(kind) · Added \(completed.formatted(.dateTime.month(.abbreviated).day()))"
        }
        return "\(kind) · Requested \(record.createdAt.formatted(.dateTime.month(.abbreviated).day()))"
    }

    /// The status line under the stage track: the long label, plus the
    /// per-quality summary while in flight or the reason when stuck.
    static func status(_ record: MediaRequest, progress: RequestProgress) -> String {
        if case .needsAttention(_, let reason) = progress.display,
           let copy = RequestErrorCopy.message(forToken: reason) {
            return "\(progress.longLabel) · \(copy)"
        }
        if progress.display == .onTheWay, let targets = RequestTargetSummary.text(for: record.targets) {
            return "\(progress.longLabel) · \(targets)"
        }
        return progress.longLabel
    }
}
