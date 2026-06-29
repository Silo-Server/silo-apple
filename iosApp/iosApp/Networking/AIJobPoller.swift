//
//  AIJobPoller.swift
//  Continuum (iOS + tvOS)
//
//  Generic poller for an AI subtitle job. Emits each fetched ``SubtitleJob``
//  snapshot on a fixed cadence and stops once the job reaches a terminal
//  state (`completed` / `failed` / `cancelled`).
//
//  The `fetch` closure is injected rather than the live ``ContinuumAI``
//  facade so the poller is unit-testable headless — a fake `fetch` can
//  return a scripted sequence of snapshots (see `AIJobPollerTests`). In
//  production the caller passes `{ try await ContinuumAI.shared.subtitleJob(id: $0) }`.
//
//  This is the authority/fallback layer under the (M4) live websocket path:
//  the poller owns `result_subtitle_id` and the completion handoff, so a
//  dropped socket still completes the job over polling.
//

import Foundation

/// Polls a single AI subtitle job to completion, surfacing every snapshot.
///
/// `actor` so the in-flight poll Task and its cancellation are serialized
/// independently of the `@MainActor` controller that drives it. The
/// returned ``AsyncStream`` finishes when the job becomes terminal, when a
/// fetch keeps failing past the retry budget, or when the consuming Task is
/// cancelled (cancelling iteration tears the producer Task down via
/// `onTermination`).
actor AIJobPoller {

    /// Cadence between successive job fetches. Matches the Android client's
    /// ~1.5s job-poll interval.
    static let pollInterval: Duration = .milliseconds(1500)

    /// Consecutive fetch failures tolerated before the stream gives up and
    /// finishes. A transient error (server hiccup, brief network drop) is
    /// retried on the next tick; a sustained outage ends the stream so the
    /// controller can fall back to a terminal "failed" UI rather than poll
    /// forever.
    static let maxConsecutiveFailures = 5

    /// The active poll Task, retained so `cancel()` (and stream teardown)
    /// can stop it. One poller drives at most one job at a time.
    private var task: Task<Void, Never>?

    init() {}

    /// Begin polling `jobId`, emitting each fetched snapshot until the job
    /// is terminal. The first fetch happens immediately (no leading delay)
    /// so the UI reflects server state as soon as possible.
    ///
    /// - Parameters:
    ///   - jobId: the job to poll.
    ///   - fetch: how to fetch one snapshot by id. Injected for testability.
    /// - Returns: a stream of snapshots that finishes on terminal status,
    ///   exhausted retries, or consumer cancellation.
    func poll(
        jobId: String,
        fetch: @escaping @Sendable (String) async throws -> SubtitleJob
    ) -> AsyncStream<SubtitleJob> {
        // Replace any prior in-flight poll — a poller instance drives one
        // job at a time.
        task?.cancel()

        return AsyncStream { continuation in
            let pollTask = Task {
                var consecutiveFailures = 0
                // Emit immediately, then on every `pollInterval` tick.
                while !Task.isCancelled {
                    do {
                        let snapshot = try await fetch(jobId)
                        consecutiveFailures = 0
                        continuation.yield(snapshot)
                        if snapshot.status.isTerminal {
                            break
                        }
                    } catch {
                        if Task.isCancelled { break }
                        consecutiveFailures += 1
                        if consecutiveFailures >= Self.maxConsecutiveFailures {
                            break
                        }
                    }

                    // Sleep between ticks; `Task.sleep` throws on
                    // cancellation, which exits the loop cleanly.
                    do {
                        try await Task.sleep(for: Self.pollInterval)
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }

            self.setTask(pollTask)

            // If the consumer stops iterating (or its Task is cancelled),
            // tear the producer down so we don't keep hitting the network.
            continuation.onTermination = { _ in
                pollTask.cancel()
            }
        }
    }

    /// Cancel the active poll, if any. The stream finishes shortly after.
    func cancel() {
        task?.cancel()
        task = nil
    }

    private func setTask(_ newTask: Task<Void, Never>) {
        task = newTask
    }
}
