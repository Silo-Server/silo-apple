import Foundation
import Observation
import SwiftUI

/// Drives the Home Sections editors (iOS/macOS Settings → Interface, tvOS
/// Settings → General). It edits the acting profile's layout on the server,
/// so the order and visibility follow the profile to every device, and to
/// the admin's view of that profile. Each change saves at once; saves from
/// every editor run one after another, and a failed save reads the layout
/// back from the server unless a later change is queued to carry it.
@Observable
@MainActor
final class HomeSectionsEditorModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    /// Every Home row of the profile in display order, hidden rows included.
    private(set) var rows: [APIv2ProfileSectionSetting] = []
    /// Why the last change could not be saved, or the last reload failed
    /// while rows were already on screen.
    private(set) var saveError: String?

    @ObservationIgnored private let api: SiloAPI
    @ObservationIgnored private let newID: () -> String
    @ObservationIgnored private var auth: CapturedOrdinaryRequestAuth?
    @ObservationIgnored private var saved: [APIv2SectionOverride] = []
    /// The rows the server last confirmed.
    @ObservationIgnored private var confirmedRows: [APIv2ProfileSectionSetting] = []
    /// Set when a save failed and a later change was queued before the
    /// layout could be read back. The server may or may not hold the failed
    /// save, so the queued save sends its rows even when they match
    /// `confirmedRows`.
    @ObservationIgnored private var serverMayDiffer = false
    /// Every editor's saves, in order. Shared, so an editor opened while a
    /// closed one's save is still in flight reads the layout after it lands
    /// rather than before, and its own saves never race that one.
    private static var saveChain: Task<Void, Never>?
    /// Counts edits, so a load can tell whether one happened while it read.
    @ObservationIgnored private var editGeneration = 0

    init(api: SiloAPI = .shared, newID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.api = api
        self.newID = newID
    }

    /// Reads the layout once every queued save has landed, including one
    /// queued while this waited. An edit made while the read is in flight
    /// wins: the read is dropped, because it may predate that edit's save,
    /// and the edit's own save carries on.
    func load() async {
        var generation: Int
        var awaited: Task<Void, Never>?
        repeat {
            generation = editGeneration
            awaited = Self.saveChain
            await awaited?.value
        } while generation != editGeneration || awaited != Self.saveChain
        let previousPhase = phase
        if rows.isEmpty { phase = .loading }
        do {
            let layout = try await api.profileHomeLayout()
            guard generation == editGeneration else { return }
            adopt(layout)
            saveError = nil
        } catch {
            guard generation == editGeneration else { return }
            guard !(error is CancellationError), !Task.isCancelled else {
                // A cancelled read (a pull to refresh the view dropped)
                // leaves the editor as it was, not on a spinner.
                if phase == .loading, rows.isEmpty { phase = previousPhase }
                return
            }
            let message = ErrorState(error).message
            if rows.isEmpty {
                phase = .failed(message)
            } else {
                saveError = message
            }
        }
    }

    func canMove(id: String, by offset: Int) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return false }
        return rows.indices.contains(index + offset)
    }

    // The edits below change `rows` at once, so a List drag or a focused
    // tvOS button sees the new order before the save leaves, and return the
    // queued save so a caller (or a test) can wait for it.

    @discardableResult
    func move(fromOffsets source: IndexSet, toOffset destination: Int) -> Task<Void, Never> {
        var next = rows
        next.move(fromOffsets: source, toOffset: destination)
        return apply(next)
    }

    @discardableResult
    func move(id: String, by offset: Int) -> Task<Void, Never> {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows.indices.contains(index + offset) else {
            return Task {}
        }
        var next = rows
        next.swapAt(index, index + offset)
        return apply(next)
    }

    @discardableResult
    func setHidden(_ hidden: Bool, id: String) -> Task<Void, Never> {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return Task {} }
        var next = rows
        next[index].hidden = hidden
        return apply(next)
    }

    private func apply(_ next: [APIv2ProfileSectionSetting]) -> Task<Void, Never> {
        guard phase == .loaded, next != rows else { return Task {} }
        rows = next
        saveError = nil
        editGeneration += 1
        let previous = Self.saveChain
        // The task holds the model until its save is sent, so closing the
        // editor while an earlier save is in flight does not drop this edit.
        // The chain ends with the last queued save.
        let task = Task {
            await previous?.value
            await self.saveCurrentRows()
        }
        Self.saveChain = task
        return task
    }

    /// Sends the rows as they are now. A change made while this is in flight
    /// queues its own save, which sends the newer rows. When this save fails
    /// with no newer change queued, the layout is read back: a save whose
    /// reply was lost may still have been stored.
    private func saveCurrentRows() async {
        guard let auth else { return }
        guard rows != confirmedRows || serverMayDiffer else {
            saveError = nil
            return
        }
        let sent = rows
        let sentGeneration = editGeneration
        let overrides = ProfileHomeLayout.overrides(rows: sent, baseline: confirmedRows, saved: saved, newID: newID)
        do {
            try await api.saveProfileHomeLayout(overrides, auth: auth)
            saved = overrides
            confirmedRows = sent
            serverMayDiffer = false
            saveError = nil
            Self.refreshHome()
        } catch {
            let message = AppLanguage.string(.homeProfileEditorSaveFailed(ErrorState(error).message))
            guard editGeneration == sentGeneration else {
                // The queued save carries the newer rows; it must send them
                // whatever the server now holds.
                serverMayDiffer = true
                saveError = message
                return
            }
            await readBack(after: sent, owner: auth, failure: message)
        }
    }

    /// Reconciles with the server after a failed save of `sent` for
    /// `owner`: shows what it holds, refreshes Home when that changed, and
    /// otherwise reports `failure`. The read is for `owner` only, so after a
    /// profile switch it is refused rather than loading someone else's
    /// layout. If the read fails, the last confirmed rows come back.
    private func readBack(after sent: [APIv2ProfileSectionSetting], owner: CapturedOrdinaryRequestAuth,
                          failure: String) async {
        let generation = editGeneration
        let layout = try? await api.profileHomeLayout(owner: owner)
        guard generation == editGeneration else {
            serverMayDiffer = true
            saveError = failure
            return
        }
        guard let layout else {
            rows = confirmedRows
            serverMayDiffer = true
            saveError = failure
            return
        }
        // The server rewrites positions and `customized` once it stores a
        // change, so compare what the editor changes: order and visibility.
        let held = Self.arrangement(layout.rows)
        let stored = held == Self.arrangement(sent)
        // Home refreshes when the server holds this save, or when its layout
        // moved anyway (an earlier save whose reply was lost). Home may
        // already have read such an earlier save, so a stored save refreshes
        // even when it puts back the last confirmed layout.
        let moved = held != Self.arrangement(confirmedRows)
        adopt(layout)
        if stored || moved { Self.refreshHome() }
        saveError = stored ? nil : failure
    }

    private static func arrangement(_ rows: [APIv2ProfileSectionSetting]) -> [String] {
        rows.map { "\($0.id)\u{0}\($0.hidden)" }
    }

    private func adopt(_ layout: APIv2ProfileHomeLayoutRead) {
        auth = layout.auth
        saved = layout.saved
        rows = layout.rows
        confirmedRows = layout.rows
        serverMayDiffer = false
        phase = .loaded
    }

    /// Home renders the server's rows, so it re-reads them after a save
    /// rather than reordering anything locally.
    private static func refreshHome() {
        StartupContentPrefetcher.invalidateHomeSectionsInFlight()
        ResponseCache.shared.remove(CacheKey.homeSections)
        NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
    }
}
