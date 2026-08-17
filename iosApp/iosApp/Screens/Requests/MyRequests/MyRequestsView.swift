import SwiftUI

/// The signed-in user's request queue, bucketed like the web's "Yours" tab:
/// In motion / Landed in your library / Needs attention. Pending requests
/// can be cancelled (swipe on iOS, long-press context menu on tvOS);
/// completed rows deep-link into the real library item.
struct MyRequestsView: View {
    @State private var viewModel = MyRequestsViewModel()
    @Environment(AppRouter.self) private var router

    var body: some View {
        Group {
            if let error = viewModel.error, viewModel.buckets.isEmpty {
                ErrorView(state: error, onRetry: { Task { await viewModel.load() } })
            } else if viewModel.isLoading && viewModel.buckets.isEmpty {
                LoadingView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.isEmpty {
                EmptyStateView(
                    icon: "sparkles",
                    title: "No requests yet",
                    subtitle: "Movies and series you request will show up here"
                )
            } else {
                bucketList
            }
        }
        .siloBackground()
        .navigationTitle("My Requests")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
        .siloNavigationBarSurfaceBackground()
        .task {
            await viewModel.load()
        }
        .onChange(of: RequestsEventBus.shared.lastUpdate) { _, update in
            if let update {
                viewModel.applyRequestUpdate(update)
            }
        }
        #if !os(tvOS)
        .refreshable {
            await viewModel.load()
        }
        #endif
    }

    // MARK: - Buckets

    private var bucketList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: sectionSpacing) {
                if let message = viewModel.actionErrorMessage {
                    Text(message)
                        .font(.siloCaption)
                        .foregroundColor(.siloSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                ForEach(viewModel.buckets, id: \.bucket) { entry in
                    bucketSection(entry.bucket, requests: entry.requests)
                }
            }
            .padding(.horizontal, SiloTheme.padding)
            .padding(.top, SiloTheme.smallPadding)
            .padding(.bottom, SiloTheme.largePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(tvOS)
        .safeAreaPadding(.horizontal, 40)
        #endif
    }

    @ViewBuilder
    private func bucketSection(_ bucket: MyRequestsBucket, requests: [MediaRequest]) -> some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(bucket.title)
                    .font(.siloHeadline)
                    .foregroundColor(.siloOnSurface)
                Text(String(requests.count))
                    .font(.siloCaption)
                    .foregroundColor(.siloSecondaryText)
            }

            #if os(tvOS)
            RequestCardRail(items: requests) { record in
                RequestMediaCard(record: record, onTap: { router.openRequestRecord(record) })
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
            .focusSection()
            #else
            VStack(spacing: rowSpacing) {
                ForEach(requests) { record in
                    requestRow(record)
                }
            }
            #endif
        }
    }

    // MARK: - iOS/macOS rows

    #if !os(tvOS)
    private func requestRow(_ record: MediaRequest) -> some View {
        Button {
            router.openRequestRecord(record)
        } label: {
            HStack(spacing: 12) {
                rowThumb(record)

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title)
                        .font(.siloSubheadline)
                        .foregroundColor(.siloOnSurface)
                        .lineLimit(1)

                    Text(rowMeta(record))
                        .font(.siloCaption)
                        .foregroundColor(.siloSecondaryText)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                RequestStatusChip(state: rowState(record))
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: SiloTheme.cornerRadius)
                    .fill(Color.siloSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SiloTheme.cornerRadius)
                    .stroke(Color.siloOutline.opacity(0.6), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.cancellingId == record.id)
        .opacity(viewModel.cancellingId == record.id ? 0.5 : 1)
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

    @ViewBuilder
    private func rowThumb(_ record: MediaRequest) -> some View {
        if let url = RequestImageURL.build(record.posterPath, size: .poster) {
            AsyncImageView(
                url: url,
                targetSize: CGSize(width: 46, height: 69),
                contentMode: .fill
            )
            .frame(width: 46, height: 69)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius))
        } else {
            RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius)
                .fill(Color.siloSurfaceElevated)
                .frame(width: 46, height: 69)
        }
    }
    #endif

    // MARK: - Row derivation

    private func rowState(_ record: MediaRequest) -> RequestDisplayState {
        RequestDisplayState(status: record.status, outcome: record.outcome, reason: record.lastError)
    }

    private func isCancelable(_ record: MediaRequest) -> Bool {
        rowState(record).isCancelable
    }

    private func rowMeta(_ record: MediaRequest) -> String {
        var parts = [record.mediaType.displayName]
        if let summary = targetSummary(record) {
            parts.append(summary)
        } else {
            parts.append("requested \(record.createdAt.formatted(.dateTime.month(.abbreviated).day()))")
        }
        if case .needsAttention(let reason) = rowState(record),
           let copy = RequestErrorCopy.message(forToken: reason) {
            parts.append(copy)
        }
        return parts.joined(separator: " · ")
    }

    /// "1080p done · 4K downloading" for multi-target requests in flight.
    private func targetSummary(_ record: MediaRequest) -> String? {
        guard let targets = record.targets, targets.count > 1 else { return nil }
        let summaries = targets.compactMap { target -> String? in
            guard let quality = target.quality, !quality.isEmpty else { return nil }
            let word: String
            switch target.status {
            case .completed: word = "done"
            case .downloading: word = "downloading"
            case .queued, .approved: word = "queued"
            case .pending: word = "pending"
            case .failed: word = "failed"
            case .unknown: return nil
            }
            return "\(quality) \(word)"
        }
        guard !summaries.isEmpty else { return nil }
        return summaries.joined(separator: " · ")
    }

    // MARK: - Metrics

    private var sectionSpacing: CGFloat {
        #if os(tvOS)
        48
        #else
        24
        #endif
    }

    private var rowSpacing: CGFloat {
        #if os(tvOS)
        20
        #else
        10
        #endif
    }
}
