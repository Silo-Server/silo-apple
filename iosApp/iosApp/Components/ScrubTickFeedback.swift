import SwiftUI

extension View {
    /// Plays a selection haptic each time a scrub crosses one of the tick
    /// marks drawn at `tickTimes`. Pass the same times the bar draws, in any
    /// order. `scrubTime` is nil outside a drag on the bar, so starting or
    /// ending a scrub is silent.
    func scrubTickFeedback(tickTimes: [Double], scrubTime: Double?) -> some View {
        sensoryFeedback(trigger: scrubTime.map { ScrubTicks.passed(tickTimes, at: $0) }) { old, new in
            old != nil && new != nil ? .selection : nil
        }
    }
}

enum ScrubTicks {
    /// How many ticks sit at or before `time`. The count changes exactly when
    /// the scrub head crosses a tick, whichever way it moves.
    static func passed(_ tickTimes: [Double], at time: Double) -> Int {
        tickTimes.filter { $0 <= time }.count
    }
}
