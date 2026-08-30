import XCTest

final class TVDetailFocusHandoffUITests: XCTestCase {
    private let app = XCUIApplication()
    private let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = false

        let environment = ProcessInfo.processInfo.environment
        guard let contentID = environment["SILO_UI_TEST_CONTENT_ID"] else {
            throw XCTSkip("A Silo tvOS UI-test content fixture was not supplied")
        }

        let server = environment["SILO_UI_TEST_SERVER"]
        let username = environment["SILO_UI_TEST_USERNAME"]
        let password = environment["SILO_UI_TEST_PASSWORD"]
        if let server, let username, let password {
            app.launchEnvironment["SILO_DEBUG_PASSWORD"] = password
            app.launchArguments += ["-debugServer", server, "-debugUsername", username]
        } else if server != nil || username != nil || password != nil {
            throw XCTSkip("The Silo tvOS UI-test login fixture was incomplete")
        }
        // With no login fixture, reuse the simulator's persisted authenticated
        // session. CI can continue supplying all three login values above.
        app.launchArguments += [
            "-debugItem", contentID,
            "-debugSuppressDiagnosticsPrompt",
        ]
        app.launch()

        // `simctl openurl` presents a one-time tvOS confirmation owned by
        // PineBoard. A prior manual fixture launch may leave it pending over
        // the app; dismiss it explicitly so it cannot masquerade as lost app
        // focus in this regression test.
        let pineBoard = XCUIApplication(bundleIdentifier: "com.apple.PineBoard")
        let openButton = pineBoard.buttons["Open"]
        if openButton.waitForExistence(timeout: 1) {
            remote.press(.select)
            app.activate()
        }
    }

    func testSeasonUpReturnsToPlaybackSelector() throws {
        let playID = "detail.action.play"
        let play = app.descendants(matching: .any)[playID]
        XCTAssertTrue(play.waitForExistence(timeout: 30), "Detail Play action never appeared")
        XCTAssertTrue(waitForFocus(identifier: playID), "Play did not receive page-entry focus")

        let versionID = "detail.selector.version"
        let version = app.descendants(matching: .any)[versionID]
        XCTAssertTrue(version.waitForExistence(timeout: 15), "Version selector never appeared")
        let selectedSeasonAnchor = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "detail.season.selected."
                )
            )
            .firstMatch
        XCTAssertTrue(
            selectedSeasonAnchor.waitForExistence(timeout: 15),
            "Selected Season anchor never appeared"
        )
        let canvasAnchorYBeforeSelectorEntry = waitForStableVerticalPosition(
            of: selectedSeasonAnchor
        )
        XCTAssertNotNil(
            canvasAnchorYBeforeSelectorEntry,
            "Version selector never reached stable layout"
        )
        remote.press(.down)
        XCTAssertTrue(
            waitForFocus(identifier: versionID),
            "Down from Play did not focus Version; focus=\(focusedElementSummary())"
        )
        let canvasAnchorYAfterSelectorEntry = waitForStableVerticalPosition(
            of: selectedSeasonAnchor
        )
        XCTAssertNotNil(
            canvasAnchorYAfterSelectorEntry,
            "Version selector did not settle after receiving focus"
        )
        if let before = canvasAnchorYBeforeSelectorEntry,
           let after = canvasAnchorYAfterSelectorEntry {
            XCTAssertEqual(
                after,
                before,
                accuracy: 2,
                "Play-to-Version focus moved the detail canvas"
            )
        }

        let audioID = "detail.selector.audio"
        remote.press(.right)
        XCTAssertTrue(
            waitForFocus(identifier: audioID, timeout: 3),
            "Right from Version did not focus Audio on initial entry; "
                + "focus=\(focusedElementSummary())"
        )
        remote.press(.left)
        XCTAssertTrue(
            waitForFocus(identifier: versionID, timeout: 3),
            "Left from Audio did not return focus to Version on initial entry"
        )

        let versionToSeasonStartY = version.frame.minY
        remote.press(.down)
        let versionToSeasonTrajectory = verticalTrajectoryUntilStable(of: version)
        let versionToSeasonOvershoot = verticalOvershoot(
            startY: versionToSeasonStartY,
            trajectory: versionToSeasonTrajectory
        )
        XCTAssertFalse(
            versionToSeasonTrajectory.isEmpty,
            "Version-to-Season canvas motion was not observable"
        )
        XCTAssertLessThanOrEqual(
            versionToSeasonOvershoot,
            4,
            "Version-to-Season canvas overshot its resting position by "
                + "\(versionToSeasonOvershoot) points; trajectory="
                + "\(versionToSeasonTrajectory)"
        )
        let selectedSeasonPrefix = "detail.season.selected."
        let enteredSeason = firstFocusedElement(
            matchingIdentifierPrefix: "detail.season."
        )
        XCTAssertNotNil(
            enteredSeason,
            "Down from Version did not enter the Season row"
        )
        XCTAssertTrue(
            enteredSeason?.identifier.hasPrefix(selectedSeasonPrefix) ?? false,
            "Down from Version focused \(enteredSeason?.identifier ?? "nothing") instead of the selected Season pill"
        )
        let seasonRestingY = enteredSeason.flatMap {
            waitForStableVerticalPosition(of: $0)
        }
        XCTAssertNotNil(
            seasonRestingY,
            "Selected Season pill did not reach stable browser framing"
        )
        if let seasonRestingY {
            XCTAssertLessThanOrEqual(
                seasonRestingY,
                280,
                "Selected Season settled mid-screen instead of near the top"
            )
        }
        let verticalPositionBeforeSeasonMove = waitForStableVerticalPosition(of: version)
        XCTAssertNotNil(
            verticalPositionBeforeSeasonMove,
            "Detail canvas did not settle after entering the Season row"
        )

        // Prove the entry gate does not break ordinary navigation within the
        // row, then approach Episodes from a non-selected pill. Up must still
        // return to the selected season rather than this last hover.
        let seasonCandidates = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail.season."))
            .allElementsBoundByIndex
        let selectedSeason = seasonCandidates.first {
            $0.identifier.hasPrefix(selectedSeasonPrefix)
        }
        XCTAssertNotNil(selectedSeason, "Selected Season pill was not exposed to UI testing")
        let originalSeasonNumber = selectedSeason.flatMap { seasonNumber(from: $0) }
        XCTAssertNotNil(originalSeasonNumber, "Selected Season pill had no season number")
        let movedLeft: Bool
        if let selectedSeason,
           seasonCandidates.contains(where: { $0.frame.midX < selectedSeason.frame.midX }) {
            remote.press(.left)
            movedLeft = true
        } else {
            remote.press(.right)
            movedLeft = false
        }
        let adjacentSeason = firstFocusedElement(
            matchingIdentifierPrefix: "detail.season.",
            timeout: 3
        )
        XCTAssertNotNil(adjacentSeason, "Horizontal Season navigation lost focus")
        XCTAssertFalse(
            adjacentSeason?.identifier.hasPrefix(selectedSeasonPrefix) ?? true,
            "Horizontal Season navigation did not leave the selected pill"
        )
        let verticalPositionAfterSeasonMove = waitForStableVerticalPosition(of: version)
        XCTAssertNotNil(
            verticalPositionAfterSeasonMove,
            "Detail canvas did not settle after horizontal Season navigation"
        )
        if let before = verticalPositionBeforeSeasonMove,
           let after = verticalPositionAfterSeasonMove {
            XCTAssertEqual(
                after,
                before,
                accuracy: 2,
                "Horizontal Season navigation moved the vertical detail canvas"
            )
        }

        // Select must remain owned by the pill's single composite control. A
        // nested Button previously let the outer focus interaction intercept
        // activation: every pill appeared selected while Episodes never changed.
        let adjacentSeasonNumber = adjacentSeason.flatMap { seasonNumber(from: $0) }
        XCTAssertNotNil(adjacentSeasonNumber, "Adjacent Season pill had no season number")
        if let adjacentSeasonNumber, let originalSeasonNumber {
            remote.press(.select)
            XCTAssertTrue(
                app.descendants(matching: .any)[
                    "\(selectedSeasonPrefix)\(adjacentSeasonNumber)"
                ].waitForExistence(timeout: 15),
                "Select did not update the selected Season pill"
            )
            XCTAssertTrue(
                waitForEpisodeSeason(adjacentSeasonNumber),
                "Select did not update the episode carousel to Season \(adjacentSeasonNumber)"
            )

            remote.press(movedLeft ? .right : .left)
            XCTAssertTrue(
                waitForFocus(identifier: "detail.season.\(originalSeasonNumber)", timeout: 3),
                "Could not return focus to the original Season pill"
            )
            remote.press(.select)
            XCTAssertTrue(
                app.descendants(matching: .any)[
                    "\(selectedSeasonPrefix)\(originalSeasonNumber)"
                ].waitForExistence(timeout: 15),
                "Select did not restore the original selected Season"
            )
            XCTAssertTrue(
                waitForEpisodeSeason(originalSeasonNumber),
                "Select did not restore the original episode carousel"
            )
        }

        remote.press(.down)
        let currentEpisodeID = "detail.episode.current"
        XCTAssertTrue(
            waitForFocus(identifier: currentEpisodeID, timeout: 5),
            "Down from the Season row did not prioritize the current episode"
        )

        remote.press(.up)
        XCTAssertNotNil(
            firstFocusedElement(
                matchingIdentifierPrefix: selectedSeasonPrefix,
                timeout: 5
            ),
            "Up from the current episode did not prioritize the selected Season pill"
        )

        remote.press(.up)
        XCTAssertTrue(
            waitForFocus(identifier: versionID, timeout: 3),
            "Up from the Season row did not return focus to Version"
        )
        remote.press(.right)
        XCTAssertTrue(
            waitForFocus(identifier: audioID, timeout: 3),
            "Right from Version did not focus Audio"
        )

        let subtitlesID = "detail.selector.subtitles"
        remote.press(.right)
        XCTAssertTrue(
            waitForFocus(identifier: subtitlesID, timeout: 3),
            "Right from Audio did not focus Subtitles"
        )

        remote.press(.left)
        XCTAssertTrue(
            waitForFocus(identifier: audioID, timeout: 3),
            "Left from Subtitles did not focus Audio"
        )
        remote.press(.left)
        XCTAssertTrue(
            waitForFocus(identifier: versionID, timeout: 3),
            "Left from Audio did not return focus to Version"
        )

        remote.press(.up)
        XCTAssertTrue(
            waitForFocus(identifier: playID, timeout: 3),
            "Up from Version did not preserve Play as the priority action"
        )

        let startOverID = "detail.action.startOver"
        let startOver = app.descendants(matching: .any)[startOverID]
        if startOver.exists {
            remote.press(.right)
            XCTAssertTrue(
                waitForFocus(identifier: startOverID, timeout: 3),
                "Right from Play did not focus Start Over"
            )
            remote.press(.left)
            XCTAssertTrue(
                waitForFocus(identifier: playID, timeout: 3),
                "Left from Start Over did not return focus to Play"
            )
        }
    }

    private func waitForFocus(identifier: String, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if focusIsWithinElement(identifier: identifier) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    private func firstFocusedElement(
        matchingIdentifierPrefix prefix: String,
        timeout: TimeInterval = 8
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let candidates = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
                .allElementsBoundByIndex
            if let focusedCandidate = candidates.first(where: focusIsWithinElement) {
                return focusedCandidate
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return nil
    }

    private func focusedElementSummary() -> String {
        let focused = app.descendants(matching: .any)
            .allElementsBoundByIndex
            .filter(focusIsWithinElement)
        guard !focused.isEmpty else { return "none" }
        return focused.prefix(4).map { element in
            let identifier = element.identifier.isEmpty ? "<no-id>" : element.identifier
            return "\(element.elementType.rawValue):\(identifier):\(element.label)"
        }.joined(separator: " | ")
    }

    private func waitForStableVerticalPosition(
        of element: XCUIElement,
        timeout: TimeInterval = 3
    ) -> CGFloat? {
        let deadline = Date().addingTimeInterval(timeout)
        var previousY: CGFloat?
        var stableSamples = 0

        repeat {
            guard element.exists else { return nil }
            let currentY = element.frame.minY
            guard currentY.isFinite else { return nil }
            if let previousY, abs(currentY - previousY) <= 0.5 {
                stableSamples += 1
                if stableSamples >= 4 { return currentY }
            } else {
                stableSamples = 0
            }
            previousY = currentY
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return nil
    }

    private func verticalTrajectoryUntilStable(
        of element: XCUIElement,
        timeout: TimeInterval = 3
    ) -> [CGFloat] {
        let deadline = Date().addingTimeInterval(timeout)
        var positions: [CGFloat] = []
        var stableSamples = 0

        repeat {
            guard element.exists else { break }
            let currentY = element.frame.minY
            guard currentY.isFinite else { break }
            positions.append(currentY)
            if let previousY = positions.dropLast().last,
               abs(currentY - previousY) <= 0.5 {
                stableSamples += 1
                if stableSamples >= 5 { break }
            } else {
                stableSamples = 0
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        } while Date() < deadline

        return positions
    }

    private func verticalOvershoot(
        startY: CGFloat,
        trajectory: [CGFloat]
    ) -> CGFloat {
        guard let finalY = trajectory.last else { return 0 }
        if finalY < startY {
            return max(0, finalY - (trajectory.min() ?? finalY))
        }
        return max(0, (trajectory.max() ?? finalY) - finalY)
    }

    private func seasonNumber(from element: XCUIElement) -> Int? {
        guard let component = element.identifier.split(separator: ".").last else {
            return nil
        }
        return Int(component)
    }

    private func waitForEpisodeSeason(
        _ seasonNumber: Int,
        timeout: TimeInterval = 15
    ) -> Bool {
        let labelPrefix = seasonNumber == 0
            ? "Specials, Episode "
            : "Season \(seasonNumber), Episode "
        let predicate = NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
            "detail.episode.",
            labelPrefix
        )
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.descendants(matching: .any).matching(predicate).count > 0 {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    /// A tvOS `Menu` exposes its accessibility identifier on the wrapper but
    /// reports focus on an anonymous inner element. Accept either direct focus
    /// or a focused descendant whose center lies inside the identified frame.
    private func focusIsWithinElement(identifier: String) -> Bool {
        let element = app.descendants(matching: .any)[identifier]
        return element.exists && focusIsWithinElement(element)
    }

    private func focusIsWithinElement(_ element: XCUIElement) -> Bool {
        if element.hasFocus { return true }
        let frame = element.frame
        guard !frame.isEmpty, !frame.isNull, !frame.isInfinite else { return false }
        let focusedQuery = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true"))
        guard focusedQuery.count > 0 else { return false }
        let focusedElement = focusedQuery.element(boundBy: 0)
        let point = CGPoint(
            x: focusedElement.frame.midX,
            y: focusedElement.frame.midY
        )
        return frame.contains(point)
    }
}
