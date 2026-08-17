//
//  VTTToASSConverter.swift
//  Silo (iOS + tvOS)
//
//  Translate WebVTT subtitle content into an ASS document suitable for
//  libass's `ass_read_memory`. libass parses SSA/ASS natively and SRT
//  natively, but WebVTT is not supported by libass directly — hence this
//  converter.
//
//  Scope: the subset of WebVTT used by server-side ffmpeg. We handle cue
//  blocks with HH:MM:SS.mmm timestamps, basic inline markup (<b>, <i>,
//  <u>), speaker tags (<v Speaker>), class tags (<c.name>), and numeric
//  HTML entities. Positioning settings (line:, position:, align:) are
//  stripped — libass uses its own positioning derived from the synthetic
//  ASS header's Default style (which the session populates from the user
//  PlayerSettings override).
//

import Foundation

enum VTTToASSConverter {

    struct ConversionResult {
        let assDocument: String
        /// Whether any Dialogue actually selected `ArabicFallback`. Drives
        /// the renderer's `FONT_NAME`-override suppression.
        let usedArabicFallbackStyle: Bool
        /// Whether any cue carries Arabic at all, independent of whether
        /// the header offered a fallback style. Drives the session's
        /// font-change reinstall: a track with Arabic cues must be
        /// reconverted for the new family even when the old family covered
        /// Arabic itself (no fallback style emitted).
        let containsArabicCues: Bool
    }

    /// Convert a WebVTT document body to a full ASS document.
    ///
    /// - Parameter vtt: the raw WebVTT content as served by the Silo
    ///   server. Leading BOM and CRLF/CR line endings are tolerated.
    /// - Parameter header: a prebuilt synthetic ASS `[Script Info]` +
    ///   `[V4+ Styles]` + `[Events] Format:` header. Supplied by the
    ///   caller (`SubtitleStylingOverride.syntheticHeader`) so the user's
    ///   styling preferences are embedded at conversion time.
    /// - Parameter hasArabicFallbackStyle: whether `header` contains the
    ///   script-aware `ArabicFallback` style.
    /// - Returns: the full ASS document, whether any emitted Dialogue
    ///   selected `ArabicFallback`, and whether any cue contained Arabic.
    ///   The document is always syntactically valid; catastrophic parse
    ///   failure produces just the header and empty Events section
    ///   (never throws).
    static func convert(
        vtt: String,
        header: String,
        hasArabicFallbackStyle: Bool
    ) -> ConversionResult {
        var out = header
        var usedArabicFallbackStyle = false
        var containsArabicCues = false
        if !out.hasSuffix("\n") { out.append("\n") }

        // Normalise line endings so the scanner only has to handle `\n`.
        var body = vtt
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        body = body.replacingOccurrences(of: "\r\n", with: "\n")
        body = body.replacingOccurrences(of: "\r", with: "\n")

        let lines = body.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            // Skip blank lines between blocks.
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
            }
            guard i < lines.count else { break }

            let firstLine = lines[i]
            let trimmedFirst = firstLine.trimmingCharacters(in: .whitespaces)

