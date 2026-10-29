import XCTest
import IOKit.pwr_mgt
@testable import TilveroApp

@MainActor final class FlexibleAwakeServiceTests: XCTestCase {
    func testExplicitIndefiniteHasNoCountdownOrExtensionAndStops() throws {
        let driver = AwakeFixture(), service = KeepAwakeService(driver: driver)
        try service.startUntilStopped()
        XCTAssertEqual(service.expiry, .untilStopped)
        XCTAssertTrue(service.isActive)
        XCTAssertNil(driver.assertions[try XCTUnwrap(service.ownedAssertionID)]?.seconds)
        XCTAssertThrowsError(try service.extend(by: 900))
        XCTAssertThrowsError(try service.start(seconds: 60))
        XCTAssertEqual(driver.createCount, 1)
        try service.stop()
        XCTAssertNil(service.expiry)
        XCTAssertFalse(service.hasOwnedAssertion)
        XCTAssertFalse(KeepAwakeService(driver: driver).isActive)
    }

    func testExtensionUpdatesSameIDFromCeilingOfRemainingAndAccumulates() throws {
        let clock = AwakeTestClock(), driver = AwakeFixture()
        let service = makeService(driver, clock)
        try service.start(seconds: 200)
        let id = try XCTUnwrap(service.ownedAssertionID)
        clock.advance(100.2)
        try service.extend(by: 900)
        XCTAssertEqual(service.remainingSeconds, 1000)
        XCTAssertEqual(driver.assertions[id]?.seconds, 1000)
        XCTAssertEqual(service.ownedAssertionID, id)
        clock.advance(10)
        try service.extend(by: 1800)
        XCTAssertEqual(service.remainingSeconds, 2790)
        XCTAssertEqual(driver.createCount, 1)
        XCTAssertEqual(driver.updateCount, 2)
        try service.stop()
    }

    func testExtensionCapAndUnacceptedDeltaCannotWrite() throws {
        let clock = AwakeTestClock(), driver = AwakeFixture()
        let service = makeService(driver, clock)
        try service.start(seconds: 86_400)
        for delta in [900, 1800, 3600, 0, -900, Int.max] {
            XCTAssertThrowsError(try service.extend(by: delta))
        }
        XCTAssertEqual(driver.updateCount, 0)
        XCTAssertEqual(service.remainingSeconds, 86_400)
        try service.stop()
    }

    func testExpiredInactiveDeletedAndForeignCannotBeExtendedOrRecreated() throws {
        for mode in 0...3 {
            let clock = AwakeTestClock(), driver = AwakeFixture()
            let service = makeService(driver, clock)
            try service.start(seconds: 100)
            let id = try XCTUnwrap(service.ownedAssertionID)
            let old = try XCTUnwrap(driver.assertions[id])
            switch mode {
            case 0: clock.advance(101)
            case 1: driver.assertions[id] = .init(name: old.name, kind: old.kind, active: false, seconds: 100, releasesOnTimeout: true)
            case 2: driver.assertions.removeValue(forKey: id)
            default: driver.assertions[id] = .init(name: "Foreign", kind: old.kind, active: true, seconds: 100, releasesOnTimeout: true)
            }
            XCTAssertThrowsError(try service.extend(by: 900))
            XCTAssertEqual(driver.updateCount, 0)
            XCTAssertEqual(driver.createCount, 1)
            XCTAssertEqual(driver.releaseCount, mode == 0 ? 1 : 0)
        }
    }

    func testFailedSetterConfirmedUnchangedPreservesPriorDeadlineForRetry() throws {
        let clock = AwakeTestClock(), driver = AwakeFixture()
        let service = makeService(driver, clock)
        try service.start(seconds: 200)
        clock.advance(100)
        driver.failUpdate = true
        XCTAssertThrowsError(try service.extend(by: 900))
        XCTAssertTrue(service.isActive)
        XCTAssertEqual(service.remainingSeconds, 100)
        XCTAssertEqual(driver.releaseCount, 0)
        driver.failUpdate = false
        try service.extend(by: 900)
        XCTAssertEqual(service.remainingSeconds, 1000)
        try service.stop()
    }

    func testUnconfirmedUpdateReleasesOwnAndReleaseFailureRetainsStopRetry() throws {
        for releaseFails in [false, true] {
            let clock = AwakeTestClock(), driver = AwakeFixture()
            let service = makeService(driver, clock)
            try service.start(seconds: 200)
            driver.wrongUpdatedTimeout = true
            driver.failRelease = releaseFails
            XCTAssertThrowsError(try service.extend(by: 900))
            XCTAssertFalse(service.isActive)
            XCTAssertEqual(service.hasOwnedAssertion, releaseFails)
            XCTAssertEqual(driver.createCount, 1)
            if releaseFails {
                XCTAssertThrowsError(try service.start(seconds: 60))
                XCTAssertThrowsError(try service.extend(by: 900))
                driver.failRelease = false
                try service.stop()
                XCTAssertFalse(service.hasOwnedAssertion)
            }
        }
    }

