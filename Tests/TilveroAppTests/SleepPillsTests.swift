import XCTest
@testable import TilveroApp

@MainActor final class SleepPillsTests: XCTestCase {
    func testTimerMasterStartsDefaultDraftAndStopsItsCapturedSession() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        try SleepPillActions.setTimerEnabled(f.model, enabled: true, token: nil)
        let token = try XCTUnwrap(SleepPillActions.controlToken(f.model, awake: false))
        XCTAssertEqual(f.model.sleepTimer.remainingSeconds, 1800)
        XCTAssertEqual(SleepPillActions.timerSelection(f.model), .preset(30))
        XCTAssertTrue(f.model.sleepTimer.isHoldingAwake)
        try SleepPillActions.setTimerEnabled(f.model, enabled: false, token: token)
        XCTAssertFalse(f.model.sleepTimer.isActive)
        XCTAssertFalse(f.model.sleepTimer.isHoldingAwake)
        XCTAssertEqual(f.model.sleepTimer.phase, .cancelled)
        XCTAssertEqual(f.timer.requests, 0)
    }

    func testTimerMasterStartsSavedCustomDraftAndPreservesItAfterStopping() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        f.model.sleepTimerMinutes = "7"
        f.model.sleepTimerUsesCustom = true
        try SleepPillActions.setTimerEnabled(f.model, enabled: true, token: nil)
        let token = try XCTUnwrap(SleepPillActions.controlToken(f.model, awake: false))
        XCTAssertEqual(f.model.sleepTimer.remainingSeconds, 420)
        XCTAssertEqual(SleepPillActions.timerSelection(f.model), .custom)
        try SleepPillActions.setTimerEnabled(f.model, enabled: false, token: token)
        try SleepPillActions.setTimerEnabled(f.model, enabled: true, token: nil)
        XCTAssertEqual(f.model.sleepTimer.remainingSeconds, 420)
        XCTAssertEqual(SleepPillActions.timerSelection(f.model), .custom)
        XCTAssertNotEqual(SleepPillActions.controlToken(f.model, awake: false), token)
    }

    func testTimerMasterRejectsInvalidDraftWithoutStartingOrReplacingAwake() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        try SleepPillActions.awake(f.model, request: .duration(15))
        let awakeID = try XCTUnwrap(f.model.keepAwake.ownedAssertionID)
        for draft in ["", "invalid", "0", "1441"] {
            f.model.sleepTimerMinutes = draft
            XCTAssertThrowsError(try SleepPillActions.setTimerEnabled(f.model, enabled: true, token: nil,
                consent: .endAwake(awakeID))) {
                XCTAssertEqual($0 as? SleepPillActionError, .invalidDuration)
            }
        }
        XCTAssertEqual(f.model.keepAwake.ownedAssertionID, awakeID)
        XCTAssertTrue(f.model.keepAwake.isActive)
        XCTAssertFalse(f.model.sleepTimer.isActive)
        XCTAssertEqual(f.timer.acquisitions, 0)
    }

    func testStaleTimerMasterOnAndOffCannotReplaceInterveningTimer() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        try SleepPillActions.timer(f.model, minutes: 15)
        let old = try XCTUnwrap(SleepPillActions.controlToken(f.model, awake: false))
        f.model.sleepTimer.cancel()
        try SleepPillActions.timer(f.model, minutes: 60)
        let replacement = f.model.sleepTimer.sessionID
        XCTAssertThrowsError(try SleepPillActions.setTimerEnabled(f.model, enabled: false, token: old))
        XCTAssertThrowsError(try SleepPillActions.setTimerEnabled(f.model, enabled: true, token: nil))
        XCTAssertThrowsError(try SleepPillActions.setTimerEnabled(f.model, enabled: true, token: old))
        XCTAssertThrowsError(try SleepPillActions.setTimerEnabled(f.model, enabled: false, token: .awake(1)))
        XCTAssertEqual(f.model.sleepTimer.sessionID, replacement)
        XCTAssertEqual(f.model.sleepTimer.remainingSeconds, 3600)
        XCTAssertTrue(f.model.sleepTimer.isHoldingAwake)
        XCTAssertEqual(f.timer.replacements, 0)
    }

    func testTimerMasterConflictRequiresCurrentAwakeConsentAndCapturesDraft() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        try SleepPillActions.awake(f.model, request: .duration(15))
        let first = try XCTUnwrap(f.model.keepAwake.ownedAssertionID)
        XCTAssertThrowsError(try SleepPillActions.setTimerEnabled(f.model, enabled: true, token: nil)) {
            XCTAssertEqual($0 as? SleepPillActionError, .confirmation(.endAwake(first)))
        }
        XCTAssertEqual(f.timer.acquisitions, 0)
        try f.model.keepAwake.stop()
        try SleepPillActions.awake(f.model, request: .duration(60))
        let replacement = try XCTUnwrap(f.model.keepAwake.ownedAssertionID)
        XCTAssertThrowsError(try SleepPillActions.setTimerEnabled(f.model, enabled: true, token: nil,
            minutes: 7, custom: true, consent: .endAwake(first))) {
            XCTAssertEqual($0 as? SleepPillActionError, .confirmation(.endAwake(replacement)))
        }
        XCTAssertEqual(f.model.keepAwake.ownedAssertionID, replacement)
        f.model.sleepTimerMinutes = "60"
        try SleepPillActions.setTimerEnabled(f.model, enabled: true, token: nil,
            minutes: 7, custom: true, consent: .endAwake(replacement))
        XCTAssertFalse(f.model.keepAwake.hasOwnedAssertion)
        XCTAssertEqual(f.model.sleepTimer.remainingSeconds, 420)
        XCTAssertEqual(SleepPillActions.timerSelection(f.model), .custom)
    }

    func testTimerMasterConfirmationCannotReplaceTimerStartedWhileDialogWasOpen() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        try SleepPillActions.awake(f.model, request: .duration(15))
        let awakeID = try XCTUnwrap(f.model.keepAwake.ownedAssertionID)
        XCTAssertThrowsError(try SleepPillActions.setTimerEnabled(f.model, enabled: true, token: nil))
        try SleepPillActions.timer(f.model, minutes: 60, consent: .endAwake(awakeID))
        let timerID = f.model.sleepTimer.sessionID
        XCTAssertThrowsError(try SleepPillActions.setTimerEnabled(f.model, enabled: true, token: nil,
            minutes: 30, custom: false, consent: .endAwake(awakeID)))
        XCTAssertEqual(f.model.sleepTimer.sessionID, timerID)
        XCTAssertEqual(f.model.sleepTimer.remainingSeconds, 3600)
        XCTAssertEqual(f.timer.replacements, 0)
    }

    func testTimerMasterFailedStopRetainsHoldAndRetriesOnlySameSession() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        try SleepPillActions.timer(f.model, minutes: 15)
        let token = try XCTUnwrap(SleepPillActions.controlToken(f.model, awake: false))
        f.timer.failRelease = true
        XCTAssertThrowsError(try SleepPillActions.setTimerEnabled(f.model, enabled: false, token: token))
        XCTAssertEqual(f.model.sleepTimer.phase, .cancelled)
        XCTAssertTrue(f.model.sleepTimer.isActive)
        XCTAssertTrue(f.model.sleepTimer.needsHoldRelease)
        XCTAssertTrue(f.model.sleepTimer.isHoldingAwake)
        XCTAssertNil(SleepPillActions.timerSelection(f.model))
        XCTAssertNotNil(f.model.sleepTimer.message)
        XCTAssertThrowsError(try SleepPillActions.setTimerEnabled(f.model, enabled: true, token: nil))
        f.timer.failRelease = false
        try SleepPillActions.setTimerEnabled(f.model, enabled: false, token: token)
        XCTAssertFalse(f.model.sleepTimer.isActive)
        XCTAssertFalse(f.model.sleepTimer.needsHoldRelease)
        XCTAssertFalse(f.model.sleepTimer.isHoldingAwake)
        try SleepPillActions.timer(f.model, minutes: 60)
        let replacement = f.model.sleepTimer.sessionID
        f.timer.failRelease = true
        f.model.sleepTimer.cancel()
        f.timer.failRelease = false
        XCTAssertThrowsError(try SleepPillActions.setTimerEnabled(f.model, enabled: false, token: token))
        XCTAssertEqual(f.model.sleepTimer.sessionID, replacement)
        XCTAssertTrue(f.model.sleepTimer.needsHoldRelease)
        XCTAssertEqual(f.timer.requests, 0)
    }

    func testTimerMasterCannotInventSessionForOrphanHoldRecovery() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        f.timer.failAcquisitionAfterOwnership = true
        f.timer.failRelease = true
        XCTAssertThrowsError(try SleepPillActions.setTimerEnabled(f.model, enabled: true, token: nil))
        XCTAssertNil(f.model.sleepTimer.sessionID)
        XCTAssertTrue(f.model.sleepTimer.needsHoldRelease)
        XCTAssertTrue(f.model.sleepTimer.isActive)
        XCTAssertNil(SleepPillActions.controlToken(f.model, awake: false))
        XCTAssertThrowsError(try SleepPillActions.setTimerEnabled(f.model, enabled: false, token: nil))
        XCTAssertThrowsError(try SleepPillActions.setTimerEnabled(f.model, enabled: false, token: .timer(UUID())))
        f.timer.failRelease = false
        f.model.sleepTimer.cancel()
        XCTAssertFalse(f.model.sleepTimer.needsHoldRelease)
        XCTAssertFalse(f.model.sleepTimer.isActive)
        XCTAssertEqual(f.timer.requests, 0)
    }

    func testMasterSwitchStartsSavedDraftAndStopsOnlyItsCapturedSession() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        f.model.keepAwakeDuration = KeepAwakeDuration(rawValue: 60)!
        try SleepPillActions.setAwakeEnabled(f.model, enabled: true, token: nil)
        let first = try XCTUnwrap(SleepPillActions.controlToken(f.model, awake: true))
        XCTAssertEqual(f.model.keepAwake.remainingSeconds, 3600)
        try SleepPillActions.setAwakeEnabled(f.model, enabled: false, token: first)
        XCTAssertFalse(f.model.keepAwake.hasOwnedAssertion)
        XCTAssertEqual(f.awake.releaseCount, 1)

        try SleepPillActions.setAwakeEnabled(f.model, enabled: true, token: nil)
        let replacement = f.model.keepAwake.ownedAssertionID
        XCTAssertThrowsError(try SleepPillActions.setAwakeEnabled(f.model, enabled: false, token: first))
        XCTAssertEqual(f.model.keepAwake.ownedAssertionID, replacement)
        XCTAssertTrue(f.model.keepAwake.isActive)
    }

    func testMasterSwitchRetainsConflictConfirmationAndFailedStopRetry() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        try SleepPillActions.timer(f.model, minutes: 15)
        let timerID = f.model.sleepTimer.sessionID
        XCTAssertThrowsError(try SleepPillActions.setAwakeEnabled(f.model, enabled: true, token: nil)) {
            XCTAssertEqual($0 as? SleepPillActionError, .confirmation(.endTimer(timerID)))
        }
        XCTAssertEqual(f.awake.createCount, 0)
        try SleepPillActions.setAwakeEnabled(f.model, enabled: true, token: nil, consent: .endTimer(timerID))
        let token = try XCTUnwrap(SleepPillActions.controlToken(f.model, awake: true))
        f.awake.failRelease = true
        XCTAssertThrowsError(try SleepPillActions.setAwakeEnabled(f.model, enabled: false, token: token))
        XCTAssertTrue(f.model.keepAwake.hasOwnedAssertion)
        XCTAssertNotNil(f.model.keepAwake.message)
        f.awake.failRelease = false
        try SleepPillActions.setAwakeEnabled(f.model, enabled: false, token: token)
        XCTAssertFalse(f.model.keepAwake.hasOwnedAssertion)
    }

    func testMasterRejectsInvalidCustomDraftAndCannotReplaceAnExistingSession() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        f.model.selectKeepAwakeOption(-1)
        f.model.keepAwakeCustomMinutes = "invalid"
        XCTAssertThrowsError(try SleepPillActions.setAwakeEnabled(f.model, enabled: true, token: nil))
        XCTAssertEqual(f.awake.createCount, 0)
        f.model.keepAwakeDuration = .halfHour
        try SleepPillActions.setAwakeEnabled(f.model, enabled: true, token: nil)
        let id = f.model.keepAwake.ownedAssertionID
        XCTAssertThrowsError(try SleepPillActions.setAwakeEnabled(f.model, enabled: true, token: nil))
        XCTAssertEqual(f.model.keepAwake.ownedAssertionID, id)
        XCTAssertEqual(f.awake.createCount, 1)
        XCTAssertEqual(f.awake.updateCount, 0)
    }

    func testTwoFifteenMinuteShortcutsThenOneHourAccumulateOnSameSession() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        try SleepPillActions.awake(f.model, request: .duration(30))
        let token = try XCTUnwrap(SleepPillActions.controlToken(f.model, awake: true))
        let id = f.model.keepAwake.ownedAssertionID
        f.clock.advance(10)
        try SleepPillActions.extend(f.model, token: token, minutes: 15)
        try SleepPillActions.extend(f.model, token: token, minutes: 15)
        XCTAssertEqual(f.model.keepAwake.remainingSeconds, 3590)
        try SleepPillActions.extend(f.model, token: token, minutes: 60)
        XCTAssertEqual(f.model.keepAwake.remainingSeconds, 7190)
        XCTAssertEqual(f.model.keepAwake.ownedAssertionID, id)
        XCTAssertEqual(SleepPillActions.awakeSelection(f.model), .preset(30))
        XCTAssertEqual(f.awake.createCount, 1)
        XCTAssertEqual(f.awake.releaseCount, 0)
    }

    func testAwakePresetStartsImmediatelyAndReplacementKeepsSameOwnedAssertion() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        try SleepPillActions.awake(f.model, request: .duration(15))
        let id = try XCTUnwrap(f.model.keepAwake.ownedAssertionID)
        XCTAssertEqual(SleepPillActions.awakeSelection(f.model), .preset(15))
        f.clock.advance(45)
        try SleepPillActions.awake(f.model, request: .duration(60))
        XCTAssertEqual(f.model.keepAwake.ownedAssertionID, id)
        XCTAssertEqual(f.model.keepAwake.remainingSeconds, 3600)
        XCTAssertEqual(f.awake.createCount, 1)
        XCTAssertEqual(f.awake.releaseCount, 0)
        XCTAssertEqual(SleepPillActions.awakeSelection(f.model), .preset(60))
        // Reopening a view cannot substitute its saved draft for applied state.
        f.model.selectKeepAwakeOption(30)
        XCTAssertEqual(SleepPillActions.awakeSelection(f.model), .preset(60))
        _ = KeepAwakePillsPanel(model: f.model)
        XCTAssertEqual(SleepPillActions.awakeSelection(f.model), .preset(60))
    }

    func testFailedAwakeReplacementPreservesConclusiveOldAppliedSelection() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        try SleepPillActions.awake(f.model, request: .duration(15))
        let id = f.model.keepAwake.ownedAssertionID
        f.awake.failUpdate = true
        XCTAssertThrowsError(try SleepPillActions.awake(f.model, request: .duration(60)))
        XCTAssertEqual(f.model.keepAwake.ownedAssertionID, id)
        XCTAssertEqual(SleepPillActions.awakeSelection(f.model), .preset(15))
        XCTAssertNotNil(f.model.keepAwake.message)
        XCTAssertEqual(f.awake.releaseCount, 0)
    }

    func testCustomDraftAndInvalidSubmissionCannotMutateEitherActivePeriod() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        try SleepPillActions.awake(f.model, request: .duration(15))
        let id = f.model.keepAwake.ownedAssertionID
        f.model.selectKeepAwakeOption(-1)
        f.model.keepAwakeCustomMinutes = "invalid"
        XCTAssertNil(SleepTimerInput.minutes("invalid"))
        XCTAssertThrowsError(try SleepPillActions.awake(f.model, request: .duration(0)))
        XCTAssertEqual(f.model.keepAwake.ownedAssertionID, id)
        XCTAssertEqual(SleepPillActions.awakeSelection(f.model), .preset(15))
        XCTAssertEqual(f.awake.updateCount, 0)
        try f.model.keepAwake.stop()
        try SleepPillActions.timer(f.model, minutes: 30)
        let timerID = f.model.sleepTimer.sessionID
        f.model.sleepTimerMinutes = "120"
        f.model.sleepTimerUsesCustom = true
        XCTAssertThrowsError(try SleepPillActions.timer(f.model, minutes: 1441, custom: true))
        XCTAssertEqual(f.model.sleepTimer.sessionID, timerID)
        XCTAssertEqual(SleepPillActions.timerSelection(f.model), .preset(30))
        XCTAssertEqual(f.timer.replacements, 0)
    }

    func testTimerPresetStartsAndReplacesSameSessionFromNow() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        try SleepPillActions.timer(f.model, minutes: 15)
        let id = f.model.sleepTimer.sessionID
        f.clock.advance(20)
        try SleepPillActions.timer(f.model, minutes: 60)
        XCTAssertEqual(f.model.sleepTimer.sessionID, id)
        XCTAssertEqual(f.model.sleepTimer.remainingSeconds, 3600)
        XCTAssertEqual(f.timer.acquisitions, 1)
        XCTAssertEqual(f.timer.replacements, 1)
        XCTAssertEqual(f.timer.requests, 0)
        XCTAssertEqual(SleepPillActions.timerSelection(f.model), .preset(60))
        _ = SleepTimerPillsPanel(model: f.model)
        XCTAssertEqual(SleepPillActions.timerSelection(f.model), .preset(60))
        f.timer.failReplace = true
        XCTAssertThrowsError(try SleepPillActions.timer(f.model, minutes: 30))
        XCTAssertNil(SleepPillActions.timerSelection(f.model), "Cancelled intent cannot retain an applied pill")
        XCTAssertFalse(f.model.sleepTimer.isActive)
    }

    func testOppositeModeRequiresExplicitConsentAndFailedAcquisitionRetainsTimer() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        try SleepPillActions.timer(f.model, minutes: 15)
        let timerID = f.model.sleepTimer.sessionID
        let needed = SleepPillConfirmation.endTimer(timerID)
        XCTAssertThrowsError(try SleepPillActions.awake(f.model, request: .duration(30))) {
            XCTAssertEqual($0 as? SleepPillActionError, .confirmation(needed))
        }
        XCTAssertEqual(f.awake.createCount, 0)
        f.awake.failCreate = true
        XCTAssertThrowsError(try SleepPillActions.awake(f.model, request: .duration(30), consent: needed))
        XCTAssertEqual(f.model.sleepTimer.sessionID, timerID)
        XCTAssertTrue(f.model.sleepTimer.isActive)
        f.awake.failCreate = false
        try SleepPillActions.awake(f.model, request: .duration(30), consent: needed)
        XCTAssertFalse(f.model.sleepTimer.isActive)
        let awakeID = try XCTUnwrap(f.model.keepAwake.ownedAssertionID)
        XCTAssertThrowsError(try SleepPillActions.timer(f.model, minutes: 60)) {
            XCTAssertEqual($0 as? SleepPillActionError, .confirmation(.endAwake(awakeID)))
        }
        XCTAssertTrue(f.model.keepAwake.isActive)
        try SleepPillActions.timer(f.model, minutes: 60, consent: .endAwake(awakeID))
        XCTAssertFalse(f.model.keepAwake.hasOwnedAssertion)
        XCTAssertTrue(f.model.sleepTimer.isActive)
    }

    func testTypeChangeNeedsRestartConsentAndRepeatedInfinityDoesNothing() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        try SleepPillActions.awake(f.model, request: .duration(15))
        let id = try XCTUnwrap(f.model.keepAwake.ownedAssertionID)
        XCTAssertThrowsError(try SleepPillActions.awake(f.model, request: .untilStopped)) {
            XCTAssertEqual($0 as? SleepPillActionError, .confirmation(.restartAwake(id)))
        }
        XCTAssertEqual(f.awake.releaseCount, 0)
        try SleepPillActions.awake(f.model, request: .untilStopped, consent: .restartAwake(id))
        XCTAssertEqual(f.awake.createCount, 2)
        XCTAssertEqual(f.awake.releaseCount, 1)
        XCTAssertEqual(SleepPillActions.awakeSelection(f.model), .untilStopped)
        try SleepPillActions.awake(f.model, request: .untilStopped)
        XCTAssertEqual(f.awake.createCount, 2)
        let infiniteID = try XCTUnwrap(f.model.keepAwake.ownedAssertionID)
        XCTAssertThrowsError(try SleepPillActions.awake(f.model, request: .duration(60)))
        try SleepPillActions.awake(f.model, request: .duration(60), consent: .restartAwake(infiniteID))
        let finiteID = try XCTUnwrap(f.model.keepAwake.ownedAssertionID)
        let target = Date().addingTimeInterval(600)
        XCTAssertThrowsError(try SleepPillActions.awake(f.model, request: .until(target)))
        try SleepPillActions.awake(f.model, request: .until(target), consent: .restartAwake(finiteID))
        XCTAssertEqual(SleepPillActions.awakeSelection(f.model), .until)
    }

    func testUnconfirmedOwnershipDisablesNewSelectionsAndRetainsStopRetry() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        try SleepPillActions.awake(f.model, request: .duration(15))
        f.awake.wrongUpdatedTimeout = true; f.awake.failRelease = true
        XCTAssertThrowsError(try SleepPillActions.awake(f.model, request: .duration(60)))
        XCTAssertTrue(f.model.keepAwake.hasOwnedAssertion)
        XCTAssertFalse(f.model.keepAwake.isActive)
        XCTAssertNil(SleepPillActions.awakeSelection(f.model))
        XCTAssertFalse(SleepPillActions.canChooseAwake(f.model))
        XCTAssertFalse(SleepPillActions.canChooseTimer(f.model))
        XCTAssertThrowsError(try SleepPillActions.awake(f.model, request: .duration(30)))
        f.awake.failRelease = false
        try f.model.keepAwake.stop()
        XCTAssertFalse(f.model.keepAwake.hasOwnedAssertion)
    }

    func testNonPresetCustomDurationStartsAndReplacesWithConfirmedCustomIdentity() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        try SleepPillActions.awake(f.model, request: .duration(7))
        let awakeID = f.model.keepAwake.ownedAssertionID
        XCTAssertEqual(f.model.keepAwake.remainingSeconds, 420)
        XCTAssertEqual(SleepPillActions.awakeSelection(f.model), .custom)
        try SleepPillActions.awake(f.model, request: .duration(11))
        XCTAssertEqual(f.model.keepAwake.ownedAssertionID, awakeID)
        XCTAssertEqual(f.model.keepAwake.remainingSeconds, 660)
        XCTAssertEqual(SleepPillActions.awakeSelection(f.model), .custom)
        try f.model.keepAwake.stop()
        try SleepPillActions.timer(f.model, minutes: 7, custom: true)
        XCTAssertEqual(f.model.sleepTimer.remainingSeconds, 420)
        XCTAssertEqual(SleepPillActions.timerSelection(f.model), .custom)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("History.sqlite").path))
    }

    func testExtensionKeepsAppliedPillAndActualAwakeAssertion() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        try SleepPillActions.awake(f.model, request: .duration(30))
        let token = try XCTUnwrap(SleepPillActions.controlToken(f.model, awake: true))
        let id = f.model.keepAwake.ownedAssertionID
        f.clock.advance(10)
        try SleepPillActions.extend(f.model, token: token, minutes: 30)
        XCTAssertEqual(f.model.keepAwake.remainingSeconds, 3590)
        XCTAssertEqual(f.model.keepAwake.ownedAssertionID, id)
        XCTAssertEqual(SleepPillActions.awakeSelection(f.model), .preset(30))
        XCTAssertEqual(f.model.keepAwake.activeDurationSeconds, 3590)
        XCTAssertEqual(f.awake.releaseCount, 0)
        try SleepPillActions.finish(f.model, token: token)
        XCTAssertFalse(f.model.keepAwake.hasOwnedAssertion)
    }

    func testTimerExtensionKeepsSessionPillAndFailureStopsFurtherIncrements() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        try SleepPillActions.timer(f.model, minutes: 30)
        let token = try XCTUnwrap(SleepPillActions.controlToken(f.model, awake: false))
        let id = f.model.sleepTimer.sessionID
        f.clock.advance(10)
        try SleepPillActions.extend(f.model, token: token, minutes: 60)
        XCTAssertEqual(f.model.sleepTimer.remainingSeconds, 5390)
        XCTAssertEqual(f.model.sleepTimer.sessionID, id)
        XCTAssertEqual(SleepPillActions.timerSelection(f.model), .preset(30))
        XCTAssertEqual(f.timer.requests, 0)
        f.timer.failExtension = f.timer.extensions + 2
        XCTAssertThrowsError(try SleepPillActions.extend(f.model, token: token, minutes: 60))
        XCTAssertEqual(f.timer.extensions, 6)
        XCTAssertFalse(f.model.sleepTimer.isActive)
        XCTAssertNil(SleepPillActions.timerSelection(f.model))
    }

    func testOldControlPanelCannotStopNewSessionsOrExtendBeyondCap() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        try SleepPillActions.awake(f.model, request: .duration(15))
        let oldAwake = try XCTUnwrap(SleepPillActions.controlToken(f.model, awake: true))
        try f.model.keepAwake.stop()
        try SleepPillActions.awake(f.model, request: .duration(30))
        XCTAssertThrowsError(try SleepPillActions.finish(f.model, token: oldAwake))
        XCTAssertTrue(f.model.keepAwake.isActive)
        try f.model.keepAwake.stop()
        try SleepPillActions.timer(f.model, minutes: 15)
        let oldTimer = try XCTUnwrap(SleepPillActions.controlToken(f.model, awake: false))
        f.model.sleepTimer.cancel()
        try SleepPillActions.timer(f.model, minutes: 1440)
        let current = try XCTUnwrap(SleepPillActions.controlToken(f.model, awake: false))
        XCTAssertThrowsError(try SleepPillActions.finish(f.model, token: oldTimer))
        XCTAssertThrowsError(try SleepPillActions.extend(f.model, token: current, minutes: 15))
        XCTAssertTrue(f.model.sleepTimer.isActive)
        XCTAssertEqual(f.model.sleepTimer.remainingSeconds, 86400)
        XCTAssertEqual(f.timer.extensions, 0)
    }

    func testUntilWheelRejectsSkippedTimeAndPreservesChosenDayAndRepeatedOffset() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let skippedDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
        XCTAssertNil(SleepWheelPicker.concreteDate(day: skippedDay, hour: 2, minute: 30, calendar: calendar))
        let valid = try XCTUnwrap(SleepWheelPicker.concreteDate(day: skippedDay, hour: 3, minute: 30, calendar: calendar))
        XCTAssertTrue(calendar.isDate(valid, inSameDayAs: skippedDay))
        let repeatedDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12)))
        let repeated = try XCTUnwrap(SleepWheelPicker.concreteDate(day: repeatedDay, hour: 1, minute: 30, calendar: calendar))
        XCTAssertTrue(calendar.isDate(repeated, inSameDayAs: repeatedDay))
        XCTAssertEqual(calendar.timeZone.secondsFromGMT(for: repeated), calendar.timeZone.secondsFromGMT(for: repeatedDay))
    }

    func testStaleRestartConsentCannotStopAReplacementSession() throws {
        let f = try PillFixture(); defer { f.cleanUp() }
        try SleepPillActions.awake(f.model, request: .duration(15))
        let previous = try XCTUnwrap(f.model.keepAwake.ownedAssertionID)
        try f.model.keepAwake.stop()
        try SleepPillActions.awake(f.model, request: .duration(30))
        let replacement = try XCTUnwrap(f.model.keepAwake.ownedAssertionID)
        XCTAssertThrowsError(try SleepPillActions.awake(f.model, request: .untilStopped, consent: .restartAwake(previous))) {
            XCTAssertEqual($0 as? SleepPillActionError, .confirmation(.restartAwake(replacement)))
        }
        XCTAssertEqual(f.model.keepAwake.ownedAssertionID, replacement)
        XCTAssertEqual(f.awake.releaseCount, 1)
    }
}

