import SwiftUI

/// Request management. On iOS/macOS: the signed-in user's requests as an
/// inset-grouped list in the Downloads manager's shape — a stage track on
/// every row, swipe to cancel, Open once a title lands, and a filter menu in
/// the navigation bar. Admins get a card into the approval queue, which is
/// its own page (`.everyone`). tvOS renders the same data as a Skyline page
/// (`TVRequestsPage`).
struct MyRequestsView: View {
    var initialScope: MyRequestsScope = .mine

    var body: some View {
        #if os(tvOS)
        TVRequestsPage(mode: initialScope == .everyone ? .approvals : .mine)
        #else
        PhoneMyRequestsView(initialScope: initialScope)
        #endif
    }
}

enum MyRequestsScope: Hashable {
    case mine
    case everyone
}

#if !os(tvOS)
private struct PhoneMyRequestsView: View {
    @State private var viewModel = MyRequestsViewModel()
    @State private var approvals = RequestApprovalsViewModel()
    private let scope: MyRequestsScope
    @State private var filter: MyRequestsBucket?
    @State private var pendingDecline: MediaRequest?
    @Environment(AppRouter.self) private var router

    init(initialScope: MyRequestsScope) {
        scope = initialScope
    }

    private var canModerate: Bool { RequestsFeatureStore.shared.canModerate }