    func testOldSameSessionExpiryCannotStopExtendedAssertion() async throws {
        let clock = AwakeTestClock(), driver = AwakeFixture(), gate = FlexibleAwakeGate()
        let service = KeepAwakeService(driver: driver, sleeper: { _ in await gate.wait() },
                                       wallNow: { clock.wall }, continuousNow: { clock.continuous })
        try service.start(seconds: 100)
        while await gate.count < 1 { await Task.yield() }
        try service.extend(by: 900)
        while await gate.count < 2 { await Task.yield() }
        await gate.resumeFirst()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(service.isActive)
        XCTAssertEqual(driver.releaseCount, 0)
        clock.advance(1001)
        await gate.resumeFirst()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(service.hasOwnedAssertion)
        XCTAssertEqual(driver.releaseCount, 1)
    }

    func testWallJumpDoesNotChangeDurationButUntilRearmsSameIDAndExpires() throws {
        let clock = AwakeTestClock(), driver = AwakeFixture()
        let service = makeService(driver, clock)
        try service.start(seconds: 200)
        clock.wall = clock.wall.addingTimeInterval(-1000)
        try service.reconcile()
        XCTAssertEqual(service.remainingSeconds, 200)
        XCTAssertEqual(driver.updateCount, 0)
        try service.stop()
        let target = clock.wall.addingTimeInterval(1000)
        try service.start(until: target)
        let id = try XCTUnwrap(service.ownedAssertionID)
        clock.wall = clock.wall.addingTimeInterval(-200)
        try service.reconcile()
        XCTAssertEqual(driver.assertions[id]?.seconds, 1200)
        XCTAssertEqual(service.expiry, .until(target))
        XCTAssertEqual(driver.updateCount, 1)
        try service.reconcile()
        XCTAssertEqual(driver.updateCount, 1, "Display reconciliation does not continuously rearm")
        clock.wall = target.addingTimeInterval(1)
        try service.reconcile()
        XCTAssertFalse(service.hasOwnedAssertion)
    }

    func testUntilExtensionMovesFixedTargetAndClockBackwardOverLimitStops() throws {
        let clock = AwakeTestClock(), driver = AwakeFixture()
        let service = makeService(driver, clock)
        let target = clock.wall.addingTimeInterval(1000)
        try service.start(until: target)
        try service.extend(by: 900)
        XCTAssertEqual(service.expiry, .until(target.addingTimeInterval(900)))
        clock.wall = clock.wall.addingTimeInterval(-86_400)
        XCTAssertThrowsError(try service.reconcile()) { error in
            XCTAssertEqual(error.localizedDescription, "The system clock moved the end time beyond 24 hours. The Keep Awake session was stopped.")
        }
        XCTAssertFalse(service.hasOwnedAssertion)
        XCTAssertFalse(service.isActive)
    }

    func testEveryNewStartAndUpdateHonorsUnavailableGate() throws {
        let driver = AwakeFixture(), service = KeepAwakeService(driver: driver, allowed: false)
        XCTAssertThrowsError(try service.startUntilStopped())
        XCTAssertThrowsError(try service.start(until: Date().addingTimeInterval(100)))
        XCTAssertThrowsError(try service.extend(by: 900))
        XCTAssertEqual(driver.createCount, 0)
        XCTAssertEqual(driver.updateCount, 0)
    }

    func testUntilRejectsPastAndBeyondTwentyFourHoursWithoutCreate() {
        let clock = AwakeTestClock(), driver = AwakeFixture()
        let service = makeService(driver, clock)
        for interval in [-1.0, 0, 86_400.1, Double.infinity, Double.nan] {
            XCTAssertThrowsError(try service.start(until: clock.wall.addingTimeInterval(interval)))
        }
        XCTAssertEqual(driver.createCount, 0)
    }