            // Drop header / metadata blocks. They run until the next blank
            // line — consume them and loop back.
            if isHeaderBlockStart(trimmedFirst) {
                i += 1
                while i < lines.count,
                      !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    i += 1
                }
                continue
            }

            // Locate the timestamp line. If the first line of the block is
            // a cue identifier (no `-->`), the timestamp is on the next
            // line. If it's already a timestamp, the block has no id.
            var timestampLineIdx = -1
            if firstLine.contains("-->") {
                timestampLineIdx = i
            } else if i + 1 < lines.count, lines[i + 1].contains("-->") {
                timestampLineIdx = i + 1
            } else {
                // Unparseable block — skip to the next blank line and move on.
                while i < lines.count,
                      !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    i += 1
                }
                continue
            }

            guard let (startMs, endMs) = parseTimestampLine(lines[timestampLineIdx]) else {
                while i < lines.count,
                      !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    i += 1
                }
                continue
            }

            // Cue body: everything from the line after the timestamp until
            // the next blank line.
            var bodyLines: [String] = []
            i = timestampLineIdx + 1
            while i < lines.count,
                  !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                bodyLines.append(lines[i])
                i += 1
            }

            let joined = bodyLines.joined(separator: "\n")
            let cueText = translateCueBody(joined)
            guard !cueText.isEmpty else { continue }

            let startTs = assTimestamp(millis: startMs)
            let endTs = assTimestamp(millis: endMs)
            // Classify every cue regardless of header contents: the session
            // needs `containsArabicCues` even when no fallback style exists.
            let cueHasArabic = SubtitleScriptFont.containsArabicLetters(cueText)
            if cueHasArabic { containsArabicCues = true }
            let usesArabicFallback = hasArabicFallbackStyle && cueHasArabic
            if usesArabicFallback {
                usedArabicFallbackStyle = true
            }
            let style = usesArabicFallback ? "ArabicFallback" : "Default"
            // ASS Dialogue format:
            //   Dialogue: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
            out.append("Dialogue: 0,\(startTs),\(endTs),\(style),,0,0,0,,\(cueText)\n")
        }

        return ConversionResult(
            assDocument: out,
            usedArabicFallbackStyle: usedArabicFallbackStyle,
            containsArabicCues: containsArabicCues
        )
    }

    // MARK: - Block classification

    private static func isHeaderBlockStart(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("WEBVTT") { return true }
        if trimmed == "NOTE" || trimmed.hasPrefix("NOTE ") || trimmed.hasPrefix("NOTE\t") {
            return true
        }
        if trimmed.hasPrefix("STYLE") { return true }
        if trimmed.hasPrefix("REGION") { return true }
        return false
    }

    // MARK: - Timestamps

    /// Parse a VTT timestamp line and return start/end in whole
    /// milliseconds. Cue settings (anything after the second timestamp)
    /// are ignored.
    private static func parseTimestampLine(_ line: String) -> (startMs: Int, endMs: Int)? {
        // Accept arbitrary whitespace around `-->`.
        guard let arrowRange = line.range(of: "-->") else { return nil }
        let lhs = String(line[..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let rhsFull = String(line[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)

        // Strip cue settings (trailing `line:... position:... align:...`).
        let rhsEnd: String
        if let space = rhsFull.firstIndex(where: { $0.isWhitespace }) {
            rhsEnd = String(rhsFull[..<space])
        } else {
            rhsEnd = rhsFull
        }

        guard let startMs = parseVTTTimestamp(lhs),
              let endMs = parseVTTTimestamp(rhsEnd) else {
            return nil
        }
        return (startMs, endMs)
    }

    /// Parse `HH:MM:SS.mmm` or `MM:SS.mmm` into milliseconds.
    private static func parseVTTTimestamp(_ s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var hours = 0, minutes = 0
        let secAndMs: String

        if parts.count == 3 {
            guard let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
            hours = h; minutes = m
            secAndMs = String(parts[2])
        } else {
            guard let m = Int(parts[0]) else { return nil }
            minutes = m
            secAndMs = String(parts[1])
        }

        // Accept both VTT `.` and SRT-style `,` decimal separators.
        let normalised = secAndMs.replacingOccurrences(of: ",", with: ".")
        let secParts = normalised.split(separator: ".")
        guard let seconds = Int(secParts[0]) else { return nil }
        var millis = 0
        if secParts.count > 1 {
            let msStr = String(secParts[1].prefix(3))
            let padded = msStr.padding(toLength: 3, withPad: "0", startingAt: 0)
            guard let m = Int(padded) else { return nil }
            millis = m
        }

        return ((hours * 3600 + minutes * 60 + seconds) * 1000) + millis
    }

    /// ASS timestamps are `H:MM:SS.cc` (centiseconds). Seconds field
    /// is integer + a 2-digit centiseconds fraction.
    private static func assTimestamp(millis: Int) -> String {
        let clamped = max(0, millis)
        let cs = (clamped % 1000) / 10
        let totalSeconds = clamped / 1000
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        return String(format: "%d:%02d:%02d.%02d", h, m, s, cs)
    }

    // MARK: - Cue body translation

    /// Translate the inner body of a VTT cue into ASS-compatible text.
    /// - Converts recognised inline markup to ASS override tags
    /// - Drops unknown `<...>` tags while keeping the text inside them
    /// - Resolves HTML entities
    /// - Escapes literal `{`, `}`, `\` that would otherwise be parsed
    ///   as ASS override syntax
    /// - Joins multi-line bodies with `\N`
    private static func translateCueBody(_ body: String) -> String {
        guard !body.isEmpty else { return "" }
        var out = String()
        out.reserveCapacity(body.count)

        var idx = body.startIndex
        while idx < body.endIndex {
            let ch = body[idx]

            if ch == "<" {
                // Find the closing bracket. If there isn't one, treat the
                // `<` as literal text (odd VTT, but don't lose characters).
                if let close = body[idx...].firstIndex(of: ">") {
                    let tagContent = String(body[body.index(after: idx)..<close])
                    out.append(translateInlineTag(tagContent))
                    idx = body.index(after: close)
                    continue
                } else {
                    out.append("<")
                    idx = body.index(after: idx)
                    continue
                }
            }

            if ch == "&" {
                // Try to resolve a named / numeric entity. If unrecognised,
                // emit the `&` literally.
                if let (replacement, advance) = resolveEntity(in: body, at: idx) {
                    out.append(replacement)
                    idx = advance
                    continue
                }
            }

            // ASS override escape characters — strip or escape them so
            // cue text can't inject override blocks.
            switch ch {
            case "{", "}":
                // No safe ASS escape for literal braces; drop them to avoid
                // opening a rogue override block.
                idx = body.index(after: idx)
                continue
            case "\\":
                // Drop raw backslash — VTT doesn't use it for line breaks
                // (that's what `\n` in the source already is, converted
                // below).
                idx = body.index(after: idx)
                continue
            case "\n":
                out.append("\\N")
                idx = body.index(after: idx)
                continue
            default:
                out.append(ch)
                idx = body.index(after: idx)
            }
        }

        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Translate the inside of a `<...>` tag into its ASS equivalent.
    /// Returns an empty string for tags with no visible contribution
    /// (classnames, timestamp anchors, speaker tags without prefix).
    private static func translateInlineTag(_ contents: String) -> String {
        let lower = contents.lowercased()

        // Closing tags.
        if lower.hasPrefix("/") {
            let name = lower.dropFirst()
            switch name {
            case "b":  return "{\\b0}"
            case "i":  return "{\\i0}"
            case "u":  return "{\\u0}"
            case "s":  return "{\\s0}"
            default:   return ""  // </c>, </v>, </ruby>, </rt>, etc.
            }
        }

        // Self-contained timestamp anchors like `<00:00:03.000>`.
        if let first = contents.first, first.isNumber { return "" }

        // Opening tags. Names may carry class suffixes like `c.red.italic`
        // — only the base name matters for formatting.
        let baseName: String
        if let dot = lower.firstIndex(of: ".") {
            baseName = String(lower[..<dot])
        } else if let space = lower.firstIndex(where: { $0.isWhitespace }) {
            baseName = String(lower[..<space])
        } else {
            baseName = lower
        }

        switch baseName {
        case "b":  return "{\\b1}"
        case "i":  return "{\\i1}"
        case "u":  return "{\\u1}"
        case "s":  return "{\\s1}"
        case "v":
            // `<v Speaker Name>text</v>` — could prepend "Speaker: " but
            // most UIs prefer the bare line. Drop the tag.
            return ""
        case "c", "ruby", "rt", "rp", "lang":
            return ""
        default:
            return ""
        }
    }

    /// Resolve an HTML entity starting at `idx` in `s`. Returns the
    /// replacement string and the index one-past the terminating `;`,
    /// or nil if the entity is unknown / malformed.
    private static func resolveEntity(
        in s: String, at idx: String.Index
    ) -> (String, String.Index)? {
        // Find the terminating `;` within a sane window.
        let maxLen = 10
        var cursor = s.index(after: idx)
        var count = 0
        while cursor < s.endIndex, count < maxLen, s[cursor] != ";" {
            cursor = s.index(after: cursor)
            count += 1
        }
        guard cursor < s.endIndex, s[cursor] == ";" else { return nil }
        let inner = String(s[s.index(after: idx)..<cursor])
        let after = s.index(after: cursor)

        if inner.hasPrefix("#") {
            let numberStr = String(inner.dropFirst())
            let value: Int?
            if numberStr.lowercased().hasPrefix("x") {
                value = Int(numberStr.dropFirst(), radix: 16)
            } else {
                value = Int(numberStr)
            }
            if let code = value, let scalar = Unicode.Scalar(code) {
                return (String(Character(scalar)), after)
            }
            return nil
        }

        switch inner.lowercased() {
        case "amp":  return ("&", after)
        case "lt":   return ("<", after)
        case "gt":   return (">", after)
        case "quot": return ("\"", after)
        case "apos": return ("'", after)
        case "nbsp": return ("\u{00A0}", after)
        case "lrm", "rlm": return ("", after)
        default:     return nil
        }
    }
}
