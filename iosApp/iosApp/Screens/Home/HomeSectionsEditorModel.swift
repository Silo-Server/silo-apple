import Foundation
import Observation
import SwiftUI

/// Drives the Home Sections editors (iOS/macOS Settings → Interface, tvOS
/// Settings → General). It edits the acting profile's layout on the server,
/// so the order and visibility follow the profile to every device, and to
/// the admin's view of that profile. Each change saves at once; saves run one
/// after another, and a refused save puts the last saved layout back
/// unless a later change is queued to carry it.
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
    private(set) var isSaving = false

    @ObservationIgnored private let api: SiloAPI
    @ObservationIgnored private let newID: () -> String
    @ObservationIgnored private var auth: CapturedOrdinaryRequestAuth?
    @ObservationIgnored private var saved: [APIv2SectionOverride] = []
    /// The rows the server last confirmed; a refused save returns here
    /// when no later change is queued.
    @ObservationIgnored private var confirmedRows: [APIv2ProfileSectionSetting] = []
    @ObservationIgnored private var saveChain: Task<Void, Never>?
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
        repeat {
            generation = editGeneration
            await saveChain?.value
        } while generation != editGeneration
        if rows.isEmpty { phase = .loading }
        do {
            let layout = try await api.profileHomeLayout()
            guard generation == editGeneration else { return }
            auth = layout.auth
            saved = layout.saved
            rows = layout.rows
            confirmedRows = layout.rows
            saveError = nil
            phase = .loaded
        } catch {
            guard !(error is CancellationError), !Task.isCancelled, generation == editGeneration else { return }
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
        let previous = saveChain
        // The task holds the model until its save is sent, so closing the
        // editor while an earlier save is in flight does not drop this edit.
        // The chain ends with the last queued save.
        let task = Task {
            await previous?.value
            await self.saveCurrentRows()
        }
        saveChain = task
        return task
    }

    /// Sends the rows as they are now. A change made while this is in flight
    /// queues its own save, which sends the newer rows, so a refused save
    /// leaves those rows on screen for that save to carry.
    private func saveCurrentRows() async {
        guard let auth, rows != confirmedRows else { return }
        let sent = rows
        let sentGeneration = editGeneration
        let overrides = ProfileHomeLayout.overrides(rows: sent, baseline: confirmedRows, saved: saved, newID: newID)
        isSaving = true
        defer { isSaving = false }
        do {
            try await api.saveProfileHomeLayout(overrides, auth: auth)
            saved = overrides
            confirmedRows = sent
            saveError = nil
            Self.refreshHome()
        } catch {
            if editGeneration == sentGeneration {
                rows = confirmedRows
            }
            saveError = "Couldn’t save the Home layout. \(ErrorState(error).message)"
        }
    }

    /// Home renders the server's rows, so it re-reads them after a save
    /// rather than reordering anything locally.
    private static func refreshHome() {
        StartupContentPrefetcher.invalidateHomeSectionsInFlight()
        ResponseCache.shared.remove(CacheKey.homeSections)
        NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
    }
}
