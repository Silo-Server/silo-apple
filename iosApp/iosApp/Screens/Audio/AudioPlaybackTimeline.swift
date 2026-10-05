import Foundation

enum AudioPlaybackTimeline {
    /// `tracks` must be in book order, as `AudiobookPlaybackContext` builds them.
    static func trackIndex(at globalTime: Double, tracks: [AudioPlaybackTrack]) -> Int? {
        guard !tracks.isEmpty else { return nil }
        let clamped = max(0, globalTime)
        for track in tracks {
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
}
