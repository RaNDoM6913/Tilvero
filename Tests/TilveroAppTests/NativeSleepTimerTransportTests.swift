import XCTest
@testable import TilveroApp

@MainActor final class NativeSleepTimerTransportTests: XCTestCase {
    func testTimerHoldIsFiniteVerifiedAndIndependentOfForeignAssertions() throws {
        let awake = AwakeFixture()
        awake.assertions[99] = .init(name: "Foreign player", kind: "PreventUserIdleSystemSleep", active: true, seconds: 3600, releasesOnTimeout: true)
        let transport = NativeSleepTimerTransport(consoleCheck: { true }, request: { 0 }, idleHoldTransport: awake)
        try transport.acquireIdleHold(seconds: 120)
        XCTAssertTrue(transport.hasIdleHold)
        XCTAssertEqual(awake.assertions.values.first { $0.name != "Foreign player" }?.seconds, 120)
        try transport.extendIdleHold()
        XCTAssertEqual(awake.assertions.values.first { $0.name != "Foreign player" }?.seconds, 1020)
        let id = try XCTUnwrap(awake.assertions.keys.first { $0 != 99 })
        try transport.replaceIdleHold(seconds: 60)
        XCTAssertEqual(awake.assertions[id]?.seconds, 60)
        try transport.releaseIdleHold()
        XCTAssertFalse(transport.hasIdleHold)
        XCTAssertEqual(awake.assertions.count, 1)
        XCTAssertEqual(awake.assertions[99]?.name, "Foreign player")
    }
    func testUnverifiedTimerHoldCannotClaimProtectionAndKeepsReleaseFailureVisible() throws {
        let awake = AwakeFixture()
        awake.wrongTimeoutOnCreate = true
        let transport = NativeSleepTimerTransport(consoleCheck: { true }, request: { 0 }, idleHoldTransport: awake)
        XCTAssertThrowsError(try transport.acquireIdleHold(seconds: 120))
        XCTAssertFalse(transport.hasIdleHold)
        awake.wrongTimeoutOnCreate = false
        try transport.acquireIdleHold(seconds: 120)
        awake.failRelease = true
        XCTAssertThrowsError(try transport.releaseIdleHold())
        XCTAssertTrue(transport.hasIdleHold)
        awake.failRelease = false
        try transport.releaseIdleHold()
        XCTAssertFalse(transport.hasIdleHold)
    }
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
