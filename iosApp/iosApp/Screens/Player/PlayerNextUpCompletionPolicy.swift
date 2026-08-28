import Foundation

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

    static func shouldFinalizeAsCompleted(
        isNextUpPresented: Bool,
        hasReachedEndOfFile: Bool,
        endedPrematurely: Bool = false,
        currentTime: Double,
        duration: Double,
        promptSeconds: Int
    ) -> Bool {
        // A connection-reset EOS still latches `hasReachedEndOfFile` so the
        // player stays paused, but it is not a natural finish. Treating it as
        // one would overwrite the real resume point with "watched".
        if endedPrematurely {
            return false
        }
        if hasReachedEndOfFile {
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
        endedPrematurely: Bool = false,
        currentTime: Double,
        duration: Double,
        promptSeconds: Int
    ) -> Double {
        guard duration.isFinite, duration > 0 else {
            return currentTime
        }
        return shouldFinalizeAsCompleted(
            isNextUpPresented: isNextUpPresented,
            hasReachedEndOfFile: hasReachedEndOfFile,
            endedPrematurely: endedPrematurely,
            currentTime: currentTime,
            duration: duration,
            promptSeconds: promptSeconds
        ) ? duration : currentTime
    }
}
