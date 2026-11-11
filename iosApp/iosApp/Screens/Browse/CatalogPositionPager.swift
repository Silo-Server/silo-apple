import Foundation

/// The titles of a title-ordered library, read a page at a time by list
/// position and kept for the visit.
///
/// The grid shows every position from the start and tells the pager which
/// ones are on screen. The pager reads those pages and the ones beside them,
/// so a page is usually there before its cards scroll into view, whichever
/// way the grid moves and wherever a jump to a letter lands.
@MainActor
final class CatalogPositionPager {
    /// Reads `limit` titles starting at list position `start`.
    typealias Read = @MainActor (_ start: Int, _ limit: Int) async throws -> [BrowseItem]

    /// The catalog's largest page.
    static let pageSize = 100
    /// Reads in flight at once. A fast scroll passes more pages than this;
    /// the ones it has left behind give way to the ones in view.
    static let maxConcurrentReads = 4
    /// Titles on each side of a letter's first one that a jump lands among.
    private static let landingBefore = 12
    private static let landingAfter = 48

    /// Number of titles in the list.
    let total: Int
    /// Called after a page arrives.
    var onChange: (() -> Void)?

    private let read: Read
    private let retryDelay: Duration
    private var pages: [Int: [BrowseItem]] = [:]
    private var reads: [Int: (id: Int, task: Task<Void, Never>)] = [:]
    /// Pages whose last read failed; skipped until the next retry.
    private var failed: Set<Int> = []
    private var retry: Task<Void, Never>?
    private var lastReadID = 0
    private var visible: Range<Int> = 0..<0
    /// Which way the grid last moved: down the list, up it, or not yet.
    private var movingDown: Bool?
    /// Where a jump is about to land, read ahead of the scroll.
    private var landing: Range<Int>?
    private var isCancelled = false

    init(total: Int, retryDelay: Duration = .seconds(2), read: @escaping Read) {
        self.total = max(0, total)
        self.retryDelay = retryDelay
        self.read = read
    }

    /// The title at `position`, or nil while its page has not arrived.
    func item(at position: Int) -> BrowseItem? {
        guard position >= 0, let page = pages[position / Self.pageSize] else { return nil }
        let offset = position % Self.pageSize
        return offset < page.count ? page[offset] : nil
    }

    /// Whether every page holding `positions` has arrived.
    func isLoaded(_ positions: Range<Int>) -> Bool {
        pageNumbers(positions).allSatisfy { pages[$0] != nil }
    }

    /// Take the titles the grid already has from the start of the list, so
    /// their pages are not read again. A trailing part of a page is left to
    /// be read whole.
    func seed(_ first: [BrowseItem]) {
        var start = 0
        while start < first.count {
            let end = min(start + Self.pageSize, first.count)
            guard end - start == Self.pageSize || end >= total else { break }
            let page = start / Self.pageSize
            if pages[page] == nil { pages[page] = Array(first[start..<end]) }
            start = end
        }
    }

    /// The grid now shows `positions`. Reads their pages, then the pages
    /// beside them, the one it is moving toward first.
    func show(_ positions: Range<Int>) {
        let positions = positions.clamped(to: 0..<total)
        guard positions != visible else { return }
        if !visible.isEmpty, positions.lowerBound != visible.lowerBound {
            movingDown = positions.lowerBound > visible.lowerBound
        }
        visible = positions
        pump()
    }

    /// A jump to `position` may follow: read where it would land.
    func prepareLanding(at position: Int) {
        let range = (position - Self.landingBefore..<position + Self.landingAfter).clamped(to: 0..<total)
        guard range != landing else { return }
        landing = range
        pump()
    }

    /// Reads where a jump to `position` lands and returns once those titles
    /// are there, their read has failed, or `patience` has passed, so the
    /// grid moves to cards rather than to placeholders when the server is
    /// quick enough.
    func awaitLanding(at position: Int, patience: Duration) async {
        prepareLanding(at: position)
        guard let landing else { return }
        let deadline = ContinuousClock.now + patience
        while !isLoaded(landing), failed.isDisjoint(with: pageNumbers(landing)),
              ContinuousClock.now < deadline, !Task.isCancelled, !isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Stop reading; the list this pager reads is no longer shown.
    func cancel() {
        isCancelled = true
        onChange = nil
        retry?.cancel()
        retry = nil
        for read in reads.values { read.task.cancel() }
        reads = [:]
    }

    // MARK: - Reading

    private func pageNumbers(_ positions: Range<Int>) -> ClosedRange<Int> {
        guard !positions.isEmpty else { return 0...0 }
        return positions.lowerBound / Self.pageSize...(positions.upperBound - 1) / Self.pageSize
    }

    /// Pages worth having, most wanted first: the ones on screen, where a
    /// jump would land, then the neighbours of the ones on screen.
    private var wantedPages: [Int] {
        guard total > 0 else { return [] }
        let lastPage = (total - 1) / Self.pageSize
        var wanted: [Int] = []
        func want(_ pages: some Sequence<Int>) {
            for page in pages where (0...lastPage).contains(page) && !wanted.contains(page) {
                wanted.append(page)
            }
        }
        let shown = visible.isEmpty ? nil : pageNumbers(visible)
        if let shown { want(shown) }
        if let landing, !landing.isEmpty { want(pageNumbers(landing)) }
        if let shown {
            let above = shown.lowerBound - 1, below = shown.upperBound + 1
            switch movingDown {
            case true?: want([below, above, below + 1])
            case false?: want([above, below, above - 1])
            case nil: want([below, above])
            }
        }
        return wanted
    }

    private func pump() {
        guard !isCancelled else { return }
        let wanted = wantedPages
        for page in wanted where pages[page] == nil && reads[page] == nil && !failed.contains(page) {
            if reads.count >= Self.maxConcurrentReads {
                // The grid has moved on from some page still being read.
                guard let passed = reads.keys.first(where: { !wanted.contains($0) }) else { break }
                reads.removeValue(forKey: passed)?.task.cancel()
            }
            start(page)
        }
    }

    private func start(_ page: Int) {
        lastReadID += 1
        let id = lastReadID
        let read = read
        let task = Task { [weak self] in
            let items = try? await read(page * Self.pageSize, Self.pageSize)
            // A cancelled or superseded read publishes nothing.
            guard let self, self.reads[page]?.id == id else { return }
            self.reads[page] = nil
            if let items {
                self.pages[page] = items
                self.onChange?()
            } else {
                self.failed.insert(page)
                self.scheduleRetry()
            }
            self.pump()
        }
        reads[page] = (id, task)
    }

    /// Failed pages wait out `retryDelay`, then are read again if the grid
    /// still wants them.
    private func scheduleRetry() {
        guard retry == nil else { return }
        retry = Task { [weak self, retryDelay] in
            try? await Task.sleep(for: retryDelay)
            guard let self, !Task.isCancelled else { return }
            self.retry = nil
            self.failed = []
            self.pump()
        }
    }
}
