//
//  SeekIntervals.swift
//  Silo (iOS + tvOS + macOS)
//
//  Contract facts and pure helpers for the profile-wide skip intervals
//  (`player.{video,audiobook}_skip_{back,forward}_seconds`, contract
//  revision 9). The observable store that reads and writes them lives in
//  SeekIntervalPreferences.swift.
//

import Foundation

enum SeekMedia: String, CaseIterable, Codable, Sendable {
    case video
    case audiobook
}

enum SeekDirection: String, CaseIterable, Codable, Sendable {
    case backward
    case forward
}

/// One media kind's pair of intervals, in whole seconds.
struct SeekIntervalPair: Codable, Equatable, Sendable {
    var backward: Int
    var forward: Int

    subscript(direction: SeekDirection) -> Int {
        get { direction == .backward ? backward : forward }
        set {
            switch direction {
            case .backward: backward = newValue
            case .forward: forward = newValue
            }
        }
    }
}

/// Both media kinds' intervals as the server resolved them.
struct SeekIntervalValues: Codable, Equatable, Sendable {
    var video: SeekIntervalPair
    var audiobook: SeekIntervalPair

    subscript(media: SeekMedia) -> SeekIntervalPair {
        get { media == .video ? video : audiobook }
        set {
            switch media {
            case .video: video = newValue
            case .audiobook: audiobook = newValue
            }
        }
    }

    static let contractDefaults = SeekIntervalValues(
        video: SeekIntervalContract.defaultPair,
        audiobook: SeekIntervalContract.defaultPair
    )
}

/// The revision-9 definitions. The generated bindings carry keys only, so the
/// choices and defaults are restated here and checked against the vendored
/// manifest by `SettingsConformanceTests`.
enum SeekIntervalContract {
    /// Every key shares one choice list; the manifest declares it per key.
    static let choices: [Int] = [5, 10, 15, 30, 45, 60, 90]
    static let defaultPair = SeekIntervalPair(backward: 10, forward: 30)

    static let keys: [SettingKey] = SeekMedia.allCases.flatMap { media in
        SeekDirection.allCases.map { key(media, $0) }
    }

    static func key(_ media: SeekMedia, _ direction: SeekDirection) -> SettingKey {
        switch (media, direction) {
        case (.video, .backward): return .playerVideoSkipBackSeconds
        case (.video, .forward): return .playerVideoSkipForwardSeconds
        case (.audiobook, .backward): return .playerAudiobookSkipBackSeconds
        case (.audiobook, .forward): return .playerAudiobookSkipForwardSeconds
        }
    }

    static func defaultValue(_ direction: SeekDirection) -> Int {
        defaultPair[direction]
    }

    static func isValid(_ seconds: Int) -> Bool {
        choices.contains(seconds)
    }

    /// A resolved row's value, or the contract default when the row is
    /// missing, not a whole number, or outside the choice list. The server
    /// validates writes, so this only guards against a malformed response.
    static func resolve(_ value: SettingJSONValue?, direction: SeekDirection) -> Int {
        guard let seconds = value?.intValue, isValid(seconds) else {
            return defaultValue(direction)
        }
        return seconds
    }

    static func resolve(_ response: EffectiveSettingValuesResponse) -> SeekIntervalValues {
        let rows = response.byKey
        var values = SeekIntervalValues.contractDefaults
        for media in SeekMedia.allCases {
            for direction in SeekDirection.allCases {
                values[media][direction] = resolve(
                    rows[key(media, direction)]?.value,
                    direction: direction
                )
            }
        }
        return values
    }

    /// Whether a server can store and resolve every seek key: the web
    /// client's per-key revision test on an available settings contract.
    static func isSupported(by capabilities: APIv2SettingsContractCapabilities) -> Bool {
        keys.allSatisfy(capabilities.supports)
    }
}

/// Fixed intervals each surface used before revision 9. Older servers, and
/// newer ones before their first successful read, keep exactly this behavior.
struct SeekIntervalSurface: Equatable, Sendable {
    let media: SeekMedia
    let legacy: SeekIntervalPair

    /// On-screen video transport, keyboard, gestures, and Siri Remote clicks.
    static let videoPlayer: SeekIntervalSurface = {
        #if os(tvOS)
        return SeekIntervalSurface(media: .video, legacy: .init(backward: 10, forward: 30))
        #elseif os(macOS)
        return SeekIntervalSurface(media: .video, legacy: .init(backward: 15, forward: 15))
        #else
        return SeekIntervalSurface(media: .video, legacy: .init(backward: 10, forward: 10))
        #endif
    }()

    /// Lock screen, Control Center, headphones, and other system media
    /// controls while a video plays on this device.
    static let videoSystemControls = SeekIntervalSurface(
        media: .video,
        legacy: .init(backward: 10, forward: 10)
    )

    /// The phone remote and its system media controls while it drives
    /// playback on another device.
    static let videoRemoteControl = SeekIntervalSurface(
        media: .video,
        legacy: .init(backward: 10, forward: 30)
    )

    /// The audiobook full player, mini player, and system media controls.
    static let audiobook = SeekIntervalSurface(
        media: .audiobook,
        legacy: .init(backward: 30, forward: 30)
    )
}

/// Symbols and spoken labels for a skip control that must name the interval
/// the action will actually use.
enum SeekIntervalLabel {
    /// Counts with a numbered `gobackward.N` / `goforward.N` SF Symbol. Every
    /// contract choice and every legacy fixed interval is in this list;
    /// anything else falls back to the unnumbered arrow.
    static let numberedSymbolSeconds: Set<Int> = [5, 10, 15, 30, 45, 60, 75, 90]

    static func symbolName(_ direction: SeekDirection, seconds: Int) -> String {
        let base = direction == .backward ? "gobackward" : "goforward"
        return numberedSymbolSeconds.contains(seconds) ? "\(base).\(seconds)" : base
    }

    static func accessibilityLabel(_ direction: SeekDirection, seconds: Int) -> String {
        let verb = direction == .backward ? "Back" : "Forward"
        return seconds == 1 ? "\(verb) 1 second" : "\(verb) \(seconds) seconds"
    }

    static func choiceLabel(_ seconds: Int) -> String {
        "\(seconds) seconds"
    }
}

/// Where a relative skip lands. Rapid presses must build on the target the
/// previous press already requested, not on a playhead that has not caught up
/// yet, or three quick presses would move one interval instead of three.
enum RelativeSeek {
    /// - Parameters:
    ///   - current: the playhead the transport last reported.
    ///   - pending: the target of a seek that has been requested but not yet
    ///     reflected in `current`, if any.
    ///   - delta: signed seconds to move.
    ///   - duration: the media duration, or `nil`/non-positive when unknown.
    static func target(
        current: Double,
        pending: Double?,
        delta: Double,
        duration: Double?
    ) -> Double {
        let base = pending ?? current
        let raw = base + delta
        guard raw.isFinite else { return max(0, base.isFinite ? base : 0) }
        if let duration, duration > 0 {
            return min(max(0, raw), duration)
        }
        return max(0, raw)
    }
}