    var body: some View {
        List {
            switch scope {
            case .mine: mineContent
            case .everyone: everyoneContent
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .siloPageBackground()
        .navigationTitle(scope == .mine ? "My Requests" : "Approvals")
        .siloNavigationTitleDisplayMode(.large)
        .siloToolbarColorSchemeDark()
        .toolbar {
            if scope == .mine, viewModel.buckets.count > 1 {
                ToolbarItem(placement: .primaryAction) { filterMenu }
            }
        }
        .task {
            switch scope {
            case .mine:
                await viewModel.load()
                // For the approvals card; a failed read just hides it.
                if canModerate { await approvals.load() }
            case .everyone:
                await approvals.load()
            }
        }
        .refreshable {
            switch scope {
            case .mine: await viewModel.load()
            case .everyone: await approvals.load()
            }
        }
        .onChange(of: RequestsEventBus.shared.lastUpdate) { _, update in
            if let update { viewModel.applyRequestUpdate(update) }
        }
        .onChange(of: RequestsEventBus.shared.lastModeration) { _, record in
            if let record { approvals.applyModeration(record) }
        }
        .onChange(of: RequestsFeatureStore.shared.canModerate) { _, canModerate in
            // Moderation can be confirmed after the page's first load.
            if canModerate { Task { await approvals.load() } }
        }
        .onChange(of: viewModel.buckets.map(\.bucket)) { _, buckets in
            // A filter whose last request moved on would leave a blank list.
            if let filter, !buckets.contains(filter) { self.filter = nil }
        }
        .sensoryFeedback(.success, trigger: approvals.completedActions)
        .sensoryFeedback(.error, trigger: approvals.failedActions)
        // Finished rows fade and collapse out of the list.
        .animation(.smooth(duration: 0.35), value: approvals.awaitingApproval.map(\.id))
        .animation(.smooth(duration: 0.35), value: approvals.failed.map(\.id))
        .confirmationDialog(
            "Decline this request?",
            isPresented: Binding(get: { pendingDecline != nil }, set: { if !$0 { pendingDecline = nil } }),
            titleVisibility: .visible,
            presenting: pendingDecline
        ) { request in
            Button("Decline \(request.title)", role: .destructive) {
                Task { await approvals.perform(.decline, on: request) }
            }
        } message: { _ in
            Text("The requester will see it as declined.")
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

    // MARK: - Approvals card

    /// Admins' way into the approval queue, in the hub summary card's shape.
    @ViewBuilder
    private var approvalsCard: some View {
        if canModerate, approvals.hasLoaded, let title = approvalsCardTitle {
            fullRow {
                Button {
                    router.navigate(to: .requestApprovals)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: approvals.pendingCount > 0 ? "person.crop.circle.badge.clock" : "exclamationmark.arrow.triangle.2.circlepath")
                            .font(.title3)
                            .foregroundColor(approvals.pendingCount > 0 ? .requestAmber : .requestRose)
                            .frame(width: 28)
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.siloOnSurface)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.siloSecondaryText)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.siloChromeRestingFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.siloChromeRestingBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var approvalsCardTitle: String? {
        let pending = approvals.awaitingApproval.count
        let failed = approvals.failed.count
        if pending > 0 {
            return pending == 1 ? "1 request needs your approval" : "\(pending) requests need your approval"
        }
        if failed > 0 {
            return failed == 1 ? "1 failed request to review" : "\(failed) failed requests to review"
        }
        return nil
    }

    // MARK: - Mine

    @ViewBuilder
    private var mineContent: some View {
        // Independent of the admin's own list: an admin with no requests of
        // their own still needs the way into the queue.
        approvalsCard

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

    // MARK: - Everyone (admin)

    @ViewBuilder
    private var everyoneContent: some View {
        if let error = approvals.error, !approvals.hasLoaded {
            fullRow { ErrorView(state: error, onRetry: { Task { await approvals.load() } }).padding(.top, 60) }
        } else if !approvals.hasLoaded {
            fullRow { MyRequestsSkeleton().padding(.horizontal, -16) }
        } else if approvals.isEmpty {
            fullRow {
                EmptyStateView(
                    icon: "checkmark.circle",
                    title: "Nothing waiting on you",
                    subtitle: "New requests that need approval will show up here"
                )
                .padding(.top, 80)
            }
        } else {
            if let message = approvals.actionErrorMessage {
                fullRow {
                    Text(message)
                        .font(.siloCaption)
                        .foregroundColor(.siloSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            if !approvals.awaitingApproval.isEmpty {
                Section {
                    ForEach(approvals.awaitingApproval) { record in
                        RequestApprovalRow(
                            record: record,
                            isBusy: !approvals.canAct(on: record),
                            phase: approvals.phase(for: record),
                            actionError: approvals.rowErrors[record.id],
                            shakeTrigger: approvals.failureCounts[record.id] ?? 0,
                            onOpen: { router.openModerationRecord(record) },
                            onApprove: { Task { await approvals.perform(.approve, on: record) } },
                            onDecline: { pendingDecline = record }
                        )
                        .listRowBackground(Color.siloGroupedCell)
                    }
                } header: {
                    sectionHeader("Waiting for approval", count: approvals.awaitingApproval.count)
                }
            }

            if !approvals.failed.isEmpty {
                Section {
                    ForEach(approvals.failed) { record in
                        MyRequestRow(
                            record: record,
                            isBusy: !approvals.canAct(on: record),
                            actionPhase: approvals.phase(for: record),
                            actionError: approvals.rowErrors[record.id],
                            shakeTrigger: approvals.failureCounts[record.id] ?? 0,
                            onOpen: { router.openModerationRecord(record) },
                            onRetry: { Task { await approvals.perform(.retry, on: record) } }
                        )
                        .listRowBackground(Color.siloGroupedCell)
                    }
                } header: {
                    sectionHeader("Failed", count: approvals.failed.count)
                }
            }
        }
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
/// track, and a status line. The trailing slot is Open (in the library),
/// Retry (admin, failed), or a disclosure chevron.
struct MyRequestRow: View {
    let record: MediaRequest
    /// Takes no taps (another action is in flight, or this one is held).
    var isBusy = false
    /// Fades the row's content, e.g. while it's being cancelled.
    var isDimmed = false
    /// This row's own admin action; its button animates it.
    var actionPhase: RequestRowActionPhase? = nil
    /// Why this row's last action failed; replaces the status line.
    var actionError: String? = nil
    var shakeTrigger = 0
    let onOpen: () -> Void
    var onOpenInLibrary: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil

    private var progress: RequestProgress { RequestProgress(record: record) }

    var body: some View {
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
                        Group {
                            if let actionError {
                                RequestRowErrorLine(text: "Couldn't retry · \(actionError)")
                            } else {
                                RequestStatusLabel(
                                    progress: progress,
                                    text: RequestRowCopy.status(record, progress: progress),
                                    font: .caption.weight(.semibold),
                                    color: .siloOnSurface,
                                    lineLimit: 2
                                )
                            }
                        }
                        .padding(.top, 6)
                        .transition(.opacity)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The content fades while the action runs; its button doesn't.
            .opacity(isDimmed || actionPhase != nil ? 0.45 : 1)

            trailing
        }
        .padding(.vertical, 4)
        .disabled(isBusy)
        .animation(.easeOut(duration: 0.2), value: actionPhase)
        .animation(.easeOut(duration: 0.2), value: actionError)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var trailing: some View {
        if let onRetry {
            RequestRowActionButton(
                action: .retry,
                phase: actionPhase,
                shakeTrigger: shakeTrigger,
                onTap: onRetry
            )
        } else if let onOpenInLibrary, progress.display == .inLibrary {
            RequestRowCapsuleButton(title: "Open", systemImage: "arrow.up.right", action: onOpenInLibrary)
        } else {
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundColor(.siloSecondaryText.opacity(0.7))
        }
    }
}

/// An admin's view of someone's pending request, with inline decisions.
struct RequestApprovalRow: View {
    let record: MediaRequest
    var isBusy = false
    var phase: RequestRowActionPhase? = nil
    var actionError: String? = nil
    var shakeTrigger = 0
    let onOpen: () -> Void
    let onApprove: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    RequestRowPoster(path: record.posterPath)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(record.title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.siloOnSurface)
                            if let year = record.year, year > 0 {
                                Text("(\(String(year)))")
                                    .font(.system(size: 16))
                                    .foregroundColor(.siloSecondaryText)
                            }
                        }
                        .lineLimit(1)
                        Text("Requested \(record.createdAt.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundColor(.siloSecondaryText)
                        Text(RequestRowCopy.kindAndQuality(record))
                            .font(.caption)
                            .foregroundColor(.siloSecondaryText)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(phase != nil ? 0.45 : 1)

            HStack(spacing: 8) {
                RequestRowActionButton(
                    action: .approve,
                    phase: phase,
                    shakeTrigger: shakeTrigger,
                    style: .prominent,
                    onTap: onApprove
                )
                RequestRowActionButton(
                    action: .decline,
                    phase: phase,
                    shakeTrigger: shakeTrigger,
                    style: .wide,
                    onTap: onDecline
                )
            }

            if let actionError {
                RequestRowErrorLine(text: actionError)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 6)
        .disabled(isBusy)
        .animation(.easeOut(duration: 0.2), value: phase)
        .animation(.easeOut(duration: 0.2), value: actionError)
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

/// An admin action button that shows its own progress: the icon spins
/// while the request is in flight, turns into a check when the server
/// accepts it, and the button shakes when it fails. Buttons for the other
/// actions on the same row step back while one runs.
private struct RequestRowActionButton: View {
    enum Style {
        /// Compact capsule at the row's trailing edge (Retry).
        case trailing
        /// Full-width white capsule (Approve).
        case prominent
        /// Full-width quiet capsule (Decline).
        case wide
    }

    let action: AdminRequestAction
    let phase: RequestRowActionPhase?
    var shakeTrigger = 0
    var style: Style = .trailing
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isWorking: Bool { phase == .working(action) }
    private var isDone: Bool { phase == .succeeded(action) }
    /// Another action on this row owns the animation.
    private var isSidelined: Bool { phase != nil && !isWorking && !isDone }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: isDone ? "checkmark" : idleSymbol)
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isWorking && spins && !reduceMotion)
                    .contentTransition(.symbolEffect(.replace))
                    // A stopped rotation can leave the arrow mid-turn; a
                    // fresh identity when the row returns to idle resets it.
                    .id(phase == nil)
                    .foregroundStyle(iconColor)
                    .opacity(isWorking && !spins && !reduceMotion ? 0 : 1)
                    .overlay {
                        if isWorking && (!spins || reduceMotion) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(foreground)
                        }
                    }
                Text(title)
                    .contentTransition(.interpolate)
            }
            .font(font)
            .foregroundStyle(foreground)
            .padding(.horizontal, style == .trailing ? 12 : 0)
            .padding(.vertical, style == .trailing ? 7 : 0)
            .frame(maxWidth: style == .trailing ? nil : .infinity, minHeight: style == .trailing ? nil : 38)
            .background(Capsule().fill(background))
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .opacity(isSidelined ? 0.35 : 1)
        .modifier(ShakeOnChange(trigger: shakeTrigger))
        .animation(.snappy(duration: 0.25), value: phase)
        .accessibilityLabel(title)
    }

    /// Retry's arrow spins in place; other icons don't read as motion, so
    /// they swap for a spinner.
    private var spins: Bool { action == .retry }

    private var idleSymbol: String {
        switch action {
        case .approve: "checkmark"
        case .decline: "xmark"
        case .retry: "arrow.clockwise"
        }
    }

    private var title: String {
        switch (action, isWorking, isDone) {
        case (.approve, true, _): "Approving…"
        case (.approve, _, true): "Approved"
        case (.approve, _, _): "Approve"
        case (.decline, true, _): "Declining…"
        case (.decline, _, true): "Declined"
        case (.decline, _, _): "Decline"
        case (.retry, true, _): "Retrying…"
        case (.retry, _, true): "Retried"
        case (.retry, _, _): "Retry"
        }
    }

    private var font: Font {
        switch style {
        case .trailing: .footnote.weight(.semibold)
        case .prominent: .subheadline.weight(.bold)
        case .wide: .subheadline.weight(.semibold)
        }
    }

    private var foreground: Color {
        style == .prominent ? .black : .siloOnSurface
    }

    private var iconColor: Color {
        guard isDone else { return foreground }
        return style == .prominent ? .black : .requestEmerald
    }

    private var background: Color {
        switch style {
        case .prominent: .white
        case .trailing, .wide: .siloChromeSelectedFill
        }
    }
}

/// A failed action's reason, in the status line's slot.
private struct RequestRowErrorLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.circle.fill")
                .imageScale(.small)
            Text(text)
                .lineLimit(2)
        }
        .font(.caption.weight(.semibold))
        .foregroundColor(.requestRose)
    }
}

/// A short horizontal shake each time `trigger` changes.
private struct ShakeOnChange: ViewModifier {
    let trigger: Int

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, offset in
            view.offset(x: offset)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(-7, duration: 0.07)
                CubicKeyframe(6, duration: 0.07)
                CubicKeyframe(-4, duration: 0.07)
                CubicKeyframe(0, duration: 0.09)
            }
        }
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

    /// "Series · 1080p · 4K" for admin rows.
    static func kindAndQuality(_ record: MediaRequest) -> String {
        [record.mediaType.displayName, RequestTargetSummary.qualities(for: record.targets)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
