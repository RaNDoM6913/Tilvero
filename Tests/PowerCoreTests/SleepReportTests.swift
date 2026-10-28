import XCTest
@testable import PowerCore

final class SleepReportTests: XCTestCase {
    private let run = UUID()
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func stamp(_ seconds: Double, wall: Double? = nil, run: UUID? = nil) -> SleepObservationStamp {
        .init(wallDate: date.addingTimeInterval(wall ?? seconds), continuousSeconds: 100 + seconds, runID: run ?? self.run)
    }
    private func endpoint(_ seconds: Double, charge: Int = 80, identity: String? = "salted", external: Bool? = false,
                          age: Double = 0, freshness: TelemetryFreshness = .fresh, demo: Bool = false) -> SleepBatteryEndpoint? {
        let at = date.addingTimeInterval(seconds - age)
        return SleepBatteryEndpoint(snapshot: BatterySnapshot(chargePercent: .init(value: charge, source: "IOPowerSources", collectedAt: at, freshness: freshness),
            isExternalPower: .init(value: external, source: "IOPowerSources", collectedAt: at), collectedAt: at,
            isDemo: demo, batteryIdentityToken: identity), stamp: stamp(seconds))
    }
    func testExplicitlyOldSourceSampleCannotBecomeFreshEndpoint() {
        let raw = BatterySnapshot(chargePercent: .init(value: 80, source: "IOPowerSources", collectedAt: date,
            sourceSampleAt: date.addingTimeInterval(-600), freshness: .fresh), collectedAt: date, batteryIdentityToken: "salted")
        XCTAssertNil(SleepBatteryEndpoint(snapshot: raw, stamp: stamp(0)))
    }
        func testFirstFreshReadingClosesSameRecordAndPreservesOriginalMeasurementTime() throws {
        var tracker = SleepSessionTracker()
        let pending = try XCTUnwrap(tracker.accept(.willSleep(stamp: stamp(10), latestEndpoint: endpoint(8))).first)
        XCTAssertEqual(pending.phase, .awaitingWake)
        XCTAssertTrue(tracker.accept(.willSleep(stamp: stamp(11), latestEndpoint: endpoint(11))).isEmpty)
        XCTAssertEqual(tracker.accept(.didWake(stamp: stamp(600), epoch: 2)).first?.phase, .awaitingReading)
        XCTAssertTrue(tracker.accept(.didWake(stamp: stamp(601), epoch: 3)).isEmpty)
        let closed = try XCTUnwrap(tracker.accept(.freshReading(endpoint: try XCTUnwrap(endpoint(603, charge: 77, age: 1)), epoch: 2)).first)
        XCTAssertEqual(closed.id, pending.id)
        XCTAssertEqual(closed.phase, .closed)
        XCTAssertEqual(closed.chargeChangePercentagePoints, 3)
        XCTAssertEqual(closed.before?.collectedAt, date.addingTimeInterval(8))
        XCTAssertEqual(closed.after?.collectedAt, date.addingTimeInterval(602))
        XCTAssertEqual(closed.measurementIntervalSeconds, 594)
        XCTAssertEqual(closed.notificationIntervalSeconds, 590)
        XCTAssertEqual(closed.powerEvidence, .batteryAtBothObservations)
        XCTAssertNil(tracker.pending)
    }
    func testPreWakeEpochAndReadingCannotCompleteSession() throws {
        var tracker = SleepSessionTracker()
        _ = tracker.accept(.willSleep(stamp: stamp(10), latestEndpoint: endpoint(9)))
        _ = tracker.accept(.didWake(stamp: stamp(600), epoch: 8))
        XCTAssertTrue(tracker.accept(.freshReading(endpoint: try XCTUnwrap(endpoint(601)), epoch: 7)).isEmpty)
        XCTAssertTrue(tracker.accept(.freshReading(endpoint: try XCTUnwrap(endpoint(599)), epoch: 8)).isEmpty)
        XCTAssertEqual(tracker.pending?.phase, .awaitingReading)
        let expired = tracker.accept(.expire(stamp: stamp(661))).first
        XCTAssertEqual(expired?.phase, .incomplete)
        XCTAssertTrue(expired?.issues.contains(.postReadingMissing) == true)
    }
    func testStaleDemoOutOfRangeAndFutureProviderReadingsAreRejected() {
        XCTAssertNil(endpoint(1, freshness: .stale))
        XCTAssertNil(endpoint(1, freshness: .unknown))
        XCTAssertNil(endpoint(1, demo: true))
        XCTAssertNil(endpoint(1, charge: 101))
        XCTAssertNil(endpoint(1, age: -10))
        var tracker = SleepSessionTracker()
        let pending = tracker.accept(.willSleep(stamp: stamp(100), latestEndpoint: endpoint(1))).first
        XCTAssertNil(pending?.before)
        XCTAssertTrue(pending?.issues.contains(.preReadingMissing) == true)
    }
    func testSupersedingSleepReturnsOldIncompleteAndNewPending() {
        var tracker = SleepSessionTracker()
        _ = tracker.accept(.willSleep(stamp: stamp(1), latestEndpoint: endpoint(1)))
        _ = tracker.accept(.didWake(stamp: stamp(10), epoch: 1))
        let changes = tracker.accept(.willSleep(stamp: stamp(20), latestEndpoint: endpoint(20)))
        XCTAssertEqual(changes.map(\.phase), [.incomplete, .awaitingWake])
        XCTAssertTrue(changes[0].issues.contains(.supersededBySleep))
        XCTAssertNotEqual(changes[0].id, changes[1].id)
    }
    func testOrphanWakeRestartAndDisableNeverInventSleepStart() {
        var tracker = SleepSessionTracker()
        let orphan = tracker.accept(.didWake(stamp: stamp(10), epoch: 1)).first
        XCTAssertEqual(orphan?.phase, .incomplete)
        XCTAssertNil(orphan?.sleepBoundary)
        XCTAssertTrue(orphan?.issues.contains(.sleepBoundaryMissing) == true)
        let pending = tracker.accept(.willSleep(stamp: stamp(20), latestEndpoint: endpoint(20))).first!
        let recovered = pending.interrupted(reason: .applicationRestarted, at: stamp(30, run: UUID()))
        XCTAssertEqual(recovered.id, pending.id)
        XCTAssertEqual(recovered.phase, .incomplete)
        XCTAssertTrue(recovered.issues.contains(.applicationRestarted))
        XCTAssertEqual(tracker.accept(.interrupted(reason: .historyDisabled, stamp: stamp(30))).first?.phase, .incomplete)
        XCTAssertNil(tracker.pending)
    }
    func testIdentityAndPowerEvidenceDoNotInventContinuity() throws {
        for (identity, external, expectedDelta, expectedPower) in [
            ("other" as String?, false as Bool?, nil as Double?, SleepPowerEvidence.batteryAtBothObservations),
            (nil, false, nil, .batteryAtBothObservations),
            ("salted", true, -2, .externalPowerObserved),
            ("salted", nil, -2, .unavailable)
        ] {
            var tracker = SleepSessionTracker()
            _ = tracker.accept(.willSleep(stamp: stamp(1), latestEndpoint: endpoint(1)))
            _ = tracker.accept(.didWake(stamp: stamp(600), epoch: 1))
            let record = try XCTUnwrap(tracker.accept(.freshReading(endpoint: try XCTUnwrap(endpoint(601, charge: 82, identity: identity, external: external)), epoch: 1)).first)
            XCTAssertEqual(record.chargeChangePercentagePoints, expectedDelta)
            XCTAssertEqual(record.powerEvidence, expectedPower)
        }
    }
    func testClockRollbackKeepsQualifiedArithmeticButInvalidatesDuration() throws {
        var tracker = SleepSessionTracker()
        _ = tracker.accept(.willSleep(stamp: stamp(10), latestEndpoint: endpoint(10)))
        _ = tracker.accept(.didWake(stamp: stamp(610, wall: -100), epoch: 1))
        // Endpoint clock stamps independently retain valid arithmetic despite wall chronology change.
        let raw = BatterySnapshot(chargePercent: .init(value: 78, source: "IOPowerSources", collectedAt: date.addingTimeInterval(-99)),
                                  collectedAt: date.addingTimeInterval(-99), batteryIdentityToken: "salted")
        let endpoint = try XCTUnwrap(SleepBatteryEndpoint(snapshot: raw, stamp: stamp(611, wall: -99)))
        let record = try XCTUnwrap(tracker.accept(.freshReading(endpoint: endpoint, epoch: 1)).first)
        XCTAssertEqual(record.chargeChangePercentagePoints, 2)
        XCTAssertTrue(record.issues.contains(.clockChanged))
        XCTAssertNil(record.notificationIntervalSeconds)
        XCTAssertNil(record.measurementIntervalSeconds)
    }
    func testRetainedFailedCollectionAndCrossRunReadAreNotEndpoints() throws {
        let valid = BatterySnapshot(chargePercent: .init(value: 81, source: "IOPowerSources", collectedAt: date),
                                    collectedAt: date, monotonicTime: 100, batteryIdentityToken: "salted")
        let retained = BatterySnapshot(collectedAt: date.addingTimeInterval(1), monotonicTime: 101).retainingPreviousReadings(valid)
        XCTAssertNil(SleepBatteryEndpoint(snapshot: retained, stamp: stamp(1)))
        var tracker = SleepSessionTracker()
        _ = tracker.accept(.willSleep(stamp: stamp(1), latestEndpoint: endpoint(1)))
        _ = tracker.accept(.didWake(stamp: stamp(600), epoch: 3))
        let otherRun = try XCTUnwrap(SleepBatteryEndpoint(snapshot: valid, stamp: stamp(1, run: UUID())))
        XCTAssertTrue(tracker.accept(.freshReading(endpoint: otherRun, epoch: 3)).isEmpty)
        let expired = tracker.accept(.freshReading(endpoint: try XCTUnwrap(endpoint(661)), epoch: 3)).first
        XCTAssertEqual(expired?.phase, .incomplete)
        XCTAssertNil(expired?.after)
    }
}
