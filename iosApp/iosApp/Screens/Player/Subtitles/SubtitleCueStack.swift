import AetherEngine
import Foundation

/// Text subtitles on screen at the same time, one above the other.
///
/// Every text cue without a placement of its own is drawn at the same spot,
/// so two shown at once (a sign or name card while dialogue continues, or two
/// speakers) landed on top of each other. The overlay draws them as one block
/// instead, in the order this returns, bottom first.
///
/// A caption that stays on screen keeps its line, the way a browser keeps a
/// WebVTT cue box it has already placed: a new caption takes the line a
/// finished one left, bottom first, and otherwise goes on top. A card shown
/// across two lines of dialogue therefore stays where it is while the dialogue
/// changes. Captions that appear together go earliest at the bottom. A repeat
/// of a caption already in the block is dropped: drawn in the same place it
/// was invisible, and stacked it would show twice.
///
/// Cues with an authored placement, bitmap cues and empty cues are not
/// stacked. A reference type so the overlay can update it while computing its
/// body, like ``SubtitleCueCursor``; keep one per subtitle layer.
final class SubtitleCueStack {
    /// Caption texts in the bottom-up order last returned.
    private var lastOrder: [String] = []

    /// Whether `cue` joins the block: text that draws something, with no
    /// placement of its own.
    static func stacks(_ cue: SubtitleCue) -> Bool {
        cue.placement == nil && !caption(cue).isEmpty
    }

    /// `cues`, all of which ``stacks(_:)``, one per caption text, bottom first.
    func bottomUp(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        var seen = Set<String>()
        let captions = cues.enumerated()
            .sorted { ($0.element.startTime, $0.offset) < ($1.element.startTime, $1.offset) }
            .map(\.element)
            .filter { seen.insert(Self.caption($0)).inserted }
        let byCaption = Dictionary(uniqueKeysWithValues: captions.map { (Self.caption($0), $0) })
        var arriving = captions.filter { !lastOrder.contains(Self.caption($0)) }[...]

        var order: [SubtitleCue] = []
        for shown in lastOrder {
            if let still = byCaption[shown] {
                order.append(still)
            } else if let next = arriving.popFirst() {
                order.append(next)
            }
        }
        order.append(contentsOf: arriving)
        lastOrder = order.map(Self.caption)
        return order
    }

    private static func caption(_ cue: SubtitleCue) -> String {
        cue.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
