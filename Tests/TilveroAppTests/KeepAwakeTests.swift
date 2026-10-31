import XCTest
@testable import TilveroApp

@MainActor final class KeepAwakeTests: XCTestCase {
    func testReplacementReusesVerifiedAssertionAndCountsFromNow() throws {
        let driver = AwakeFixture()
        var now = ContinuousClock.now
        let service = KeepAwakeService(driver: driver, continuousNow: { now })
        try service.start(seconds: 900)
        let id = try XCTUnwrap(service.ownedAssertionID)
        now = now.advanced(by: .seconds(30))
        try service.replaceDuration(seconds: 3600)
        XCTAssertEqual(service.ownedAssertionID, id)
        XCTAssertEqual(service.remainingSeconds, 3600)
        now = now.advanced(by: .seconds(10))
        try service.replaceDuration(seconds: 1800)
        XCTAssertEqual(service.ownedAssertionID, id)
        XCTAssertEqual(service.remainingSeconds, 1800)
        XCTAssertEqual(driver.assertions[id]?.seconds, 1800)
        XCTAssertEqual(driver.createCount, 1)
        XCTAssertEqual(driver.releaseCount, 0)
        try service.stop()
    }

    func testReplacementRejectsBoundsAndIndefiniteSessionWithoutChangingAssertion() throws {
        let driver = AwakeFixture(), service = KeepAwakeService(driver: driver)
        XCTAssertThrowsError(try service.replaceDuration(seconds: 900))
        try service.startUntilStopped()
        XCTAssertThrowsError(try service.replaceDuration(seconds: 900))
        try service.stop()
        try service.start(seconds: 900)
        for seconds in [0, -1, 86401, Int.max] {
            XCTAssertThrowsError(try service.replaceDuration(seconds: seconds))
        }
        XCTAssertEqual(service.remainingSeconds, 900)
        XCTAssertEqual(driver.updateCount, 0)
        try service.replaceDuration(seconds: 1)
        try service.replaceDuration(seconds: 86400)
        try service.stop()
    }

    func testReplacementUpdateFailureKeepsOnlyConclusiveUnchangedTimeoutForRetry() throws {
        let driver = AwakeFixture(), service = KeepAwakeService(driver: driver)
        try service.start(seconds: 900)
        let id = service.ownedAssertionID
        driver.failUpdate = true
        XCTAssertThrowsError(try service.replaceDuration(seconds: 1800))
        XCTAssertEqual(service.ownedAssertionID, id)
        XCTAssertTrue(service.isActive)
        XCTAssertEqual(service.remainingSeconds, 900)
        XCTAssertEqual(driver.releaseCount, 0)
        driver.failUpdate = false
        try service.replaceDuration(seconds: 1800)
        XCTAssertEqual(service.ownedAssertionID, id)
        try service.stop()
    }

    func testReplacementWrongReadbackCleansOwnHoldOrRetainsReleaseRetry() throws {
        for failRelease in [false, true] {
            let driver = AwakeFixture(), service = KeepAwakeService(driver: driver)
            try service.start(seconds: 900)
            driver.wrongUpdatedTimeout = true
            driver.failRelease = failRelease
            XCTAssertThrowsError(try service.replaceDuration(seconds: 1800))
            XCTAssertFalse(service.isActive)
            XCTAssertEqual(service.hasOwnedAssertion, failRelease)
            if failRelease {
                XCTAssertThrowsError(try service.replaceDuration(seconds: 3600))
                driver.failRelease = false
                try service.stop()
            }
            XCTAssertTrue(driver.assertions.isEmpty)
        }
    }

    func testReplacementNeverChangesOrReleasesReusedForeignID() throws {
        let driver = AwakeFixture(), service = KeepAwakeService(driver: driver)
        try service.start(seconds: 900)
        let id = try XCTUnwrap(service.ownedAssertionID)
        driver.assertions[id] = .init(name: "Foreign app", kind: "PreventUserIdleSystemSleep", active: true, seconds: 900, releasesOnTimeout: true)
        XCTAssertThrowsError(try service.replaceDuration(seconds: 1800))
        XCTAssertEqual(driver.assertions[id]?.name, "Foreign app")
        XCTAssertEqual(driver.assertions[id]?.seconds, 900)
        XCTAssertEqual(driver.updateCount, 0)
        XCTAssertEqual(driver.releaseCount, 0)
    }

    func testOldAssertionExpiryCannotReleaseTheSameIDAfterReplacement() async throws {
        let driver = AwakeFixture(), gate = AwakeExpiryGate()
        let service = KeepAwakeService(driver: driver, sleeper: { _ in await gate.wait() })
        try service.start(seconds: 900)
        while await gate.count < 1 { await Task.yield() }
        let id = service.ownedAssertionID
        try service.replaceDuration(seconds: 3600)
        while await gate.count < 2 { await Task.yield() }
        await gate.resumeFirst()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(service.ownedAssertionID, id)
        XCTAssertTrue(service.isActive)
        XCTAssertEqual(driver.releaseCount, 0)
        try service.stop()
        await gate.resumeFirst()
    }

