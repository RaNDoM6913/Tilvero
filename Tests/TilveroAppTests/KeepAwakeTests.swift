import XCTest
@testable import TilveroApp

@MainActor final class KeepAwakeTests: XCTestCase {
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
        XCTAssertThrowsError(try service.start(seconds: 7201))
        driver.failCreate = true
        XCTAssertThrowsError(try service.start(seconds: 900))
        XCTAssertFalse(service.isActive); XCTAssertFalse(service.hasOwnedAssertion)
    }
    func testMismatchedReadbackCleansOwnAssertionAndReleaseFailureKeepsRetry() throws {
        let driver = AwakeFixture(), service = KeepAwakeService(driver: driver)
        driver.wrongKind = true
        XCTAssertThrowsError(try service.start(seconds: 900))
        XCTAssertTrue(driver.assertions.isEmpty)
        XCTAssertFalse(service.isActive)
        driver.wrongKind = false
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
    var failCreate = false, failRelease = false, wrongKind = false
    var releaseCount = 0
    private var next: UInt32 = 1
    func create(seconds: Int, name: String) throws -> UInt32 {
        if failCreate { throw KeepAwakeError.creationFailed }
        let id = next; next += 1
        assertions[id] = .init(name: name, kind: wrongKind ? "wrong" : "PreventUserIdleSystemSleep", active: true, seconds: seconds, releasesOnTimeout: true)
        return id
    }
    func read(_ id: UInt32) throws -> KeepAwakeAssertion? { assertions[id] }
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
