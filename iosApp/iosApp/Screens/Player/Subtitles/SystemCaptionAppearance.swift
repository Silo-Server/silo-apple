//
//  SystemCaptionAppearance.swift
//  Continuum (iOS + tvOS + macOS)
//
//  Maps Apple's Media Accessibility caption preferences (Settings →
//  Accessibility → Subtitles & Captioning) onto `SubtitleAppearance` so
//  the player can offer a "match device settings" appearance source.
//
//  Only fields the user actually customized (behavior == .useValue) are
//  taken from the system; everything else keeps the Silo default, which
//  mirrors how AVPlayer applies these preferences to its own captions.
//

import CoreGraphics
import CoreText
import Foundation
import MediaAccessibility

enum SystemCaptionAppearance {

    /// Raw values read from MediaAccessibility. `nil` means the user did
    /// not customize that field (behavior was `.useContentIfAvailable`).
    /// Split from the mapping so tests can exercise the mapping without
    /// touching the process-wide accessibility state.
    struct Snapshot: Equatable {
        var foregroundColorHex: String?
        var backgroundColorHex: String?
        /// 0.0–1.0.
        var backgroundOpacity: Double?
        var edgeStyle: MACaptionAppearanceTextEdgeStyle?
        /// Multiplier around 1.0 (system slider spans roughly 0.5–2.0).
        var relativeCharacterSize: Double?
        var fontFamilyName: String?
    }

    static let settingsChangedNotification =
        Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String)

    /// The user's system caption style expressed as a `SubtitleAppearance`.
    static func current() -> SubtitleAppearance {
        appearance(from: snapshot())
    }

    // MARK: - Reading MediaAccessibility

    static func snapshot() -> Snapshot {
        var result = Snapshot()
        var behavior = MACaptionAppearanceBehavior.useValue

        let foreground = MACaptionAppearanceCopyForegroundColor(.user, &behavior).takeRetainedValue()
        if behavior == .useValue {
            result.foregroundColorHex = hexString(from: foreground)
        }

        behavior = .useValue
        let background = MACaptionAppearanceCopyBackgroundColor(.user, &behavior).takeRetainedValue()
        if behavior == .useValue {
            result.backgroundColorHex = hexString(from: background)
        }

        behavior = .useValue
        let backgroundOpacity = MACaptionAppearanceGetBackgroundOpacity(.user, &behavior)
        if behavior == .useValue {
            result.backgroundOpacity = Double(backgroundOpacity)
        }

        behavior = .useValue
        let edge = MACaptionAppearanceGetTextEdgeStyle(.user, &behavior)
        if behavior == .useValue {
            result.edgeStyle = edge
        }

        behavior = .useValue
        let size = MACaptionAppearanceGetRelativeCharacterSize(.user, &behavior)
        if behavior == .useValue {
            result.relativeCharacterSize = Double(size)
        }

        behavior = .useValue
        let descriptor = MACaptionAppearanceCopyFontDescriptorForStyle(
            .user, &behavior, .default
        ).takeRetainedValue()
        if behavior == .useValue,
           let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
           !family.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.fontFamilyName = family
        }

        return result
    }

    // MARK: - Mapping

    /// Fold a system snapshot over a base appearance. Field-by-field:
    /// customized values win, everything else keeps the base.
    ///
    /// The system model has no combined shadow-plus-box: a drop-shadow
    /// edge maps to our Drop Shadow style only when the user has no
    /// background, since Box occupies the same `backgroundStyle` slot.
    static func appearance(
        from snapshot: Snapshot,
        base: SubtitleAppearance = .default
    ) -> SubtitleAppearance {
        var result = base

        if let opacity = snapshot.backgroundOpacity {
            if opacity > 0.01 {
                result.backgroundStyle = .box
                result.backgroundOpacity = Int((opacity * 100).rounded())
            } else {
                result.backgroundStyle = SubtitleBackgroundStylePreset.none
            }
        }
        if let background = snapshot.backgroundColorHex {
            result.backgroundColor = background
        }

        if let edge = snapshot.edgeStyle {
            switch edge {
            case .uniform, .raised, .depressed:
                result.textOutline = true
            case .dropShadow:
                result.textOutline = false
                if result.backgroundStyle != .box {
                    result.backgroundStyle = .shadow
                }
            default:
                result.textOutline = false
            }
        }

        if let foreground = snapshot.foregroundColorHex {
            result.fontColor = foreground
        }
        if let relativeSize = snapshot.relativeCharacterSize {
            result.fontSize = fontSizePreset(forRelativeSize: relativeSize)
        }
        if let family = snapshot.fontFamilyName,
           let preset = SubtitleFontFamilyPreset(rawValue: family) {
            result.fontFamily = preset
        }

        return result.sanitized()
    }

    /// Map the system's relative character size (1.0 = default) onto our
    /// preset ladder, anchoring 1.0 at the Silo default preset.
    static func fontSizePreset(forRelativeSize relative: Double) -> SubtitleFontSizePreset {
        let anchors: [(preset: SubtitleFontSizePreset, relative: Double)] = [
            (.small, 0.6),
            (.medium, 0.8),
            (.large, 1.0),
            (.xlarge, 1.4),
            (.xxlarge, 1.8),
        ]
        return anchors.min(by: { abs($0.relative - relative) < abs($1.relative - relative) })?.preset
            ?? SubtitleAppearance.default.fontSize
    }

    /// `#RRGGBB` from a CGColor, converted through sRGB. Alpha is carried
    /// separately by the opacity preferences, so it is dropped here.
    static func hexString(from color: CGColor) -> String? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let components = converted.components,
              components.count >= 3 else {
            return nil
        }
        func byte(_ value: CGFloat) -> Int {
            Int((max(0, min(1, value)) * 255).rounded())
        }
        return String(
            format: "#%02x%02x%02x",
            byte(components[0]), byte(components[1]), byte(components[2])
        )
    }
}