    func testExplicitStartVerifiesOwnAssertionAndDuplicateStartCannotAcquireAnother() throws {
        let driver = AwakeFixture(), service = KeepAwakeService(driver: driver)
        XCTAssertFalse(service.isActive)
        try service.start(seconds: 900)
        XCTAssertTrue(service.isActive)
        let id = try XCTUnwrap(service.ownedAssertionID)
        XCTAssertEqual(driver.assertions[id]?.seconds, 900)
        XCTAssertEqual(driver.assertions[id]?.kind, "PreventUserIdleSystemSleep")
        XCTAssertTrue(driver.assertions[id]?.releasesOnTimeout == true)
        XCTAssertThrowsError(try service.start(seconds: 1800))
        XCTAssertEqual(driver.assertions.count, 1)
        try service.stop()
        XCTAssertTrue(driver.assertions.isEmpty)
        XCTAssertFalse(service.hasOwnedAssertion)
    }
    func testCreateFailureAndInvalidDurationNeverClaimActive() {
        let driver = AwakeFixture(), service = KeepAwakeService(driver: driver)
        XCTAssertThrowsError(try service.start(seconds: 0))
        XCTAssertThrowsError(try service.start(seconds: 86401))
        driver.failCreate = true
        XCTAssertThrowsError(try service.start(seconds: 900))
        XCTAssertFalse(service.isActive); XCTAssertFalse(service.hasOwnedAssertion)
    }
    func testFiniteBoundaryOneSecondAndTwentyFourHours() throws {
        let driver = AwakeFixture(), service = KeepAwakeService(driver: driver)
        for seconds in [1, 86_400] {
            try service.start(seconds: seconds)
            XCTAssertTrue(service.isActive)
            XCTAssertEqual(driver.assertions[try XCTUnwrap(service.ownedAssertionID)]?.seconds, seconds)
            try service.stop()
        }
    }
    func testMismatchedReadbackCleansOwnAssertionAndReleaseFailureKeepsRetry() throws {
        let driver = AwakeFixture(), service = KeepAwakeService(driver: driver)
        driver.wrongTimeoutOnCreate = true
        XCTAssertThrowsError(try service.start(seconds: 900))
        XCTAssertTrue(driver.assertions.isEmpty)
        XCTAssertFalse(service.isActive)
        driver.wrongTimeoutOnCreate = false
        try service.start(seconds: 900)
        driver.failRelease = true
        XCTAssertThrowsError(try service.stop())
        XCTAssertTrue(service.hasOwnedAssertion); XCTAssertTrue(service.isActive)
        driver.failRelease = false
        try service.stop()
        XCTAssertFalse(service.hasOwnedAssertion)
    }
    func testOSExpiryReconciliationNeverReleasesForeignAssertionOrReenablesAfterRestart() throws {
        let driver = AwakeFixture(), service = KeepAwakeService(driver: driver)
        try service.start(seconds: 900)
        let ownID = try XCTUnwrap(service.ownedAssertionID)
        driver.assertions[99] = .init(name: "Foreign app", kind: "PreventUserIdleSystemSleep", active: true, seconds: 900, releasesOnTimeout: true)
        driver.assertions.removeValue(forKey: ownID)
        try service.reconcile()
        XCTAssertFalse(service.hasOwnedAssertion)
        XCTAssertEqual(driver.assertions[99]?.name, "Foreign app")
        let reopened = KeepAwakeService(driver: driver)
        XCTAssertFalse(reopened.hasOwnedAssertion)
        XCTAssertEqual(driver.assertions.count, 1)
    }
    func testDisallowedBuildAndSimulationCannotCreateAssertions() throws {
        let driver = AwakeFixture()
        let service = KeepAwakeService(driver: driver, allowed: false)
        XCTAssertThrowsError(try service.start(seconds: 900))
        XCTAssertFalse(service.hasOwnedAssertion)
        XCTAssertTrue(driver.assertions.isEmpty)
    }
    func testDelayedExpiryFromStoppedSessionCannotStopTheNextSession() async throws {
        let driver = AwakeFixture(), gate = AwakeExpiryGate()
        let service = KeepAwakeService(driver: driver, sleeper: { _ in await gate.wait() })
        try service.start(seconds: 900)
        while await gate.count == 0 { await Task.yield() }
        try service.stop()
        try service.start(seconds: 1800)
        while await gate.count < 2 { await Task.yield() }
        let current = try XCTUnwrap(service.ownedAssertionID)
        await gate.resumeFirst()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(service.ownedAssertionID, current)
        XCTAssertTrue(service.isActive)
        try service.stop()
        await gate.resumeFirst()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(driver.releaseCount, 2)
    }
    func testDurationAndCompositionPersistButOpeningPreviewNeverStartsOrRestarts() async throws {
        let suite = "TilveroAwake-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let driver = AwakeFixture()
        let model = TilveroModel(isDemo: true, preferences: prefs, keepAwakeTransport: driver)
        model.keepAwakeDuration = .hour
        model.overviewPreferences.hidden.remove(.keepAwake)
        XCTAssertThrowsError(try model.keepAwake.start(seconds: 900), "Simulation never acquires physical assertions")
        let reopened = TilveroModel(isDemo: true, preferences: prefs, keepAwakeTransport: driver)
        XCTAssertEqual(reopened.keepAwakeDuration, .hour)
        XCTAssertFalse(reopened.keepAwake.hasOwnedAssertion)
        XCTAssertTrue(driver.assertions.isEmpty)
        XCTAssertFalse(reopened.overviewPreferences.hidden.contains(.keepAwake))
    }
    func testTerminationFailureKeepsOwnedSessionForRetryAndNormalStopReleases() async throws {
        let suite = "TilveroAwake-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let driver = AwakeFixture()
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"), keepAwakeTransport: driver)
        try model.keepAwake.start(seconds: 900)
        driver.failRelease = true
        let denied = await model.prepareForTermination()
        XCTAssertFalse(denied)
        XCTAssertNotNil(model.terminationRecoveryMessage)
        XCTAssertTrue(model.keepAwake.hasOwnedAssertion)
        driver.failRelease = false
        model.stop()
        XCTAssertTrue(driver.assertions.isEmpty)
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
    }

