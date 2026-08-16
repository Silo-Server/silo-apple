//
//  PlayerTimeFormatterTests.swift
//  SiloTests
//
//  Pins the output of the shared player time formatters. The tvOS transport
//  bar and scrubber used to carry their own copies of the HMS path; these
//  cases lock the boundaries (hour rollover, day rollover) and the
//  defensive clamps (negative / non-finite) so a future consolidation
//  cannot silently change what the overlays render.
//

import XCTest
@testable import Silo

final class PlayerTimeFormatterTests: XCTestCase {
    // MARK: - formatHMS

    func testFormatHMSBoundaries() {
        XCTAssertEqual(PlayerTimeFormatter.formatHMS(0), "0:00")
        XCTAssertEqual(PlayerTimeFormatter.formatHMS(59), "0:59")
        XCTAssertEqual(PlayerTimeFormatter.formatHMS(60), "1:00")
        XCTAssertEqual(PlayerTimeFormatter.formatHMS(3599), "59:59")
        XCTAssertEqual(PlayerTimeFormatter.formatHMS(3600), "1:00:00")
        XCTAssertEqual(PlayerTimeFormatter.formatHMS(86399), "23:59:59")
        XCTAssertEqual(PlayerTimeFormatter.formatHMS(86400), "24:00:00")
    }

    /// Fractional seconds truncate rather than round: the elapsed readout
    /// must not show a second the playhead has not reached yet.
    func testFormatHMSTruncatesFractionalSeconds() {
        XCTAssertEqual(PlayerTimeFormatter.formatHMS(59.9), "0:59")
        XCTAssertEqual(PlayerTimeFormatter.formatHMS(3599.999), "59:59")
    }

    func testFormatHMSClampsInvalidInput() {
        XCTAssertEqual(PlayerTimeFormatter.formatHMS(-1), "0:00")
        XCTAssertEqual(PlayerTimeFormatter.formatHMS(-3600), "0:00")
        XCTAssertEqual(PlayerTimeFormatter.formatHMS(.nan), "0:00")
        XCTAssertEqual(PlayerTimeFormatter.formatHMS(.infinity), "0:00")
        XCTAssertEqual(PlayerTimeFormatter.formatHMS(-.infinity), "0:00")
    }

    // MARK: - formatRuntime

    func testFormatRuntime() {
        XCTAssertEqual(PlayerTimeFormatter.formatRuntime(59), "0m")
        XCTAssertEqual(PlayerTimeFormatter.formatRuntime(3599), "59m")
        XCTAssertEqual(PlayerTimeFormatter.formatRuntime(3600), "1h")
        XCTAssertEqual(PlayerTimeFormatter.formatRuntime(6120), "1h 42m")
        XCTAssertEqual(PlayerTimeFormatter.formatRuntime(86399), "23h 59m")
    }

    /// Zero/unknown duration returns an empty string so callers can filter
    /// it out of joined metadata lines.
    func testFormatRuntimeReturnsEmptyForUnknownDuration() {
        XCTAssertEqual(PlayerTimeFormatter.formatRuntime(0), "")
        XCTAssertEqual(PlayerTimeFormatter.formatRuntime(-1), "")
        XCTAssertEqual(PlayerTimeFormatter.formatRuntime(.nan), "")
        XCTAssertEqual(PlayerTimeFormatter.formatRuntime(.infinity), "")
    }

    // MARK: - formatCountdown

    func testFormatCountdown() {
        XCTAssertEqual(PlayerTimeFormatter.formatCountdown(0), "0:00")
        XCTAssertEqual(PlayerTimeFormatter.formatCountdown(59), "0:59")
        XCTAssertEqual(PlayerTimeFormatter.formatCountdown(3599), "59:59")
        // The sleep-timer countdown keeps counting minutes past the hour
        // rather than rolling over into an h:mm:ss form.
        XCTAssertEqual(PlayerTimeFormatter.formatCountdown(3600), "60:00")
        XCTAssertEqual(PlayerTimeFormatter.formatCountdown(7200), "120:00")
    }

    // MARK: - formatClockTime

    /// Wall-clock formatting is locale-driven, so pin it against the same
    /// `Date.FormatStyle` the transport bar used before consolidation
    /// instead of a hardcoded string.
    func testFormatClockTimeMatchesShortenedTimeStyle() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            PlayerTimeFormatter.formatClockTime(date),
            date.formatted(date: .omitted, time: .shortened)
        )
    }
}
