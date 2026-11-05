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

final class QuickPanelActivationPolicyTests: XCTestCase {
    func testSkipsActivationOnlyWhenTheDetailsWindowLivesOnAnotherSpace() {
        XCTAssertTrue(QuickPanelActivationPolicy.avoidsActivation(applicationIsActive: false, detailsWindowOnAnotherSpace: true))
        XCTAssertFalse(QuickPanelActivationPolicy.avoidsActivation(applicationIsActive: false, detailsWindowOnAnotherSpace: false),
                       "No window elsewhere: activation cannot switch Spaces, keep the normal path.")
        XCTAssertFalse(QuickPanelActivationPolicy.avoidsActivation(applicationIsActive: true, detailsWindowOnAnotherSpace: true))
    }
}