    func testReusedForeignIDCannotBeReleased() throws {
        let driver = AwakeFixture(), service = KeepAwakeService(driver: driver)
        try service.start(seconds: 900)
        let ownID = try XCTUnwrap(service.ownedAssertionID)
        driver.assertions[ownID] = .init(name: "Foreign app", kind: "PreventUserIdleSystemSleep", active: true, seconds: 900, releasesOnTimeout: true)
        XCTAssertThrowsError(try service.stop())
        XCTAssertEqual(driver.assertions[ownID]?.name, "Foreign app")
    }
}

@MainActor final class AwakeFixture: KeepAwakeTransport {
    var assertions: [UInt32: KeepAwakeAssertion] = [:]
    var failCreate = false, failRelease = false, wrongTimeoutOnCreate = false
    var failUpdate = false, wrongUpdatedTimeout = false
    var beforeUpdate: ((AwakeFixture, UInt32) -> Void)?
    var afterUpdate: ((AwakeFixture, UInt32) -> Void)?
    var failRead = false
    var releaseCount = 0, createCount = 0, updateCount = 0
    private var next: UInt32 = 1
    func create(seconds: Int, name: String) throws -> UInt32 {
        try create(timeout: seconds, name: name)
    }
    func createUntilStopped(name: String) throws -> UInt32 { try create(timeout: nil, name: name) }
    private func create(timeout: Int?, name: String) throws -> UInt32 {
        if failCreate { throw KeepAwakeError.creationFailed }
        createCount += 1
        let id = next; next += 1
        assertions[id] = .init(name: name, kind: "PreventUserIdleSystemSleep", active: true, seconds: timeout.map { wrongTimeoutOnCreate ? $0 + 1 : $0 }, releasesOnTimeout: true)
        return id
    }
    func setTimeout(_ id: UInt32, seconds: Int, name: String) throws {
        beforeUpdate?(self, id)
        guard let old = assertions[id], old.name == name, old.kind == "PreventUserIdleSystemSleep" else { throw KeepAwakeError.foreignAssertion }
        guard old.active, old.seconds != nil else { throw KeepAwakeError.unconfirmed }
        if failUpdate { throw KeepAwakeError.updateFailed }
        updateCount += 1
        assertions[id] = .init(name: name, kind: old.kind, active: old.active, seconds: wrongUpdatedTimeout ? seconds + 1 : seconds, releasesOnTimeout: true)
        afterUpdate?(self, id)
    }
    func read(_ id: UInt32) throws -> KeepAwakeAssertion? {
        if failRead { throw KeepAwakeError.unconfirmed }
        return assertions[id]
    }
    func release(_ id: UInt32, name: String) throws {
        guard assertions[id]?.name == name else { throw KeepAwakeError.foreignAssertion }
        if failRelease { throw KeepAwakeError.releaseFailed }
        releaseCount += 1
        assertions.removeValue(forKey: id)
    }
}

private actor AwakeExpiryGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var count: Int { waiting.count }
    func wait() async { await withCheckedContinuation { waiting.append($0) } }
    func resumeFirst() { if !waiting.isEmpty { waiting.removeFirst().resume() } }
}