@MainActor private final class PillFixture {
    let suite: String
    let root: URL
    let preferences: UserDefaults
    let awake: AwakeFixture
    let timer: PillTimerDriver
    let clock: PillClock
    let model: TilveroModel
    init() throws {
        let suite = "SleepPills-\(UUID())"
        self.suite = suite
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        self.preferences = preferences
        preferences.set(false, forKey: "historyEnabled")
        let clock = PillClock(), awake = AwakeFixture(), timer = PillTimerDriver()
        self.clock = clock; self.awake = awake; self.timer = timer
        let awakeService = KeepAwakeService(driver: awake, wallNow: { clock.wall }, continuousNow: { clock.continuous })
        let timerService = SleepTimerService(driver: timer, monotonic: { clock.seconds }, suspending: { clock.seconds },
            wallClock: { clock.wall }, sleeper: { _ in try await Task.sleep(for: .seconds(86_400)) })
        model = TilveroModel(isDemo: false, preferences: preferences, historyURL: root.appendingPathComponent("History.sqlite"),
            snapshotProvider: { .unavailable(reason: "Memory-only Sleep pills fixture") },
            keepAwakeService: awakeService, sleepTimerService: timerService,
            sideEffects: .init(loginStatus: { "Not enabled" }, toggleLogin: {}, openBatterySettings: {}, rawCatalog: { [] }))
    }
    func cleanUp() {
        awake.failRelease = false; awake.failRead = false
        timer.failRelease = false
        model.stop()
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
@MainActor private final class PillClock {
    var seconds = 0.0
    var wall = Date()
    var continuous = ContinuousClock.now
    func advance(_ value: Int) {
        seconds += Double(value); wall = wall.addingTimeInterval(Double(value))
        continuous = continuous.advanced(by: .seconds(value))
    }
}
@MainActor private final class PillTimerDriver: SleepTimerTransport {
    var hasIdleHold = false
    var acquisitions = 0, replacements = 0, requests = 0, extensions = 0
    var failExtension: Int?
    var failReplace = false, failRelease = false, failAcquisitionAfterOwnership = false
    func acquireIdleHold(seconds: Int) throws {
        acquisitions += 1; hasIdleHold = true
        if failAcquisitionAfterOwnership { throw KeepAwakeError.unconfirmed }
    }
    func extendIdleHold() throws {
        extensions += 1
        if extensions == failExtension { throw KeepAwakeError.updateFailed }
    }
    func replaceIdleHold(seconds: Int) throws {
        replacements += 1
        if failReplace { throw KeepAwakeError.updateFailed }
    }
    func releaseIdleHold() throws {
        if failRelease { throw KeepAwakeError.releaseFailed }
        hasIdleHold = false
    }
    func isCurrentConsoleSession() -> Bool { true }
    func requestSleep() { requests += 1 }
}
