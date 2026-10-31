import XCTest
import PowerCore
import Carbon
@testable import TilveroApp

@MainActor final class SleepTimerIntegrationTests: XCTestCase {
    func testSystemQuitReasonsDoNotUseTheInteractiveTimerQuitPolicy() {
        for reason in [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut, kAELogOut] {
            XCTAssertTrue(SleepTimerQuitReason.isSystem(reason))
        }
        XCTAssertFalse(SleepTimerQuitReason.isSystem(nil))
        XCTAssertFalse(SleepTimerQuitReason.isSystem(kAEQuitApplication))
    }
    func testCustomInputRejectsFractionsOverflowSignsAndOutOfRange() {
        for value in ["", "0", "1441", "-1", "+30", "1.5", "30 min", String(repeating: "9", count: 50)] {
            XCTAssertNil(SleepTimerInput.minutes(value), value)
        }
        XCTAssertEqual(SleepTimerInput.minutes(" 1440\n"), 1440)
        XCTAssertEqual(SleepTimerInput.minutes("1"), 1)
    }
    func testDefaultSimulationCannotStartPhysicalSleepAndOnlyDraftPersists() throws {
        let suite = "SleepDraft-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let driver = IntegrationSleepDriver()
        let model = TilveroModel(isDemo: true, preferences: prefs, sleepTimerTransport: driver)
        model.sleepTimerMinutes = "45"
        XCTAssertThrowsError(try model.startSleepTimer())
        let reopened = TilveroModel(isDemo: true, preferences: prefs, sleepTimerTransport: driver)
        XCTAssertEqual(reopened.sleepTimerMinutes, "45")
        XCTAssertFalse(reopened.sleepTimer.isActive)
        XCTAssertEqual(driver.requests, 0)
    }
    func testInFlightRefreshFinishesBeforeExpiryCanSubmitAndNewAutoActionsAreGated() async throws {
        let suite = "SleepRefresh-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let driver = IntegrationSleepDriver(), clock = IntegrationSleepClock(), gate = IntegrationSnapshotGate()
        let service = SleepTimerService(driver: driver, monotonic: { clock.value }, suspending: { clock.value }, sleeper: { _ in try await Task.sleep(for: .seconds(3600)) })
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
            snapshotProvider: { await gate.wait() }, sleepTimerService: service)
        try service.start(minutes: 1)
        let refresh = Task { await model.refresh() }
        while !(await gate.waiting) { await Task.yield() }
        clock.value = 60
        let expiry = Task { await service.reconcile() }
        while service.phase != .preparing { await Task.yield() }
        XCTAssertEqual(driver.requests, 0, "The earlier refresh must finish before sleep is requested")
        XCTAssertTrue(model.sleepTimerBlocksControls)
        await gate.finish()
        await refresh.value; await expiry.value
        XCTAssertEqual(driver.requests, 1)
        XCTAssertEqual(service.phase, .accepted)
        service.systemDidWake(); model.stop()
    }
    func testOppositeModesRequireConfirmationAndFailedAwakeAcquisitionRetainsTimer() throws {
        let suite = "SleepModes-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let awake = AwakeFixture(), driver = IntegrationSleepDriver()
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
            keepAwakeTransport: awake, sleepTimerTransport: driver)
        try model.startSleepTimer()
        let id = model.sleepTimer.sessionID
        XCTAssertThrowsError(try model.startKeepAwakeDraft())
        awake.failCreate = true
        XCTAssertThrowsError(try model.startKeepAwakeDraft(replacingSleepTimer: true))
        XCTAssertEqual(model.sleepTimer.sessionID, id)
        XCTAssertTrue(model.sleepTimer.isActive)
        awake.failCreate = false
        try model.startKeepAwakeDraft(replacingSleepTimer: true)
        XCTAssertFalse(model.sleepTimer.isActive)
        XCTAssertTrue(model.keepAwake.hasOwnedAssertion)
        XCTAssertThrowsError(try model.startSleepTimer())
        awake.failRelease = true
        XCTAssertThrowsError(try model.startSleepTimer(replacingAwake: true))
        XCTAssertFalse(model.sleepTimer.isActive)
        XCTAssertTrue(model.keepAwake.hasOwnedAssertion)
        awake.failRelease = false
        try model.startSleepTimer(replacingAwake: true)
        XCTAssertTrue(model.sleepTimer.isActive)
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
        model.stop(); XCTAssertEqual(driver.requests, 0)
    }
}
@MainActor private final class IntegrationSleepDriver: SleepTimerTransport {
    var requests = 0
    func isCurrentConsoleSession() -> Bool { true }
    func requestSleep() { requests += 1 }
}
@MainActor private final class IntegrationSleepClock { var value = 0.0 }
private actor IntegrationSnapshotGate {
    private var continuation: CheckedContinuation<BatterySnapshot, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async -> BatterySnapshot { await withCheckedContinuation { continuation = $0 } }
    func finish() {
        continuation?.resume(returning: .unavailable(reason: "Fixture only")); continuation = nil
    }
}
