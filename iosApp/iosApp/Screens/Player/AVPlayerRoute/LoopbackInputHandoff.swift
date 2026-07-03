import Foundation
import Libavformat

/// Hands the open source `AVFormatContext` from a stopping VOD producer to
/// its restart replacement, so a seek-triggered producer swap skips
/// `avformat_open_input` + `find_stream_info` + the matroska cue warm
/// against the remote source (~1–1.5 s of every seek).
///
/// Thread contract: the retiring writer publishes from its mux queue during
/// teardown (interrupt callback already detached); the successor claims from
/// its own mux queue with a bounded wait. Exactly one side ends up owning
/// the context; an unclaimed published context is closed by `deinit`.
final class LoopbackInputHandoff {
    private let lock = NSCondition()
    private var context: UnsafeMutablePointer<AVFormatContext>?
    private var published = false
    private var abandoned = false

    deinit {
        if context != nil {
            avformat_close_input(&context)
        }
    }

    /// Retiring writer: transfer ownership of the open input. Closes it
    /// immediately if the successor already gave up waiting.
    func publish(_ ctx: UnsafeMutablePointer<AVFormatContext>) {
        lock.lock()
        if abandoned {
            lock.unlock()
            var doomed: UnsafeMutablePointer<AVFormatContext>? = ctx
            avformat_close_input(&doomed)
            return
        }
        context = ctx
        published = true
        lock.broadcast()
        lock.unlock()
    }

    /// Retiring writer: nothing will be published (input already closed or
    /// never opened). Wakes the successor so it opens fresh immediately
    /// instead of riding out its claim timeout.
    func cancelPublication() {
        lock.lock()
        abandoned = true
        lock.broadcast()
        lock.unlock()
    }

    /// Successor: wait up to `timeout` for the retiring producer's input.
    /// Returns nil (and releases the publisher to close the context itself)
    /// when the handoff is cancelled or the wait times out.
    func claim(timeout: TimeInterval) -> UnsafeMutablePointer<AVFormatContext>? {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock()
        while !published, !abandoned, Date() < deadline {
            lock.wait(until: deadline)
        }
        let claimed = context
        context = nil
        if claimed == nil {
            abandoned = true
        }
        lock.unlock()
        return claimed
    }
}
