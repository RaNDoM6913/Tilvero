import XCTest
import KeyboardBackends
@testable import TilveroApp

@MainActor final class KeyboardBacklightServiceTests: XCTestCase {
    func testConstructionAndRefreshNeverWriteAndMissingObservationIsUnknown() async throws {
        let driver = KeyboardFixture(), store = KeyboardMemory()
        let service = KeyboardBacklightService(driver: driver, storage: store)
        XCTAssertNil(service.isEnabled)
        XCTAssertNil(service.brightness)
        XCTAssertEqual(service.availability, .unknown)
        XCTAssertEqual(driver.readCount, 0)
        await service.refresh()
        XCTAssertEqual(service.brightness, 0.35)
        XCTAssertEqual(service.isEnabled, true)
        XCTAssertTrue(driver.writes.isEmpty)
        XCTAssertEqual(store.lastNonzeroBrightness, 0.35)
    }
    func testExplicitOffThenOnRestoresExactPriorNonzeroAndLeavesAutomaticPolicy() async throws {
        let driver = KeyboardFixture(), store = KeyboardMemory()
        let service = KeyboardBacklightService(driver: driver, storage: store)
        await service.setEnabled(false)
        XCTAssertEqual(driver.writes, [0])
        XCTAssertEqual(service.isEnabled, false)
        XCTAssertEqual(service.lastAppliedBrightness, 0)
        XCTAssertEqual(store.lastNonzeroBrightness, 0.35)
        await service.setEnabled(true)
        XCTAssertEqual(driver.writes, [0, 0.35])
        XCTAssertEqual(service.isEnabled, true)
        XCTAssertEqual(service.observation?.automaticBrightness, true)
        XCTAssertNil(service.error)
    }
    func testOnWithoutRememberedNonzeroUsesExplicitRequestedQuarterBrightness() async throws {
        let driver = KeyboardFixture(brightness: 0), service = KeyboardBacklightService(driver: driver, storage: KeyboardMemory())
        await service.setEnabled(true)
        XCTAssertNil(service.error)
        XCTAssertEqual(driver.writes, [0.25])
        XCTAssertEqual(service.requestedBrightness, 0.25)
        XCTAssertEqual(service.isEnabled, true)
    }
    func testAlreadyMatchingStateDoesNotWrite() async throws {
        let driver = KeyboardFixture(), service = KeyboardBacklightService(driver: driver, storage: KeyboardMemory())
        await service.setEnabled(true)
        XCTAssertTrue(driver.writes.isEmpty)
        XCTAssertNil(service.lastAppliedBrightness)
        XCTAssertNil(service.error)
    }
    func testUnconfirmedWriteRetainsObservedRealityAndDoesNotClaimApplied() async throws {
        let driver = KeyboardFixture(), service = KeyboardBacklightService(driver: driver, storage: KeyboardMemory())
        driver.ignoreWrite = true
        await service.setEnabled(false)
        XCTAssertEqual(service.error, .unconfirmedWrite)
        XCTAssertEqual(service.isEnabled, true)
        XCTAssertNil(service.lastAppliedBrightness)
        XCTAssertEqual(service.requestedBrightness, 0)
    }
    func testFailureAfterWriteClearsReadbackAndRetainsRestorePreference() async throws {
        let driver = KeyboardFixture(), store = KeyboardMemory()
        let service = KeyboardBacklightService(driver: driver, storage: store)
        driver.failReadAfterWrite = true
        await service.setEnabled(false)
        XCTAssertEqual(service.error, .unconfirmedWrite)
        XCTAssertNil(service.isEnabled)
        XCTAssertNil(service.brightness)
        XCTAssertEqual(store.lastNonzeroBrightness, 0.35)
        XCTAssertNil(service.lastAppliedBrightness)
    }
    func testReadErrorClearsStaleObservationAndUnsupportedNeverWrites() async throws {
        let driver = KeyboardFixture(), service = KeyboardBacklightService(driver: driver, storage: KeyboardMemory())
        await service.refresh()
        driver.readError = .unsupported
        await service.setEnabled(false)
        XCTAssertEqual(service.availability, .unsupported)
        XCTAssertEqual(service.error, .unsupported)
        XCTAssertNil(service.brightness)
        XCTAssertTrue(driver.writes.isEmpty)
    }
    func testInvalidRememberedPreferenceCannotReachWriter() async throws {
        for value in [Double.nan, .infinity, -1, 0, 1.1] {
            let driver = KeyboardFixture(brightness: 0), store = KeyboardMemory(value)
            let service = KeyboardBacklightService(driver: driver, storage: store)
            await service.setEnabled(true)
            XCTAssertNil(service.error)
            XCTAssertEqual(driver.writes, [0.25])
        }
    }
    func testSuppressedOrDimmedPositiveSettingIsNotClaimedAsIlluminated() async throws {
        let driver = KeyboardFixture(), service = KeyboardBacklightService(driver: driver, storage: KeyboardMemory())
        driver.suppressed = true
        await service.refresh()
        XCTAssertEqual(service.brightness, 0.35)
        XCTAssertNil(service.isEnabled)
        XCTAssertTrue(driver.writes.isEmpty)
        driver.suppressed = false; driver.dimmed = true
        await service.refresh()
        XCTAssertNil(service.isEnabled)
    }
    func testSimulationCannotReadWriteOrAlterRememberedPreference() async throws {
        let driver = KeyboardFixture(), store = KeyboardMemory(0.7)
        let service = KeyboardBacklightService(driver: driver, storage: store, allowed: false)
        await service.refresh(); await service.setEnabled(false)
        XCTAssertEqual(service.error, .disabledInSimulation)
        XCTAssertNil(service.brightness)
        XCTAssertEqual(driver.readCount, 0)
        XCTAssertTrue(driver.writes.isEmpty)
        XCTAssertEqual(store.lastNonzeroBrightness, 0.7)
    }
    func testRejectedSetterStillReacquiresActualState() async throws {
        let driver = KeyboardFixture(), service = KeyboardBacklightService(driver: driver, storage: KeyboardMemory())
        driver.rejectAfterWrite = true
        await service.setEnabled(false)
        XCTAssertEqual(service.error, .writeRejected)
        XCTAssertEqual(service.isEnabled, false)
        XCTAssertEqual(driver.readCount, 2)
        XCTAssertNil(service.lastAppliedBrightness)
    }
    func testConcurrentIntentCannotInterleaveWithPendingOperation() async throws {
        let driver = KeyboardFixture(), service = KeyboardBacklightService(driver: driver, storage: KeyboardMemory())
        driver.pauseNextRead = true
        let task = Task { await service.setEnabled(false) }
        while driver.pendingRead == nil { await Task.yield() }
        XCTAssertTrue(service.isBusy)
        await service.setEnabled(true)
        await service.refresh()
        XCTAssertTrue(driver.writes.isEmpty)
        driver.pendingRead?.resume(); driver.pendingRead = nil
        await task.value
        XCTAssertEqual(driver.writes, [0])
        XCTAssertFalse(service.isBusy)
    }
    func testAutomaticPolicyChangeIsReportedWithoutRestoringGlobalPolicy() async throws {
        let driver = KeyboardFixture(), service = KeyboardBacklightService(driver: driver, storage: KeyboardMemory())
        driver.flipAutomaticOnWrite = true
        await service.setEnabled(false)
        XCTAssertEqual(service.error, .automaticPolicyChanged)
        XCTAssertEqual(service.observation?.automaticBrightness, false)
        XCTAssertNil(service.lastAppliedBrightness)
        XCTAssertEqual(driver.writes, [0])
    }
}

