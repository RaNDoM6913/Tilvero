import XCTest
@testable import TilveroApp

final class QuickPanelActivationTests: XCTestCase {
    func testInactiveApplicationWaitsForActivationAndPresentsOnlyOnce() {
        var gate = QuickPanelActivationGate()
        XCTAssertFalse(gate.request(applicationIsActive: false))
        XCTAssertTrue(gate.isWaiting)
        XCTAssertTrue(gate.applicationBecameActive())
        XCTAssertFalse(gate.applicationBecameActive())
    }
    func testCancellationCannotRevivePanelOnDelayedActivation() {
        var gate = QuickPanelActivationGate()
        XCTAssertFalse(gate.request(applicationIsActive: false))
        gate.cancel()
        XCTAssertFalse(gate.applicationBecameActive())
        XCTAssertTrue(gate.request(applicationIsActive: true))
        XCTAssertFalse(gate.isWaiting)
    }
}
