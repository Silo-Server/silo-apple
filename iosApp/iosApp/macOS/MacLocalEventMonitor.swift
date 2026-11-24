#if os(macOS)
import AppKit

/// An `NSEvent` local monitor whose handler runs on the main actor. Return
/// the event to pass it on, or nil to use it up.
@MainActor
final class MacLocalEventMonitor {
    private var token: Any?

    init(matching mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (NSEvent) -> NSEvent?) {
        token = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            let input = MainThreadEvent(value: event)
            return MainActor.assumeIsolated {
                MainThreadEvent(value: input.value.flatMap(handler))
            }.value
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    /// AppKit runs local monitors on the main thread, so the event never
    /// leaves it; the box only carries it into the main-actor closure.
    private struct MainThreadEvent: @unchecked Sendable {
        let value: NSEvent?
    }
}
#endif
