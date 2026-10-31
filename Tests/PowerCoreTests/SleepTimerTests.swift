import XCTest
@testable import PowerCore

final class SleepTimerTests: XCTestCase {
    func testReplacementCountsFromNowPreservesSessionAndInvalidatesGeneration() throws {
        var timer = SleepTimer()
        try timer.start(minutes: 15, now: 100)
        let id = timer.sessionID, generation = timer.generation
        try timer.replaceDuration(minutes: 60, now: 130)
        XCTAssertEqual(timer.sessionID, id)
        XCTAssertEqual(timer.generation, generation + 1)
        XCTAssertEqual(timer.deadline, 3730)
        try timer.replaceDuration(minutes: 30, now: 140)
        XCTAssertEqual(timer.deadline, 1940)
        XCTAssertEqual(timer.phase, .armed)
        try timer.replaceDuration(minutes: 1, now: 150)
        XCTAssertEqual(timer.deadline, 210)
        XCTAssertEqual(timer.phase, .warning)
    }

    func testReplacementRejectsInvalidValuesAndEveryNoneditablePhase() throws {
        var timer = SleepTimer()
        XCTAssertThrowsError(try timer.replaceDuration(minutes: 15, now: 0))
        try timer.start(minutes: 1, now: 0)
        let original = timer
        for minutes in [0, -1, 1441, Int.max] {
            XCTAssertThrowsError(try timer.replaceDuration(minutes: minutes, now: 10))
            XCTAssertEqual(timer, original)
        }
        XCTAssertThrowsError(try timer.replaceDuration(minutes: 15, now: .nan))
        XCTAssertEqual(timer, original)
        XCTAssertTrue(timer.beginPreparation(now: 60))
        XCTAssertThrowsError(try timer.replaceDuration(minutes: 15, now: 60))
        XCTAssertTrue(timer.beginRequest(now: 60))
        XCTAssertThrowsError(try timer.replaceDuration(minutes: 15, now: 60))
        XCTAssertTrue(timer.markSubmitted())
        timer.acceptRequest(now: 60)
        XCTAssertThrowsError(try timer.replaceDuration(minutes: 15, now: 60))
        timer.invalidate()
        XCTAssertThrowsError(try timer.replaceDuration(minutes: 15, now: 60))
    }

    func testValidationAndDuplicateStartPreserveOriginalSession() throws {
        var timer = SleepTimer()
        for minutes in [0, -1, 1441, Int.max] {
            XCTAssertThrowsError(try timer.start(minutes: minutes, now: 100))
        }
        try timer.start(minutes: 2, now: 100)
        let original = timer.sessionID
        try timer.start(minutes: 20, now: 110)
        XCTAssertEqual(timer.sessionID, original)
        XCTAssertEqual(timer.deadline, 220)
        XCTAssertEqual(timer.remainingSeconds(at: 110), 110)
    }

    func testWarningIncludesLastMinuteAndDelayedCallbackDoesNotExtendDeadline() throws {
        var timer = SleepTimer()
        try timer.start(minutes: 2, now: 0)
        timer.advance(now: 59)
        XCTAssertEqual(timer.phase, .armed)
        timer.advance(now: 60)
        XCTAssertEqual(timer.phase, .warning)
        timer.advance(now: 124)
        XCTAssertTrue(timer.beginPreparation(now: 124))
        XCTAssertTrue(timer.beginRequest(now: 125))
        XCTAssertFalse(timer.beginRequest(now: 125))
        XCTAssertEqual(timer.deadline, 120)
    }

    func testLateDispatchExpiresAndCannotRequest() throws {
        var timer = SleepTimer()
        try timer.start(minutes: 1, now: 0)
        XCTAssertEqual(timer.phase, .warning)
        XCTAssertFalse(timer.beginPreparation(now: 65.001))
        XCTAssertEqual(timer.phase, .expired)
        XCTAssertFalse(timer.beginRequest(now: 66))
    }

    func testExtensionUsesExistingDeadlineAndSameSessionWithRemainingCap() throws {
        var timer = SleepTimer()
        try timer.start(minutes: 1440, now: 0)
        XCTAssertThrowsError(try timer.extend(now: 0))
        let id = timer.sessionID
        try timer.extend(now: 900)
        XCTAssertEqual(timer.deadline, 87_300)
        XCTAssertEqual(timer.sessionID, id)
        XCTAssertEqual(timer.remainingSeconds(at: 900), 86_400)
        XCTAssertFalse(timer.canExtend(at: 900))
        timer.cancel()
        XCTAssertThrowsError(try timer.extend(now: 901))
    }

    func testSleepBeforeSubmissionCancelsButSubmittedSleepIsAnObservation() throws {
        var timer = SleepTimer()
        try timer.start(minutes: 1, now: 0)
        timer.systemWillSleep()
        XCTAssertEqual(timer.phase, .cancelled)
        try timer.start(minutes: 1, now: 100)
        XCTAssertTrue(timer.beginPreparation(now: 160))
        XCTAssertTrue(timer.beginRequest(now: 160))
        XCTAssertTrue(timer.markSubmitted())
        timer.systemWillSleep()
        XCTAssertEqual(timer.phase, .completed)
    }

    func testLifecycleBetweenRequestPublicationAndSubmissionCancelsWithoutClaimingSleep() throws {
        var timer = SleepTimer()
        try timer.start(minutes: 1, now: 0)
        XCTAssertTrue(timer.beginPreparation(now: 60))
        XCTAssertTrue(timer.beginRequest(now: 60))
        timer.invalidate()
        XCTAssertEqual(timer.phase, .cancelled)
        XCTAssertFalse(timer.markSubmitted())
    }

    func testAcceptanceIsNotSleepAndConfirmationHasOneAwakeMinute() throws {
        var timer = SleepTimer()
        try timer.start(minutes: 1, now: 0)
        XCTAssertTrue(timer.beginPreparation(now: 60))
        XCTAssertTrue(timer.beginRequest(now: 60))
        XCTAssertTrue(timer.markSubmitted())
        XCTAssertFalse(timer.markSubmitted())
        timer.acceptRequest(now: 61)
        XCTAssertEqual(timer.phase, .accepted)
        timer.advance(now: 120.999)
        XCTAssertEqual(timer.phase, .accepted)
        timer.advance(now: 121)
        XCTAssertEqual(timer.phase, .unconfirmed)
    }
}
