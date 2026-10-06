import Foundation
import SwiftUI

/// Session-scoped sleep timer: pauses playback after the requested interval
/// and exposes `remainingSeconds` for the settings countdown. Main-actor so
/// its countdown task, and the pause it fires, run on the main thread.
@MainActor
@Observable
final class SleepTimer {
    private(set) var isActive: Bool = false
    private(set) var remainingSeconds: Int = 0

    private var task: Task<Void, Never>?
    private var onFire: (@MainActor () -> Void)?

    /// Install the callback that performs the pause action.
    func configure(onFire: @escaping @MainActor () -> Void) {
        self.onFire = onFire
    }

    /// Start or replace the timer. `minutes <= 0` cancels instead.
    func start(minutes: Int) {
        cancel()
        guard minutes > 0 else { return }
        isActive = true
        remainingSeconds = minutes * 60

        task = Task { [weak self] in
            while let self, self.isActive, self.remainingSeconds > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                if self.remainingSeconds > 0 { self.remainingSeconds -= 1 }
            }
            guard let self, self.isActive else { return }
            self.onFire?()
            self.isActive = false
            self.remainingSeconds = 0
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isActive = false
        remainingSeconds = 0
    }
}