    func testNativeDecoderDistinguishesNoTimeoutAndRejectsMalformedNumbers() throws {
        var raw: [String: Any] = [kIOPMAssertionNameKey as String: "Tilvero Keep Awake test",
                                  kIOPMAssertionTypeKey as String: "PreventUserIdleSystemSleep",
                                  kIOPMAssertionLevelKey as String: NSNumber(value: 255)]
        XCTAssertNil(try NativeKeepAwakeTransport.decode(raw).seconds)
        raw[kIOPMAssertionTimeoutKey as String] = NSNumber(value: 0)
        XCTAssertNil(try NativeKeepAwakeTransport.decode(raw).seconds)
        for invalid in ["900", NSNumber(value: -1), NSNumber(value: Double.infinity), NSNumber(value: 1.5), NSNumber(value: true)] as [Any] {
            raw[kIOPMAssertionTimeoutKey as String] = invalid
            XCTAssertThrowsError(try NativeKeepAwakeTransport.decode(raw))
        }
        raw[kIOPMAssertionTimeoutKey as String] = NSNumber(value: 900)
        raw[kIOPMAssertionTimeoutActionKey as String] = kIOPMAssertionTimeoutActionRelease
        XCTAssertEqual(try NativeKeepAwakeTransport.decode(raw).seconds, 900)
    }

    func testUnconfirmedPreflightCleansOwnStateAndKeepsStopRetryIfNeeded() throws {
        for releaseFails in [false, true] {
            let driver = AwakeFixture(), clock = AwakeTestClock(), service = makeService(driver, clock)
            try service.start(seconds: 200)
            let id = try XCTUnwrap(service.ownedAssertionID), original = try XCTUnwrap(driver.assertions[id])
            driver.assertions[id] = .init(name: original.name, kind: original.kind, active: true, seconds: nil, releasesOnTimeout: true)
            driver.failRelease = releaseFails
            XCTAssertThrowsError(try service.extend(by: 900))
            XCTAssertFalse(service.isActive)
            XCTAssertEqual(service.hasOwnedAssertion, releaseFails)
            XCTAssertEqual(driver.updateCount, 0)
            driver.failRelease = false
            try service.stop()
        }
    }

    func testUntilRearmFailureDoesNotClaimPriorTimeoutIsConfirmedForChangedClock() throws {
        let driver = AwakeFixture(), clock = AwakeTestClock(), service = makeService(driver, clock)
        try service.start(until: clock.wall.addingTimeInterval(1000))
        clock.wall = clock.wall.addingTimeInterval(-300)
        driver.failUpdate = true
        XCTAssertThrowsError(try service.reconcile())
        XCTAssertFalse(service.hasOwnedAssertion)
        XCTAssertFalse(service.isActive)
        XCTAssertEqual(driver.releaseCount, 1)
    }

    func testSameNameWrongKindCannotBeReleased() throws {
        let driver = AwakeFixture(), service = KeepAwakeService(driver: driver)
        try service.start(seconds: 100)
        let id = try XCTUnwrap(service.ownedAssertionID), original = try XCTUnwrap(driver.assertions[id])
        driver.assertions[id] = .init(name: original.name, kind: "Foreign kind", active: true, seconds: 100, releasesOnTimeout: true)
        XCTAssertThrowsError(try service.stop())
        XCTAssertEqual(driver.releaseCount, 0)
        XCTAssertNotNil(driver.assertions[id])
    }

    func testSharedDraftPersistsFiniteCustomOnlyAndNeverResumes() throws {
        let suite = "TilveroFlexibleDraft-\(UUID())", prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let driver = AwakeFixture(), model = TilveroModel(isDemo: true, preferences: prefs, keepAwakeTransport: driver)
        defer { model.stop() }
        XCTAssertEqual(model.keepAwakeDraft, .duration(.halfHour))
        XCTAssertEqual(KeepAwakeDuration.allCases.map(\.rawValue), [15,30,60,120,240,480])
        for minutes in [1,1440] {
            model.selectKeepAwakeOption(-1)
            model.keepAwakeCustomMinutes = String(minutes)
            XCTAssertEqual(model.keepAwakeDraft, .duration(try XCTUnwrap(KeepAwakeDuration(rawValue: minutes))))
            XCTAssertEqual(prefs.integer(forKey: "keepAwakeMinutes"), minutes)
        }
        for invalid in ["0", "1441", "1.5", "", "-1", "not a number"] {
            model.keepAwakeCustomMinutes = invalid
            XCTAssertFalse(model.canStartKeepAwakeDraft)
            XCTAssertThrowsError(try model.startKeepAwakeDraft())
        }
        model.selectKeepAwakeOption(0)
        XCTAssertEqual(model.keepAwakeDraft, .untilStopped)
        let reopened = TilveroModel(isDemo: true, preferences: prefs, keepAwakeTransport: driver)
        defer { reopened.stop() }
        XCTAssertEqual(reopened.keepAwakeDraft, .duration(try XCTUnwrap(KeepAwakeDuration(rawValue: 1440))))
        XCTAssertFalse(reopened.keepAwake.hasOwnedAssertion)
        XCTAssertEqual(driver.createCount, 0)
        for invalid in [0, -1, 1441] {
            prefs.set(invalid, forKey: "keepAwakeMinutes")
            let fallback = TilveroModel(isDemo: true, preferences: prefs, keepAwakeTransport: driver)
            XCTAssertEqual(fallback.keepAwakeDraft, .duration(.halfHour))
            fallback.stop()
        }
    }

