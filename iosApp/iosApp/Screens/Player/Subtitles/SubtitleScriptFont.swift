//
//  SubtitleScriptFont.swift
//  Continuum (iOS + tvOS + macOS)
//
//  Script-aware font fallback for generated ASS documents. The user's
//  chosen subtitle family is often Latin-only, so Arabic cues would
//  otherwise render through libass's per-glyph fallback (or, worse, be
//  flattened onto the Latin family by the renderer-wide `FONT_NAME`
//  override). Resolves an Arabic-capable companion family for a chosen
//  family, and classifies cue text so the converter can select it.
//

import CoreText
import Foundation

enum SubtitleScriptFont {
    private static let arabicAlef: UniChar = 0x0627
    private static let cacheLock = NSLock()
    private static var resolvedArabicFamilies: [String: String] = [:]

    /// True when the cue carries any Arabic letter. The fallback faces
    /// (Geeza Pro, Damascus) cover Latin too, so a mixed cue such as
    /// `NARRATOR: مرحبا` costs nothing by taking the Arabic style, while
    /// a majority test would send it down the Latin path and flatten the
    /// Arabic run.
    static func containsArabicLetters(_ text: String) -> Bool {
        // ASS override blocks (`{\i1}`) are markup, not cue text. A cue can
        // still contain a literal unmatched `{` — `translateCueBody` drops
        // raw braces but the `&#123;` entity path resolves one back in —
        // which would latch the scanner and swallow the rest of the line.
        // Fall back to a brace-blind scan when that happens.
        if let balanced = scanForArabic(text, honoringOverrideBraces: true) {
            return balanced
        }
        return scanForArabic(text, honoringOverrideBraces: false) ?? false
    }

    /// Scan `text` for Arabic letters. Returns nil when
    /// `honoringOverrideBraces` is set and the braces never balanced,
    /// meaning the result would be based on a truncated scan.
    private static func scanForArabic(
        _ text: String,
        honoringOverrideBraces: Bool
    ) -> Bool? {
        var containsArabic = false
        var insideASSOverride = false
        var escaped = false

        for scalar in text.unicodeScalars {
            if escaped {
                escaped = false
                continue
            }
            if scalar.value == 0x5C {
                escaped = true
                continue
            }
            if honoringOverrideBraces {
                if scalar.value == 0x7B {
                    insideASSOverride = true
                    continue
                }
                if scalar.value == 0x7D {
                    insideASSOverride = false
                    continue
                }
            }
            guard !insideASSOverride, isLetter(scalar), isArabic(scalar) else { continue }
            containsArabic = true
        }

        if honoringOverrideBraces, insideASSOverride { return nil }
        return containsArabic
    }

    static func arabicFontFamily(for chosenFamily: String) -> String {
        cacheLock.lock()
        let cached = resolvedArabicFamilies[chosenFamily]
        cacheLock.unlock()
        if let cached { return cached }

        // CoreText resolution loads cmaps; keep it off the lock and accept
        // that two callers may resolve the same family concurrently — the
        // result is deterministic, so the duplicate work is benign.
        let chosenFont = availableFont(named: chosenFamily)
        let resolved: String
        if let chosenFont, coversArabic(chosenFont) {
            resolved = chosenFamily
        } else {
            let mappedFamily = mappedArabicFamily(
                for: chosenFamily,
                chosenFont: chosenFont
            )
            if let mappedFont = availableFont(named: mappedFamily), coversArabic(mappedFont) {
                resolved = mappedFamily
            } else {
                // Preserve CoreText/libass's existing per-glyph fallback if
                // the expected platform face is unavailable.
                resolved = chosenFamily
            }
        }

        cacheLock.lock()
        resolvedArabicFamilies[chosenFamily] = resolved
        cacheLock.unlock()
        return resolved
    }

    private static func availableFont(named family: String) -> CTFont? {
        let font = CTFontCreateWithName(family as CFString, 16, nil)
        let resolvedFamily = CTFontCopyFamilyName(font) as String
        guard resolvedFamily.compare(
            family,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame else {
            return nil
        }
        return font
    }

    private static func mappedArabicFamily(
        for chosenFamily: String,
        chosenFont: CTFont?
    ) -> String {
        if chosenFamily.compare("Times New Roman", options: .caseInsensitive) == .orderedSame {
            return "Damascus"
        }
        if let chosenFont, isSerif(chosenFont) {
            return "Damascus"
        }
        return "Geeza Pro"
    }

    private static func isSerif(_ font: CTFont) -> Bool {
        // CoreText stores the OpenType stylistic class in the upper four
        // bits: 1-5 and 7 are its serif classifications.
        let stylisticClass = CTFontGetSymbolicTraits(font).rawValue >> 28
        switch stylisticClass {
        case 1...5, 7:
            return true
        default:
            return false
        }
    }

    private static func coversArabic(_ font: CTFont) -> Bool {
        CFCharacterSetIsCharacterMember(CTFontCopyCharacterSet(font), arabicAlef)
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter:
            return true
        default:
            return false
        }
    }

    private static func isArabic(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0600...0x06FF,
             0x0750...0x077F,
             0x08A0...0x08FF,
             0xFB50...0xFDFF,
             0xFE70...0xFEFF:
            return true
        default:
            return false
        }
    }
}
