import Foundation

/// What in this process may still start each record's transfer: a pipeline
/// fetching the manifest, or a retry waiting out its back-off. Either one
/// survives an app suspension, so a reconcile must leave its record alone;
/// re-queuing it would start a second transfer of the file. Also tracks the
/// artwork and subtitle fetch that follows a started transfer.
struct DownloadRestartOwners: Equatable {
    /// Record id → token of the one pipeline allowed to start its transfer.
    private var pipelines: [String: UUID] = [:]
    /// Record id → when its scheduled retry fires.
    private var retries: [String: Date] = [:]
    /// Record id → token of the one fetch allowed to save its artwork and
    /// subtitles. It runs alongside the transfer and holds no queue slot.
    private var assets: [String: UUID] = [:]

    /// Hands the record to a new pipeline. Any pipeline already running for
    /// it loses ownership and stops at its next check.
    mutating func claimPipeline(_ recordId: String) -> UUID {
        let token = UUID()
        pipelines[recordId] = token
        return token
    }

    func ownsPipeline(_ recordId: String, _ token: UUID) -> Bool {
        pipelines[recordId] == token
    }

    func hasPipeline(_ recordId: String) -> Bool {
        pipelines[recordId] != nil
    }

    /// Pipelines running now. A retry waiting out its back-off isn't one.
    var pipelineCount: Int { pipelines.count }

    /// Ends the pipeline holding `token`. A superseded pipeline releases
    /// nothing, so it can't free the record from its replacement.
    mutating func releasePipeline(_ recordId: String, _ token: UUID) {
        if pipelines[recordId] == token { pipelines[recordId] = nil }
    }

    /// Takes the record away from its running pipeline.
    mutating func abandonPipeline(_ recordId: String) {
        pipelines[recordId] = nil
    }

    mutating func retryScheduled(_ recordId: String, firesAt date: Date) {
        retries[recordId] = date
    }

    /// The retry fired or was cancelled.
    mutating func retryEnded(_ recordId: String) {
        retries[recordId] = nil
    }

    /// Whether a pipeline or retry in this process owns the record's restart.
    func ownsRestart(_ recordId: String) -> Bool {
        pipelines[recordId] != nil || retries[recordId] != nil
    }

    /// Hands the record's artwork and subtitles to a new fetch. One already
    /// running stops saving at its next check.
    mutating func claimAssets(_ recordId: String) -> UUID {
        let token = UUID()
        assets[recordId] = token
        return token
    }

    /// Whether an asset fetch for the record is running.
    func fetchesAssets(_ recordId: String) -> Bool {
        assets[recordId] != nil
    }

    func ownsAssets(_ recordId: String, _ token: UUID) -> Bool {
        assets[recordId] == token
    }

    mutating func releaseAssets(_ recordId: String, _ token: UUID) {
        if assets[recordId] == token { assets[recordId] = nil }
    }

    /// Stops the record's asset fetch from saving anything more.
    mutating func abandonAssets(_ recordId: String) {
        assets[recordId] = nil
    }

    /// Whether work in this process may still need the network by
    /// `deadline`: a pipeline or asset fetch is running, or a retry fires
    /// by then.
    func handoffPending(by deadline: Date) -> Bool {
        !pipelines.isEmpty || !assets.isEmpty || retries.values.contains { $0 <= deadline }
    }

    mutating func removeAll() {
        pipelines.removeAll()
        retries.removeAll()
        assets.removeAll()
    }
}
