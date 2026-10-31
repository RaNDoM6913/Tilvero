import XCTest
@testable import TilveroApp

@MainActor final class NativeSleepTimerTransportTests: XCTestCase {
    func testOnlyMatchingNonRootConsoleUserMayRequest() throws {
        XCTAssertTrue(NativeSleepTimerTransport.consoleMatches(name: "owner", consoleUID: 501, processUID: 501))
        XCTAssertFalse(NativeSleepTimerTransport.consoleMatches(name: "loginwindow", consoleUID: 0, processUID: 0))
        XCTAssertFalse(NativeSleepTimerTransport.consoleMatches(name: nil, consoleUID: 501, processUID: 501))
        XCTAssertFalse(NativeSleepTimerTransport.consoleMatches(name: "other", consoleUID: 502, processUID: 501))
        var calls = 0
        let denied = NativeSleepTimerTransport(consoleCheck: { false }, request: { calls += 1; return 0 })
        XCTAssertThrowsError(try denied.requestSleep())
        XCTAssertEqual(calls, 0)
    }
    func testAcceptedAndRejectedResultsAreDistinctWithoutNativeCalls() throws {
        var calls = 0
        let accepted = NativeSleepTimerTransport(consoleCheck: { true }, request: { calls += 1; return 0 })
        try accepted.requestSleep()
        XCTAssertEqual(calls, 1)
        let rejected = NativeSleepTimerTransport(consoleCheck: { true }, request: { -536870207 })
        XCTAssertThrowsError(try rejected.requestSleep()) { error in
            XCTAssertTrue(error.localizedDescription.contains("-536870207"))
        }
    }
}
