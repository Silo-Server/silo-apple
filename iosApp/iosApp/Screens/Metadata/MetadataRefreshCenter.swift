#if os(iOS)
import SwiftUI

/// Non-blocking status toast shown after metadata curation actions and while
/// background refresh jobs run on the server.
struct MetadataToastState: Equatable, Identifiable {
    enum Style: Equatable {
        case running
        case success
        case info
        case error
    }

    let id = UUID()
    let message: String
    let style: Style
}

/// Session-scoped runner for asynchronous Quick/Complete metadata refresh jobs
/// and global curation status toasts.
///
/// Tracking jobs at session scope ensures leaving a detail view (or kicking
/// off a second refresh) never drops cache invalidation for an accepted server
/// job. Every submission and poll is pinned to the single captured owner so a
/// server or profile switch never polls a foreign job ID or invalidates the
/// new identity's cache.
@MainActor
@Observable
final class MetadataRefreshCenter {
    static let shared = MetadataRefreshCenter()

    private(set) var toast: MetadataToastState?

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var jobTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeRefreshJobs: [(id: UUID, message: String)] = []
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func startRefresh(target: MetadataCurationTarget, mode: MetadataRefreshMode) {
        let gen = generation
        let taskKey = UUID()
        let runningMessage = MetadataStrings.refreshingToast(title: target.displayTitle, mode: mode)
        activeRefreshJobs.append((id: taskKey, message: runningMessage))
        dismissTask?.cancel()
        toast = MetadataToastState(message: runningMessage, style: .running)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.jobTasks.removeValue(forKey: taskKey)
                self.activeRefreshJobs.removeAll { $0.id == taskKey }
            }

            guard let auth = await SiloAPI.shared.apiV2Client.ownerOrCurrent(nil) else {
                if !Task.isCancelled && self.generation == gen {
                    self.activeRefreshJobs.removeAll { $0.id == taskKey }
                    self.showTransientToast(MetadataStrings.refreshFailedToast(nil), style: .error, duration: 4.5)
                }
                return
            }

            do {
                let job = try await SiloAPI.shared.apiV2Client.refreshAdminItemMetadata(
                    id: target.contentId,
                    mode: mode,
                    auth: auth
                )
                let finalJob = try await self.pollJobToCompletion(
                    initial: job,
                    target: target,
                    auth: auth,
                    generation: gen,
                    taskKey: taskKey
                )
                let stillOwner = await SiloAPI.shared.isCurrentOwner(auth)
                guard !Task.isCancelled, self.generation == gen, stillOwner else { return }
                self.activeRefreshJobs.removeAll { $0.id == taskKey }

                guard finalJob.isTerminal else {
                    self.showTransientToast(
                        MetadataStrings.refreshStillRunningToast(title: target.displayTitle),
                        style: .info,
                        duration: 4.5
                    )
                    return
                }

                if finalJob.isSuccess {
                    let newId = finalJob.itemResult?.detailContentId
                        ?? finalJob.itemResult?.refreshContentId
                    let replacedId = (newId != nil && newId != target.contentId) ? newId : nil
                    MetadataCurationCache.invalidateAfterMutation(
                        contentId: target.contentId,
                        replacedByContentId: replacedId,
                        seriesId: target.seriesId
                    )
                    self.showTransientToast(
                        MetadataStrings.refreshedToast(title: target.displayTitle),
                        style: .success
                    )
                } else {
                    self.showTransientToast(
                        MetadataStrings.refreshFailedToast(finalJob.failure?.displayMessage),
                        style: .error,
                        duration: 4.5
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                let stillOwner = await SiloAPI.shared.isCurrentOwner(auth)
                guard !Task.isCancelled, self.generation == gen, stillOwner else { return }
                self.activeRefreshJobs.removeAll { $0.id == taskKey }
                self.showTransientToast(
                    MetadataStrings.refreshFailedToast(MetadataStrings.errorMessage(from: error)),
                    style: .error,
                    duration: 4.5
                )
            }
        }
        jobTasks[taskKey] = task
    }

    func showTransientToast(
        _ message: String,
        style: MetadataToastState.Style = .success,
        duration: TimeInterval = 3.0
    ) {
        dismissTask?.cancel()
        let next = MetadataToastState(message: message, style: style)
        toast = next
        let gen = generation
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self,
                  !Task.isCancelled,
                  self.generation == gen,
                  self.toast?.id == next.id else { return }
            if let remaining = self.activeRefreshJobs.last {
                self.toast = MetadataToastState(message: remaining.message, style: .running)
            } else {
                self.toast = nil
            }
        }
    }

    /// Cancels all tracked jobs and clears any visible toast on sign-out,
    /// profile switch, or server switch.
    func reset() {
        generation &+= 1
        for task in jobTasks.values { task.cancel() }
        jobTasks.removeAll()
        activeRefreshJobs.removeAll()
        dismissTask?.cancel()
        dismissTask = nil
        toast = nil
    }

    /// Polls an accepted refresh job to completion. Tolerates up to 3 consecutive
    /// transient poll failures, and if the job is still running past the initial
    /// window, notifies the user once with an `.info` toast while continuing
    /// background polls so cache invalidation and route replacement still run.
    private func pollJobToCompletion(
        initial: AdminTaskJob,
        target: MetadataCurationTarget,
        auth: CapturedOrdinaryRequestAuth,
        generation gen: Int,
        taskKey: UUID
    ) async throws -> AdminTaskJob {
        var current = initial
        var attempts = 0
        var consecutiveErrors = 0
        var notifiedStillRunning = false
        let fastWindow = 120
        let maxAttempts = 240

        while !current.isTerminal && attempts < maxAttempts {
            try Task.checkCancellation()
            let delayMs: UInt64
            if attempts < 10 {
                delayMs = 750
            } else if attempts < fastWindow {
                delayMs = 1_500
            } else {
                delayMs = 5_000
            }
            try await Task.sleep(for: .milliseconds(delayMs))
            try Task.checkCancellation()

            do {
                current = try await SiloAPI.shared.apiV2Client.adminJob(id: current.id, auth: auth)
                consecutiveErrors = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                consecutiveErrors += 1
                if consecutiveErrors >= 3 {
                    throw error
                }
            }
            attempts += 1

            if !current.isTerminal && attempts == fastWindow && !notifiedStillRunning {
                notifiedStillRunning = true
                let stillOwner = await SiloAPI.shared.isCurrentOwner(auth)
                guard !Task.isCancelled, self.generation == gen, stillOwner else {
                    throw CancellationError()
                }
                self.activeRefreshJobs.removeAll { $0.id == taskKey }
                self.showTransientToast(
                    MetadataStrings.refreshStillRunningToast(title: target.displayTitle),
                    style: .info,
                    duration: 4.5
                )
            }
        }
        return current
    }
}

/// Compact monochrome Liquid Glass status pill anchored near the bottom edge.
struct MetadataStatusToastPill: View {
    let state: MetadataToastState

    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch state.style {
                case .running:
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.siloPrimary)
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.siloPrimary)
                case .info:
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MetadataPalette.lockedAmber)
                case .error:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MetadataPalette.destructiveRed)
                }
            }

            Text(state.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.siloOnSurface)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .siloGlass(in: Capsule(), tint: Color.black.opacity(0.55))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
        .accessibilityElement(children: .combine)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
#endif
