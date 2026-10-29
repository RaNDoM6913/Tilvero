import AppKit
import XCTest
@testable import TilveroApp

@MainActor final class QuickPanelMotionTests: XCTestCase {
    func testCurrentReduceMotionPreferenceConfiguresSamePopoverForEachOpening() {
        let popover = NSPopover()
        // A prior disabled state must not suppress ordinary native opening.
        popover.animates = false
        QuickPanelMotion.configure(popover, reduceMotion: false)
        XCTAssertTrue(popover.animates)
        // A changed preference must be honored without rebuilding the popover.
        QuickPanelMotion.configure(popover, reduceMotion: true)
        XCTAssertFalse(popover.animates)
        QuickPanelMotion.configure(popover, reduceMotion: false)
        XCTAssertTrue(popover.animates)
    }
}
