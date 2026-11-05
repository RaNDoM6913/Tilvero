import XCTest
import Foundation
@testable import PowerCore
@testable import PowerTelemetry

/// Pins the producer/consumer contract: readings normalized from IOPowerSources must be usable
/// as sleep endpoints even though the provider (correctly) reports unknown source freshness.
final class SleepEndpointNormalizationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let run = UUID()
    private let provider = MacBatteryProvider(identitySalt: "salt")

    private func stamp(_ seconds: Double) -> SleepObservationStamp {
        .init(wallDate: t0.addingTimeInterval(seconds), continuousSeconds: 100 + seconds, runID: run)
    }
    private func snapshot(percent: Int, at seconds: Double, state: String = "Battery Power",
                          charging: Bool = false, serial: String = "S1") -> BatterySnapshot {
        provider.normalize(powerSource: ["Current Capacity": percent, "Max Capacity": 100,
                                         "Is Charging": charging, "Power Source State": state],
                           registry: ["Serial": serial], at: t0.addingTimeInterval(seconds), uptime: 1000 + seconds)
    }

    func testNormalizedIOPSReadingsCompleteSleepEndpoints() throws {
        let first = snapshot(percent: 80, at: 0)
        let row = try XCTUnwrap(first.catalog.first { $0.id == "011" })
        XCTAssertEqual(row.freshness, .unknown, "The provider must keep reporting unknown source freshness.")
        XCTAssertNil(row.sourceSampleAt)
        let before = try XCTUnwrap(SleepBatteryEndpoint(snapshot: first, stamp: stamp(2)))
        XCTAssertNil(before.sourceSampleAt, "An app-observed endpoint never invents a hardware sample time.")
        XCTAssertEqual(before.source, "IOPowerSources")

        var tracker = SleepSessionTracker()
        let pending = try XCTUnwrap(tracker.accept(.willSleep(stamp: stamp(10), latestEndpoint: before)).first)
        XCTAssertEqual(pending.before?.chargePercent, 80)
        XCTAssertEqual(tracker.accept(.didWake(stamp: stamp(600), epoch: 2)).first?.phase, .awaitingReading)
        let after = try XCTUnwrap(SleepBatteryEndpoint(snapshot: snapshot(percent: 77, at: 601), stamp: stamp(601)))
        let closed = try XCTUnwrap(tracker.accept(.freshReading(endpoint: after, epoch: 2)).first)
        XCTAssertEqual(closed.phase, .closed)
        XCTAssertTrue(closed.issues.isEmpty)
        XCTAssertEqual(closed.chargeChangePercentagePoints, 3)
        XCTAssertEqual(closed.powerEvidence, .batteryAtBothObservations)
        XCTAssertEqual(closed.before?.isCharging, false)
        XCTAssertNil(closed.before?.sourceSampleAt)
    }

    func testNormalizedACReadingsReportExternalPower() throws {
        let before = try XCTUnwrap(SleepBatteryEndpoint(snapshot: snapshot(percent: 80, at: 0, state: "AC Power", charging: true), stamp: stamp(1)))
        let after = try XCTUnwrap(SleepBatteryEndpoint(snapshot: snapshot(percent: 85, at: 600, state: "AC Power", charging: true), stamp: stamp(600)))
        var tracker = SleepSessionTracker()
        _ = tracker.accept(.willSleep(stamp: stamp(10), latestEndpoint: before))
        _ = tracker.accept(.didWake(stamp: stamp(599), epoch: 1))
        let closed = try XCTUnwrap(tracker.accept(.freshReading(endpoint: after, epoch: 1)).first)
        XCTAssertEqual(closed.powerEvidence, .externalPowerObserved)
        XCTAssertEqual(closed.before?.isCharging, true)
    }

    func testMalformedPowerStateLeavesPowerEvidenceUnavailable() throws {
        let raw = snapshot(percent: 80, at: 0, state: "unexpected")
        let endpoint = try XCTUnwrap(SleepBatteryEndpoint(snapshot: raw, stamp: stamp(1)))
        XCTAssertNil(endpoint.isExternalPower)
        let record = SleepSessionRecord(sleepBoundary: stamp(10), before: endpoint, after: endpoint, phase: .closed)
        XCTAssertEqual(record.powerEvidence, .unavailable)
    }

    func testNormalizedReadingRejectedOutsideWindowRetainedOrWrongEpoch() throws {
        let first = snapshot(percent: 80, at: 0)
        XCTAssertNotNil(SleepBatteryEndpoint(snapshot: first, stamp: stamp(60)))
        XCTAssertNil(SleepBatteryEndpoint(snapshot: first, stamp: stamp(61)), "Collected more than 60 s ago.")
        XCTAssertNil(SleepBatteryEndpoint(snapshot: first, stamp: stamp(-2)), "Collected in the future.")
        let missing = provider.normalize(powerSource: nil, registry: ["Serial": "S1"], at: t0.addingTimeInterval(10), uptime: 1010)
            .retainingPreviousReadings(first)
        XCTAssertNil(SleepBatteryEndpoint(snapshot: missing, stamp: stamp(10)), "A retained display value is not a new observation.")

        let before = try XCTUnwrap(SleepBatteryEndpoint(snapshot: first, stamp: stamp(1)))
        var tracker = SleepSessionTracker()
        _ = tracker.accept(.willSleep(stamp: stamp(10), latestEndpoint: before))
        _ = tracker.accept(.didWake(stamp: stamp(600), epoch: 2))
        let after = try XCTUnwrap(SleepBatteryEndpoint(snapshot: snapshot(percent: 77, at: 601), stamp: stamp(601)))
        XCTAssertTrue(tracker.accept(.freshReading(endpoint: after, epoch: 1)).isEmpty, "A pre-wake epoch cannot close the record.")
        let expired = try XCTUnwrap(tracker.accept(.expire(stamp: stamp(661))).first)
        XCTAssertEqual(expired.phase, .incomplete)
        XCTAssertTrue(expired.issues.contains(.postReadingMissing))

        var other = SleepSessionTracker()
        _ = other.accept(.willSleep(stamp: stamp(10), latestEndpoint: before))
        _ = other.accept(.didWake(stamp: stamp(600), epoch: 3))
        let swapped = try XCTUnwrap(SleepBatteryEndpoint(snapshot: snapshot(percent: 77, at: 601, serial: "S2"), stamp: stamp(601)))
        let changed = try XCTUnwrap(other.accept(.freshReading(endpoint: swapped, epoch: 3)).first)
        XCTAssertTrue(changed.issues.contains(.batteryIdentityChanged))
        XCTAssertNil(changed.chargeChangePercentagePoints)
    }
}
