import Foundation

/// A repeated Play Now/countdown action for the active (or loading) episode
/// is an expansion, not permission to replace that episode again.
enum PlayerNextUpPlaybackAction: Equatable {
    case unavailable
    case waitForPicture
    case expand
    case load(String)

    static func resolve(candidateId: String?, currentId: String?, awaitingPicture: Bool = false) -> Self {
        if awaitingPicture { return .waitForPicture }
        guard let candidateId else { return .unavailable }
        return candidateId == currentId ? .expand : .load(candidateId)
    }
}

enum PlayerNextUpCompletionPolicy {
    static func isInPromptWindow(
        currentTime: Double,
        duration: Double,
        promptSeconds: Int
    ) -> Bool {
        guard promptSeconds > 0,
              duration.isFinite,
              duration > 0,
              currentTime.isFinite else {
            return false
        }

        let remaining = duration - currentTime
        return remaining >= 0 && remaining <= Double(promptSeconds)
    }

    /// `skippedCredits` means the viewer skipped credits that run to the end
    /// of the file. The credits keep playing, but the item is finished, as a
    /// jump to EOF would have made it. An end of file that stopped short of
    /// the duration is a lost source, not a finish.
    static func shouldFinalizeAsCompleted(
        isNextUpPresented: Bool,
        hasReachedEndOfFile: Bool,
        currentTime: Double,
        duration: Double,
        promptSeconds: Int,
        skippedCredits: Bool = false
    ) -> Bool {
        if skippedCredits {
            return true
        }
        if hasReachedEndOfFile,
           PlayerEndOfFilePolicy.isFinish(position: currentTime, duration: duration) {
            return true
        }
        guard isNextUpPresented else { return false }
        return isInPromptWindow(
            currentTime: currentTime,
            duration: duration,
            promptSeconds: promptSeconds
        )
    }

    static func progressPosition(
        isNextUpPresented: Bool,
        hasReachedEndOfFile: Bool,
        currentTime: Double,
        duration: Double,
        promptSeconds: Int,
        skippedCredits: Bool = false
    ) -> Double {
        guard duration.isFinite, duration > 0 else {
            return currentTime
        }
        return shouldFinalizeAsCompleted(
            isNextUpPresented: isNextUpPresented,
            hasReachedEndOfFile: hasReachedEndOfFile,
            currentTime: currentTime,
            duration: duration,
            promptSeconds: promptSeconds,
            skippedCredits: skippedCredits
        ) ? duration : currentTime
    }
}

/// Tells a finished item from a source that stopped early. FFmpeg reports end
/// of stream when the upstream connection resets, so an end of file alone
/// does not mean the viewer reached the end.
enum PlayerEndOfFilePolicy {
    /// An end this close to the duration is a finish.
    static let finishWindowSeconds: Double = 8

    /// An unknown duration or position cannot prove the end was early.
    static func isFinish(position: Double, duration: Double) -> Bool {
        guard duration.isFinite, duration > 0, position.isFinite, position > 0 else {
            return true
        }
        return duration - position <= finishWindowSeconds
    }

    /// A playback error this close to the end is the stream running out, so
    /// it takes the end-of-file path instead of the error ladder. That path
    /// still reopens an error that stopped more than `finishWindowSeconds`
    /// short.
    static func treatsPlaybackErrorAsEnd(position: Double, duration: Double) -> Bool {
        guard duration.isFinite, duration > 0, position.isFinite, position > 0 else {
            return false
        }
        return duration - position <= finishWindowSeconds || isLate(position: position, duration: duration)
    }

    /// Past this share of the duration, an end that a reopen cannot get past
    /// is the end of the file.
    static func isLate(position: Double, duration: Double) -> Bool {
        guard duration.isFinite, duration > 0, position.isFinite, position > 0 else {
            return false
        }
        return position / duration >= 0.985
    }
}

enum PlayerEndOfFileOutcome: Equatable {
    case finish
    /// The source stopped early; reopen it where it stopped.
    case reopen
    /// The source stopped early and cannot be reopened again.
    case lostSource
}

/// Bounds same-route reopens after a premature end of file. The first reopen
/// is free; another needs real playback since the last one, so a connection
/// that keeps dropping is retried while a truncated file fails fast.
struct PlayerPrematureEndReopenBudget {
    static let playbackBeforeAnotherReopen: Double = 30
    /// Larger playhead jumps are seeks or reloads, not playback.
    static let maximumPlaybackTick: Double = 5
    /// A reopen that ends again within this much playback found where the
    /// file really ends.
    static let stalledReopenPlayback: Double = 10

    private var hasReopened = false
    private var playbackSinceReopen: Double = 0

    mutating func notePlayhead(from old: Double, to new: Double) {
        guard hasReopened, old.isFinite, new.isFinite else { return }
        let advance = new - old
        guard advance > 0, advance <= Self.maximumPlaybackTick else { return }
        playbackSinceReopen += advance
    }

    /// What an end of file at `position` means, consuming a reopen when it
    /// takes one. A viewer who skipped credits to the end has finished. A
    /// stored duration can overshoot the last packet by more than the finish
    /// window; the reopen then ends again almost at once, and late in the
    /// file that is the real end rather than a lost connection.
    mutating func resolveEnd(
        position: Double,
        duration: Double,
        skippedCredits: Bool
    ) -> PlayerEndOfFileOutcome {
        if skippedCredits || PlayerEndOfFilePolicy.isFinish(position: position, duration: duration) {
            return .finish
        }
        if claimReopen() {
            return .reopen
        }
        if playbackSinceReopen < Self.stalledReopenPlayback,
           PlayerEndOfFilePolicy.isLate(position: position, duration: duration) {
            return .finish
        }
        return .lostSource
    }

    /// Consumes a reopen when one is allowed.
    mutating func claimReopen() -> Bool {
        guard !hasReopened || playbackSinceReopen >= Self.playbackBeforeAnotherReopen else {
            return false
        }
        hasReopened = true
        playbackSinceReopen = 0
        return true
    }
}
