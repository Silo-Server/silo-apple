//
//  SystemCaptionAppearance.swift
//  Continuum (iOS + tvOS + macOS)
//
//  Maps Apple's Media Accessibility caption preferences (Settings →
//  Accessibility → Subtitles & Captioning) onto `SubtitleAppearance` so
//  the player can offer a "match device settings" appearance source.
//
//  Every value returned by MediaAccessibility participates in the mapped
//  appearance. Apple's `.useContentIfAvailable` behavior still requires the
//  returned value when content does not supply one. Silo-controlled text
//  tracks intentionally have no competing authored style while "Match Device
//  Settings" is enabled, so dropping those fallback values would replace the
//  selected system profile with Silo's defaults.
//

import CoreGraphics
import CoreText
import Foundation
import MediaAccessibility

enum SystemCaptionAppearance {

    /// Raw values read from MediaAccessibility. `nil` means the framework did
    /// not provide a value Silo can map. Split from the mapping so tests can
    /// exercise the mapping without touching process-wide accessibility state.
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
        if let foregroundHex = hexString(from: foreground) {
            result.foregroundColorHex = valueForMatchingDeviceSettings(
                foregroundHex,
                behavior: behavior
            )
        }

        behavior = .useValue
        let background = MACaptionAppearanceCopyBackgroundColor(.user, &behavior).takeRetainedValue()
        if let backgroundHex = hexString(from: background) {
            result.backgroundColorHex = valueForMatchingDeviceSettings(
                backgroundHex,
                behavior: behavior
            )
        }

        behavior = .useValue
        let backgroundOpacity = MACaptionAppearanceGetBackgroundOpacity(.user, &behavior)
        result.backgroundOpacity = valueForMatchingDeviceSettings(
            Double(backgroundOpacity),
            behavior: behavior
        )

        behavior = .useValue
        let edge = MACaptionAppearanceGetTextEdgeStyle(.user, &behavior)
        result.edgeStyle = valueForMatchingDeviceSettings(edge, behavior: behavior)

        behavior = .useValue
        let size = MACaptionAppearanceGetRelativeCharacterSize(.user, &behavior)
        result.relativeCharacterSize = valueForMatchingDeviceSettings(
            Double(size),
            behavior: behavior
        )

        behavior = .useValue
        let descriptor = MACaptionAppearanceCopyFontDescriptorForStyle(
            .user, &behavior, .default
        ).takeRetainedValue()
        if let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
           !family.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.fontFamilyName = valueForMatchingDeviceSettings(family, behavior: behavior)
        }

        return result
    }

    /// Resolve a value for Silo's explicit "Match Device Settings" mode.
    ///
    /// `.useContentIfAvailable` is a precedence rule, not an absent value:
    /// Apple's contract says to use the returned preference when the content
    /// has no competing style. Plain SRT/VTT and other controlled text tracks
    /// have no authored appearance, so both known behaviors resolve to the
    /// system value. Native ASS continues to preserve its authored styling in
    /// `SubtitleStylingOverride`, downstream from this mapper.
    static func valueForMatchingDeviceSettings<Value>(
        _ value: Value,
        behavior: MACaptionAppearanceBehavior
    ) -> Value? {
        switch behavior {
        case .useValue, .useContentIfAvailable:
            return value
        @unknown default:
            return nil
        }
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