    func testMissingTimeoutDeletedAndForeignPostUpdateReadbackNeverClaimsSuccess() throws {
        for mode in 0...2 {
            let driver = AwakeFixture(), service = KeepAwakeService(driver: driver)
            try service.start(seconds: 200)
            let id = try XCTUnwrap(service.ownedAssertionID)
            driver.afterUpdate = { fixture, id in
                let old = fixture.assertions[id]!
                if mode == 1 { fixture.assertions.removeValue(forKey: id) }
                else { fixture.assertions[id] = .init(name: mode == 2 ? "Foreign" : old.name, kind: old.kind, active: true,
                                                      seconds: mode == 0 ? nil : 1100, releasesOnTimeout: true) }
            }
            XCTAssertThrowsError(try service.extend(by: 900))
            XCTAssertFalse(service.isActive)
            XCTAssertEqual(driver.createCount, 1)
            if mode == 2 {
                XCTAssertEqual(driver.assertions[id]?.name, "Foreign")
                XCTAssertEqual(driver.releaseCount, 0)
                XCTAssertTrue(service.hasOwnedAssertion)
            } else { XCTAssertFalse(service.hasOwnedAssertion) }
        }
    }

    func testPersistentReadFailureRetainsStopUntilAbsenceCanBeConfirmed() throws {
        let driver = AwakeFixture(), service = KeepAwakeService(driver: driver)
        try service.start(seconds: 200)
        driver.afterUpdate = { fixture, _ in fixture.failRead = true }
        XCTAssertThrowsError(try service.extend(by: 900))
        XCTAssertFalse(service.isActive)
        XCTAssertTrue(service.hasOwnedAssertion)
        XCTAssertEqual(driver.releaseCount, 1)
        XCTAssertThrowsError(try service.start(seconds: 100))
        driver.failRead = false
        try service.stop()
        XCTAssertFalse(service.hasOwnedAssertion)
        XCTAssertEqual(driver.releaseCount, 1)
    }

    func testNativeTransportRejectsUnownedAndInvalidUpdatesBeforeAnyOSCall() {
        let native = NativeKeepAwakeTransport()
        for seconds in [0, -1, 86_401] { XCTAssertThrowsError(try native.setTimeout(77, seconds: seconds, name: "Tilvero Keep Awake fake")) }
        XCTAssertThrowsError(try native.setTimeout(77, seconds: 900, name: "Tilvero Keep Awake fake"))
        XCTAssertThrowsError(try native.release(77, name: "Tilvero Keep Awake fake"))
    }

    func testCountdownDistinguishesLongFiniteAndIndefinitePresentation() {
        XCTAssertEqual(KeepAwakePresentation.countdown(14400), "4:00:00")
        XCTAssertEqual(KeepAwakePresentation.countdown(61), "1:01")
        XCTAssertEqual(KeepAwakePresentation.countdown(-1), "0:00")
    }

    func testPersistedDurationRejectsCoercedStringsBooleansAndFractions() {
        for invalid in ["120", true, 1.5, Double.nan, -1, 1441] as [Any] {
            XCTAssertEqual(KeepAwakeDuration.load(invalid), .halfHour)
        }
        XCTAssertEqual(KeepAwakeDuration.load(1).rawValue, 1)
        XCTAssertEqual(KeepAwakeDuration.load(1440).rawValue, 1440)
    }

