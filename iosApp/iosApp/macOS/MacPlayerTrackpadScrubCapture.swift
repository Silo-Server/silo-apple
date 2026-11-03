#if os(macOS)
import AppKit
import SwiftUI

/// Two-finger trackpad scrubbing; see `TrackpadScrub`.
///
/// Scroll events go to the view under the pointer and up its superviews, so a
/// view behind the player never receives them. A local event monitor reads
/// them instead, keeping only gesture-phased scrolls with precise deltas
/// (trackpad and Magic Mouse, not wheels) that start over the player. A
/// scrub's events, and the momentum after it, are consumed so no other scroll
/// handler acts on the same swipe. When the capture is disabled mid-swipe, the
/// swipe's next event abandons the scrub without seeking.
struct MacPlayerTrackpadScrubCapture: NSViewRepresentable {
    let viewModel: PlayerViewModel
    let isEnabled: Bool

    func makeNSView(context: Context) -> TrackpadScrubCaptureView {
        let view = TrackpadScrubCaptureView()
        view.viewModel = viewModel
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ nsView: TrackpadScrubCaptureView, context: Context) {
        nsView.viewModel = viewModel
        nsView.isEnabled = isEnabled
    }
}

final class TrackpadScrubCaptureView: NSView {
    var viewModel: PlayerViewModel?
    var isEnabled = false

    private var monitor: Any?
    private var consumesMomentum = false

    /// Hosts the monitor only; never takes a click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
            viewModel?.trackpadScrubEnded(committing: false)
        } else {
            installMonitor()
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                self?.consumes(event) == true ? nil : event
            }
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Feeds one scroll event to the scrub. Returns whether the scrub owns it.
    private func consumes(_ event: NSEvent) -> Bool {
        guard event.window === window, event.hasPreciseScrollingDeltas, let viewModel else { return false }
        if !event.momentumPhase.isEmpty { return consumesMomentum }

        let delta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
        if event.phase.contains(.began) {
            consumesMomentum = false
            guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else {
                viewModel.trackpadScrubEnded(committing: false)
                return false
            }
            viewModel.trackpadScrubBegan()
            viewModel.trackpadScrubMoved(by: delta)
        } else if event.phase.contains(.changed) {
            guard isEnabled else {
                viewModel.trackpadScrubEnded(committing: false)
                return false
            }
            viewModel.trackpadScrubMoved(by: delta)
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            let owned = viewModel.isTrackpadScrubbing
            viewModel.trackpadScrubEnded(committing: isEnabled && event.phase.contains(.ended))
            consumesMomentum = owned
            return owned
        }
        return viewModel.isTrackpadScrubbing
    }
}
#endif
