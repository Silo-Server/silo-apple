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
/// handler acts on the same swipe. Disabling the capture mid-swipe abandons the
/// scrub without seeking, and the rest of that swipe does nothing.
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
    /// Turning off abandons a swipe in progress at once, so a swipe that rests
    /// while the options panel opens and closes doesn't seek on lift-off.
    var isEnabled = false {
        didSet {
            if oldValue, !isEnabled { viewModel?.trackpadScrubEnded(committing: false) }
        }
    }

    private var monitor: Any?
    private var consumesMomentum = false
    /// The current swipe has scrubbed, so its remaining events are consumed.
    private var ownsSwipe = false

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

    /// Feeds one scroll event to the scrub. Returns whether the swipe owns it.
    private func consumes(_ event: NSEvent) -> Bool {
        guard event.window === window, event.hasPreciseScrollingDeltas, let viewModel else { return false }
        if !event.momentumPhase.isEmpty { return consumesMomentum }

        let delta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
        if event.phase.contains(.began) {
            consumesMomentum = false
            ownsSwipe = false
            guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else {
                viewModel.trackpadScrubEnded(committing: false)
                return false
            }
            viewModel.trackpadScrubBegan()
            viewModel.trackpadScrubMoved(by: delta)
        } else if event.phase.contains(.changed) {
            if isEnabled {
                viewModel.trackpadScrubMoved(by: delta)
            } else {
                viewModel.trackpadScrubEnded(committing: false)
            }
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            let owned = ownsSwipe || viewModel.isTrackpadScrubbing
            viewModel.trackpadScrubEnded(committing: isEnabled && event.phase.contains(.ended))
            consumesMomentum = owned
            ownsSwipe = false
            return owned
        }
        // A swipe that scrubbed keeps its events until the fingers lift, even
        // after its scrub ends, so nothing else under the pointer scrolls.
        ownsSwipe = ownsSwipe || viewModel.isTrackpadScrubbing
        return ownsSwipe
    }
}
#endif
