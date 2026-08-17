//
//  SubtitleScriptFont.swift
//  Silo (iOS + tvOS + macOS)
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
    /// Face to try when the category-mapped one is missing. Ships on every
    /// Apple platform that carries Arabic at all, unlike Damascus (absent
    /// on tvOS).
    private static let universalArabicFamily = "Geeza Pro"
    private static let cacheLock = NSLock()
    private static var resolvedArabicFamilies: [String: String] = [:]

    /// True when the cue carries any Arabic letter or Arabic-Indic digit.
    /// The fallback faces (Geeza Pro, Damascus) cover Latin too, so a mixed
    /// cue such as `NARRATOR: مرحبا` costs nothing by taking the Arabic
    /// style, while a majority test would send it down the Latin path and
    /// flatten the Arabic run.
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

    /// Scan `text` for Arabic-script content. Returns nil when
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
            guard !insideASSOverride, isArabicScript(scalar) else { continue }
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
            // The category-mapped face is a style preference, not a
            // guarantee: Damascus is absent on tvOS, where
            // `CTFontCreateWithName` silently substitutes Helvetica and
            // `availableFont` rejects it. Fall through to the universal
            // face before giving up, otherwise no ArabicFallback style is
            // emitted and the FONT_NAME override flattens Arabic cues.
            if let covering = coveringArabicFamily(mappedFamily) {
                resolved = covering
            } else if mappedFamily != universalArabicFamily,
                      let covering = coveringArabicFamily(universalArabicFamily) {
                resolved = covering
            } else {
                // Preserve CoreText/libass's existing per-glyph fallback if
                // no expected platform face is available.
                resolved = chosenFamily
            }
        }

        cacheLock.lock()
        resolvedArabicFamilies[chosenFamily] = resolved
        cacheLock.unlock()
        return resolved
    }

    /// `family` if it both resolves to itself and covers Arabic, else nil.
    private static func coveringArabicFamily(_ family: String) -> String? {
        guard let font = availableFont(named: family), coversArabic(font) else { return nil }
        return family
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
        return universalArabicFamily
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

    /// A scalar that needs an Arabic-capable face: inside an Arabic block
    /// and either a letter or a decimal digit. Digits matter because the
    /// Arabic-Indic sets (U+0660–0669, U+06F0–06F9) live in those blocks —
    /// a digits-only cue such as `٢٠٢٦` would otherwise stay on `Default`
    /// and be flattened onto a Latin family by the `FONT_NAME` override.
    /// Punctuation and marks are excluded: they carry no script identity
    /// on their own.
    private static func isArabicScript(_ scalar: Unicode.Scalar) -> Bool {
        guard isInArabicBlock(scalar) else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter, .decimalNumber:
            return true
        default:
            return false
        }
    }

    /// The Arabic-script blocks whose letters or decimal digits can occur in
    /// subtitle prose. Deliberately not every block Scripts.txt assigns to
    /// Arabic: the remaining ones (Mathematical Alphabetic Symbols, the Siyaq
    /// and Rumi number sets, Coptic Epact) are notation whose glyphs the
    /// fallback faces don't cover, so classifying on them would switch the
    /// style without improving rendering. Extended-B/-C letters only ever
    /// appear alongside core U+06xx text, so their inclusion is completeness,
    /// not a behavior change.
    private static func isInArabicBlock(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0600...0x06FF,      // Arabic
             0x0750...0x077F,      // Arabic Supplement
             0x0870...0x089F,      // Arabic Extended-B
             0x08A0...0x08FF,      // Arabic Extended-A
             0xFB50...0xFDFF,      // Arabic Presentation Forms-A
             0xFE70...0xFEFF,      // Arabic Presentation Forms-B
             0x10EC0...0x10EFF:    // Arabic Extended-C
            return true
        default:
            return false
        }
    }
}
