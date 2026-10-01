import AetherEngine
import Foundation

/// Many community Arabic and Hebrew subtitle files are written for players that
/// lay every line out left to right. To look right there, the author moves each
/// line's neutral punctuation to the opposite logical end: the sentence's
/// closing `...` or `!` comes first, a dialogue dash comes last. Laid out the
/// Unicode way, right to left, that punctuation lands on the wrong side.
///
/// A track reads as LTR-authored when its right-to-left lines carry those
/// signals and almost none of the logical-order ones. Such a track gets a
/// left-to-right mark at the start of each right-to-left line, which gives the
/// line the left-to-right base direction its author wrote it for. Arabic and
/// Hebrew words still render right to left inside it.
///
/// silo-server applies the same rule to sidecar and downloaded files, so a
/// marked line no longer counts as right-to-left and is left alone here. This
/// copy covers text tracks embedded in the media file.
enum LTRAuthoredSubtitles {
    /// U+200E LEFT-TO-RIGHT MARK. As a line's first strong character it sets
    /// the line's base direction to left to right (Unicode bidi rules P2/P3).
    static let leftToRightMark = "\u{200E}"

    /// Signal counts below which a track is left alone. Three signals rule out
    /// a lone stray dash; the ratio keeps a logical file that happens to open
    /// a few lines with an ellipsis on its own layout.
    private static let minimumSignals = 3
    private static let dominanceRatio = 3

    /// One track's evidence, gathered across cue publishes. An embedded track
    /// reaches the overlay as a window around the playhead, so each cue counts
    /// once and a decision, once reached, holds for the rest of the track.
    struct Track {
        private var trackID: Int64?
        private var countedCueIDs: Set<Int> = []
        private var ltrSignals = 0
        private var logicalSignals = 0
        private(set) var isLTRAuthored = false

        init(trackID: Int64? = nil) {
            self.trackID = trackID
        }

        /// The cues as their author laid them out: unchanged unless the track
        /// is LTR-authored. A different `trackID` starts a new track.
        mutating func laidOutAsAuthored(_ cues: [SubtitleCue], trackID: Int64?) -> [SubtitleCue] {
            if trackID != self.trackID {
                self = Track(trackID: trackID)
            }
            for cue in cues where countedCueIDs.insert(cue.id).inserted {
                guard let text = cue.text else { continue }
                for line in text.components(separatedBy: "\n") where firstStrongIsRightToLeft(line) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if hasLTRAuthoredPunctuation(trimmed) { ltrSignals += 1 }
                    if hasLogicalPunctuation(trimmed) { logicalSignals += 1 }
                }
            }
            if !isLTRAuthored {
                isLTRAuthored = ltrSignals >= minimumSignals && ltrSignals > dominanceRatio * logicalSignals
            }
            guard isLTRAuthored else { return cues }
            return cues.map { cue in
                SubtitleCue(
                    id: cue.id,
                    startTime: cue.startTime,
                    endTime: cue.endTime,
                    body: applyingLeftToRightBase(to: cue.body),
                    placement: cue.placement
                )
            }
        }
    }

    /// The cue body with a left-to-right mark before every right-to-left line.
    static func applyingLeftToRightBase(to body: SubtitleCue.Body) -> SubtitleCue.Body {
        switch body {
        case .text(let text):
            return .text(markingRightToLeftLines(text))
        case .richText(let runs):
            return .richText(markingRightToLeftLines(runs))
        case .image:
            return body
        }
    }

    private static func markingRightToLeftLines(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { firstStrongIsRightToLeft($0) ? leftToRightMark + $0 : $0 }
            .joined(separator: "\n")
    }

    /// Lines run across styled runs, so each line's direction comes from the
    /// joined text and the mark goes into the run where that line starts.
    /// Both passes split on the newline scalar, so a `\r\n` pair can't make
    /// them disagree about where lines start.
    private static func markingRightToLeftLines(_ runs: [SubtitleTextRun]) -> [SubtitleTextRun] {
        let marksLine = runs.map(\.text).joined().components(separatedBy: "\n").map(firstStrongIsRightToLeft)
        let mark = leftToRightMark.unicodeScalars
        var lineIndex = 0
        var atLineStart = true
        return runs.map { run in
            var marked = String.UnicodeScalarView()
            for scalar in run.text.unicodeScalars {
                if atLineStart, scalar != "\n" {
                    if marksLine[lineIndex] { marked.append(contentsOf: mark) }
                    atLineStart = false
                }
                marked.append(scalar)
                if scalar == "\n" {
                    lineIndex += 1
                    atLineStart = true
                }
            }
            return SubtitleTextRun(
                text: String(marked),
                color: run.color,
                isBold: run.isBold,
                isItalic: run.isItalic,
                isUnderlined: run.isUnderlined,
                isStruckThrough: run.isStruckThrough,
                fontName: run.fontName,
                fontSize: run.fontSize
            )
        }
    }

    // MARK: - Line signals

    /// A sentence end moved to the logical start (`...لأنه`), or a dialogue
    /// dash moved to the logical end (`ماذا حدث؟ -`).
    private static func hasLTRAuthoredPunctuation(_ line: String) -> Bool {
        if let first = line.first, sentencePunctuation.contains(first) {
            let rest = line.drop { sentencePunctuation.contains($0) }
            if rest.contains(where: { !$0.isWhitespace }) { return true }
        }
        if line.last == "-" {
            return line.dropLast().contains { !$0.isWhitespace && $0 != "-" }
        }
        return false
    }

    /// A dialogue dash at the logical start, or a sentence end at the logical end.
    private static func hasLogicalPunctuation(_ line: String) -> Bool {
        if line.first == "-", line.dropFirst().contains(where: { !$0.isWhitespace }) {
            return true
        }
        if let last = line.last, sentencePunctuation.contains(last) {
            let rest = line.reversed().drop { sentencePunctuation.contains($0) }
            return rest.first.map { !$0.isWhitespace } ?? false
        }
        return false
    }

    private static let sentencePunctuation: Set<Character> = [".", "…", "!", "?", ","]

    // MARK: - Direction

    /// True when the first strongly directional character is right to left,
    /// which is what makes a Unicode renderer lay the line out right to left.
    private static func firstStrongIsRightToLeft(_ line: String) -> Bool {
        for scalar in line.unicodeScalars {
            switch scalar.value {
            case 0x200E: return false // LEFT-TO-RIGHT MARK
            case 0x200F, 0x061C: return true // RIGHT-TO-LEFT MARK, ARABIC LETTER MARK
            default: break
            }
            guard scalar.properties.isAlphabetic else { continue }
            return isRightToLeftScript(scalar)
        }
        return false
    }

    /// Hebrew, Arabic, Syriac, Thaana, N'Ko, Samaritan, Mandaic and their
    /// presentation forms, plus the historic right-to-left blocks.
    private static func isRightToLeftScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFE,
             0x10800...0x10FFF, 0x1E800...0x1EFFF:
            return true
        default:
            return false
        }
    }
}
