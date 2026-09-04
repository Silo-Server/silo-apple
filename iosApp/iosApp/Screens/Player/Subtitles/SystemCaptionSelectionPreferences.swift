//
//  SystemCaptionSelectionPreferences.swift
//  Silo (iOS + tvOS + macOS)
//
//  Read-only bridge for the non-visual half of Apple's Subtitles &
//  Captioning preferences. Silo never writes these values: the active
//  system profile remains the single source of truth.
//

import Foundation
import MediaAccessibility

struct SystemCaptionSelectionPreferences: Equatable {
    enum DisplayMode: Equatable {
        case forcedOnly
        case automatic
        case alwaysOn
    }

    var displayMode: DisplayMode
    /// Ordered canonical language identifiers from the active Apple profile.
    var preferredLanguages: [String]
    /// True when Apple asks players to prefer CC/SDH accessibility tracks.
    var prefersAccessibilityTracks: Bool

    static func current() -> SystemCaptionSelectionPreferences {
        let displayMode: DisplayMode
        switch MACaptionAppearanceGetDisplayType(.user) {
        case .forcedOnly:
            displayMode = .forcedOnly
        case .alwaysOn:
            displayMode = .alwaysOn
        case .automatic:
            displayMode = .automatic
        @unknown default:
            displayMode = .automatic
        }

        let selectedLanguages = MACaptionAppearanceCopySelectedLanguages(.user)
            .takeRetainedValue() as? [String] ?? []
        let languages = selectedLanguages.isEmpty ? Locale.preferredLanguages : selectedLanguages
        let characteristics = MACaptionAppearanceCopyPreferredCaptioningMediaCharacteristics(.user)
            .takeRetainedValue() as? [String] ?? []
        let accessibilityCharacteristics = Set([
            MAMediaCharacteristicDescribesMusicAndSoundForAccessibility as String,
            MAMediaCharacteristicTranscribesSpokenDialogForAccessibility as String,
        ])

        return SystemCaptionSelectionPreferences(
            displayMode: displayMode,
            preferredLanguages: languages,
            prefersAccessibilityTracks: !accessibilityCharacteristics.isDisjoint(with: characteristics)
        )
    }
}
