import Foundation

enum AudioPlaybackTimeline {
    static func trackIndex(at globalTime: Double, tracks: [AudioPlaybackTrack]) -> Int? {
        guard !tracks.isEmpty else { return nil }
        let clamped = max(0, globalTime)
        for track in tracks.sorted(by: { $0.index < $1.index }) {
            let start = track.startOffsetSeconds
            let end = start + max(0, track.durationSeconds)
            if clamped >= start && clamped < end {
                return track.index
            }
        }
        return tracks.last?.index
    }

    static func localTime(for globalTime: Double, in track: AudioPlaybackTrack) -> Double {
        let local = globalTime - track.startOffsetSeconds
        return min(max(0, local), max(0, track.durationSeconds))
    }

    static func globalTime(for localTime: Double, in track: AudioPlaybackTrack) -> Double {
        track.startOffsetSeconds + min(max(0, localTime), max(0, track.durationSeconds))
    }

    /// The chapter the playhead at `globalTime` is inside: the last one that
    /// starts at or before it, and the first of several sharing that start.
    /// Nil before the first chapter. `chapters` must be sorted by
    /// `startSeconds`, as `AudiobookPlaybackContext` builds them.
    static func chapter(at globalTime: Double, in chapters: [AudioPlaybackChapter]) -> AudioPlaybackChapter? {
        // Binary search for the first chapter that starts after the playhead.
        var low = 0
        var high = chapters.count
        while low < high {
            let mid = (low + high) / 2
            if chapters[mid].startSeconds <= globalTime {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low > 0 else { return nil }
        var index = low - 1
        while index > 0, chapters[index - 1].startSeconds == chapters[index].startSeconds {
            index -= 1
        }
        return chapters[index]
    }
}