    func testUntilPresentationDisambiguatesDSTRepeatedHourByUTCOffset() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let formatter = ISO8601DateFormatter()
        let first = try XCTUnwrap(formatter.date(from: "2026-11-01T05:30:00Z"))
        let repeated = try XCTUnwrap(formatter.date(from: "2026-11-01T06:30:00Z"))
        XCTAssertNotEqual(KeepAwakePresentation.endTime(first, timeZone: zone), KeepAwakePresentation.endTime(repeated, timeZone: zone))
        XCTAssertTrue(KeepAwakePresentation.endTime(first, timeZone: zone).contains("04:00"))
        XCTAssertTrue(KeepAwakePresentation.endTime(repeated, timeZone: zone).contains("05:00"))
    }

    func testModelDraftSelectionDoesNotAlterActiveSessionAndExplicitInfinityDoesNotPersist() throws {
        let suite = "TilveroFlexibleLiveDraft-\(UUID())", prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        prefs.set(false, forKey: "historyEnabled")
        let driver = AwakeFixture()
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                                 snapshotProvider: { .unavailable(reason: "Awake fixture") }, keepAwakeTransport: driver)
        defer { model.stop() }
        XCTAssertTrue(model.canStartKeepAwakeDraft)
        try model.startKeepAwakeDraft()
        let id = try XCTUnwrap(model.keepAwake.ownedAssertionID)
        model.selectKeepAwakeOption(0)
        XCTAssertEqual(model.keepAwakeDraft, .untilStopped)
        XCTAssertEqual(model.keepAwake.expiry, .duration)
        XCTAssertEqual(model.keepAwake.ownedAssertionID, id)
        XCTAssertEqual(driver.createCount, 1)
        XCTAssertFalse(model.canStartKeepAwakeDraft)
        try model.keepAwake.stop()
        try model.startKeepAwakeDraft()
        XCTAssertEqual(model.keepAwake.expiry, .untilStopped)
        XCTAssertEqual(driver.createCount, 2)
        let reopened = TilveroModel(isDemo: true, preferences: prefs, keepAwakeTransport: driver)
        defer { reopened.stop() }
        XCTAssertEqual(reopened.keepAwakeDraft, .duration(.halfHour))
        XCTAssertFalse(reopened.keepAwake.hasOwnedAssertion)
        try model.keepAwake.stop()
    }

    func testForeignSwapBetweenPreflightAndSetterIsNotMutatedOrReleased() throws {
        let driver = AwakeFixture(), service = KeepAwakeService(driver: driver)
        try service.start(seconds: 200)
        let id = try XCTUnwrap(service.ownedAssertionID)
        driver.beforeUpdate = { fixture, id in
            fixture.assertions[id] = .init(name: "Foreign at setter", kind: "PreventUserIdleSystemSleep", active: true, seconds: 42, releasesOnTimeout: true)
        }
        XCTAssertThrowsError(try service.extend(by: 900))
        XCTAssertFalse(service.isActive)
        XCTAssertEqual(driver.assertions[id]?.seconds, 42)
        XCTAssertEqual(driver.updateCount, 0)
        XCTAssertEqual(driver.releaseCount, 0)
        XCTAssertEqual(driver.createCount, 1)
        XCTAssertThrowsError(try service.start(seconds: 60))
    }

    func testCleanedExtensionFailureRemainsVisibleThroughGlobalModelNotice() throws {
        let suite = "TilveroAwakeFailureNotice-\(UUID())", prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        prefs.set(false, forKey: "historyEnabled")
        let driver = AwakeFixture()
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                                 snapshotProvider: { .unavailable(reason: "Awake fixture") }, keepAwakeTransport: driver)
        defer { model.stop() }
        try model.startKeepAwakeDraft()
        driver.wrongUpdatedTimeout = true
        XCTAssertThrowsError(try model.keepAwake.extend(by: 900))
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
        XCTAssertEqual(model.notice, model.keepAwake.message.map(L10n.text))
        XCTAssertNotNil(model.notice)
        driver.wrongUpdatedTimeout = false
        try model.startKeepAwakeDraft()
        XCTAssertNil(model.notice, "Explicit next Start clears only its prior Awake error")
        model.draftText = "invalid"
        XCTAssertFalse(model.validateTypedDraft())
        let unrelated = model.notice
        XCTAssertNotNil(unrelated)
        try model.keepAwake.stop()
        XCTAssertEqual(model.notice, unrelated, "Awake Stop preserves another feature's notice")
    }

    private func makeService(_ driver: AwakeFixture, _ clock: AwakeTestClock) -> KeepAwakeService {
        KeepAwakeService(driver: driver, wallNow: { clock.wall }, continuousNow: { clock.continuous })
    }
}

@MainActor private final class AwakeTestClock {
    var wall = Date(timeIntervalSince1970: 1_000_000)
    var continuous = ContinuousClock.now
    func advance(_ seconds: Double) {
        wall = wall.addingTimeInterval(seconds)
        continuous = continuous.advanced(by: .seconds(seconds))
    }
}

private actor FlexibleAwakeGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var count: Int { waiting.count }
    func wait() async { await withCheckedContinuation { waiting.append($0) } }
    func resumeFirst() { if !waiting.isEmpty { waiting.removeFirst().resume() } }
}