@MainActor private final class KeyboardMemory: KeyboardBacklightPreferenceStorage {
    var lastNonzeroBrightness: Double?
    init(_ value: Double? = nil) { lastNonzeroBrightness = value }
}
@MainActor private final class KeyboardFixture: KeyboardBacklightTransport {
    var brightness: Double
    var automatic = true, suppressed = false, dimmed = false
    var readCount = 0, writes: [Double] = []
    var readError: KeyboardBacklightError?
    var ignoreWrite = false, failReadAfterWrite = false, flipAutomaticOnWrite = false, rejectAfterWrite = false
    var pauseNextRead = false
    var pendingRead: CheckedContinuation<Void, Never>?
    init(brightness: Double = 0.35) { self.brightness = brightness }
    func read() async throws -> KeyboardBacklightObservation {
        readCount += 1
        if pauseNextRead {
            pauseNextRead = false
            await withCheckedContinuation { pendingRead = $0 }
        }
        if let readError { throw readError }
        if failReadAfterWrite && !writes.isEmpty { throw KeyboardBacklightError.unavailable }
        return try .init(keyboardID: 7, brightness: brightness, automaticBrightness: automatic,
                         suppressed: suppressed, dimmed: dimmed, observedAt: Date())
    }
    func setBrightness(_ value: Double, keyboardID: UInt64) async throws {
        writes.append(value)
        if !ignoreWrite { brightness = value }
        if flipAutomaticOnWrite { automatic.toggle() }
        if rejectAfterWrite { throw KeyboardBacklightError.writeRejected }
    }
}
