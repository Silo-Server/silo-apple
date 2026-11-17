#if os(tvOS)
import UIKit
import XCTest
@testable import Silo

/// The timeline preview shows while a thumb rests on the Siri Remote clickpad
/// and hides once the capture view reports the contact ended. SwiftUI removes
/// the capture view mid-touch (Up Next, item changes, the HUD), so the view
/// must end the contact itself when it leaves the window.
@MainActor
final class TVPressCaptureTouchContactTests: XCTestCase {
    private final class IndirectTouch: UITouch {
        override var type: UITouch.TouchType { .indirect }
    }

    private var window: UIWindow!
    private var view: PressCaptureUIView!
    private var began = 0
    private var ended = 0
    private var cancelled = 0

    override func setUp() {
        super.setUp()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        view = PressCaptureUIView(frame: window.bounds)
        view.onTouchSurfaceContactBegan = { [unowned self] in began += 1 }
        view.onTouchSurfaceContactEnded = { [unowned self] in ended += 1 }
        view.onTouchSurfaceContactCancelled = { [unowned self] in cancelled += 1 }
        window.addSubview(view)
    }

    override func tearDown() {
        view.removeFromSuperview()
        view = nil
        window = nil
        super.tearDown()
    }

    func testLeavingTheWindowMidTouchCancelsTheContactOnce() {
        let touch = IndirectTouch()
        view.touchesBegan([touch], with: nil)
        XCTAssertEqual(began, 1)

        view.removeFromSuperview()
        XCTAssertEqual(cancelled, 1)

        // A lift that still reaches the removed view must not report again.
        view.touchesEnded([touch], with: nil)
        XCTAssertEqual(ended, 0)
        XCTAssertEqual(cancelled, 1)
    }

    func testLiftInTheWindowEndsTheContactAndLeavingLaterReportsNothing() {
        let touch = IndirectTouch()
        view.touchesBegan([touch], with: nil)
        view.touchesEnded([touch], with: nil)
        XCTAssertEqual(ended, 1)

        view.removeFromSuperview()
        XCTAssertEqual(cancelled, 0)
    }
}
#endif
