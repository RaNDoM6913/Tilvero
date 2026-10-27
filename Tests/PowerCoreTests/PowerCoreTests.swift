import Foundation
import XCTest
@testable import PowerCore

final class TelemetryReadingTests: XCTestCase {
    func testMissingCycleCountIsDifferentFromValidZero() {
        let missing = TelemetryReading<Int>.unavailable(reason: "Not reported")
        let zero = TelemetryReading(value: 0, source: "Fixture", unit: "cycles")
        XCTAssertNil(missing.value)
        XCTAssertEqual(missing.availability, .unavailable)
        XCTAssertEqual(missing.freshness, .unknown)
        XCTAssertEqual(zero.value, 0)
        XCTAssertEqual(zero.availability, .available)
    }

    func testMissingValueCannotAdvertiseAvailableOrFresh() {
        let reading = TelemetryReading<Int>(
            value: nil, source: "Broken fixture", availability: .available, freshness: .fresh
        )
        XCTAssertEqual(reading.availability, .invalid)
        XCTAssertEqual(reading.freshness, .unknown)
        XCTAssertNotNil(reading.reason)
    }

    func testEstimatedAndStaleAreIndependent() {
        let reading = TelemetryReading(
            value: 3600.0, source: "Fixture estimate", unit: "s",
            provenance: .estimated, freshness: .stale
        )
        XCTAssertEqual(reading.provenance, .estimated)
        XCTAssertEqual(reading.freshness, .stale)
        XCTAssertEqual(reading.availability, .available)
    }

    func testUnavailableSnapshotDoesNotFabricateData() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = BatterySnapshot.unavailable(at: date, reason: "Provider offline")
        XCTAssertFalse(snapshot.isDemo)
        XCTAssertNil(snapshot.chargePercent.value)
        XCTAssertNil(snapshot.isCharging.value)
        XCTAssertNil(snapshot.isExternalPower.value)
        XCTAssertNil(snapshot.cycleCount.value)
        XCTAssertNil(snapshot.manufacturer.value)
        XCTAssertNil(snapshot.temperatureCelsius.value)
        XCTAssertNil(snapshot.voltageVolts.value)
        XCTAssertNil(snapshot.currentAmps.value)
        XCTAssertNil(snapshot.timeRemainingSeconds.value)
        XCTAssertEqual(snapshot.collectedAt, date)
        XCTAssertEqual(snapshot.chargePercent.reason, "Provider offline")
    }

    func testDemoIsExplicitAndDoesNotInventManufacturer() {
        let snapshot = BatterySnapshot.demo()
        XCTAssertTrue(snapshot.isDemo)
        XCTAssertEqual(snapshot.chargePercent.source, "Demo fixture")
        XCTAssertNil(snapshot.manufacturer.value)
        XCTAssertNil(snapshot.timeRemainingSeconds.value)
    }
}

final class ChargeLimitEditorTests: XCTestCase {
    private let nativeTargets = [80, 85, 90, 95, 100]

    func testRejectsEmptyDuplicateUnsortedAndOutOfRangeContracts() {
        for targets in [[], [80, 80, 100], [100, 80], [-1, 80], [80, 101]] {
            XCTAssertThrowsError(try ChargeLimitEditor(acceptedTargets: targets)) { error in
                XCTAssertEqual(error as? ChargeLimitEditorError, .invalidTargetSet)
            }
        }
    }

    func testUnsupportedInputIsRejectedInsteadOfRounded() throws {
        var editor = try ChargeLimitEditor(acceptedTargets: nativeTargets, effectiveTarget: 90)
        XCTAssertThrowsError(try editor.setDraftTarget(87)) { error in
            XCTAssertEqual(error as? ChargeLimitEditorError, .unsupportedTarget(87))
        }
        XCTAssertEqual(editor.draftTarget, 90)
        XCTAssertEqual(editor.effectiveTarget, 90)
    }

    func testOnePercentTargetsOnlyWhenExplicitlyDeclared() throws {
        var editor = try ChargeLimitEditor(acceptedTargets: Array(80...100))
        try editor.setDraftTarget(87)
        XCTAssertEqual(try editor.prepareApply(currentChargePercent: 70), .apply(target: 87))
    }

    func testManyDraftEditsDoNotCommitOrChangeEffectiveState() throws {
        var editor = try ChargeLimitEditor(
            acceptedTargets: nativeTargets, committedTarget: 90, effectiveTarget: 90
        )
        for _ in 0..<100 {
            try editor.setDraftTarget(80)
            try editor.setDraftTarget(100)
        }
        XCTAssertEqual(editor.draftTarget, 100)
        XCTAssertEqual(editor.committedTarget, 90)
        XCTAssertEqual(editor.effectiveTarget, 90)
        XCTAssertNil(editor.pendingTarget)
        editor.discardDraft()
        XCTAssertEqual(editor.draftTarget, 90)
    }

    func testPrepareApplyDoesNotOptimisticallyCommit() throws {
        var editor = try ChargeLimitEditor(acceptedTargets: nativeTargets, effectiveTarget: 100)
        try editor.setDraftTarget(80)
        let before = editor
        XCTAssertEqual(try editor.prepareApply(currentChargePercent: 75), .apply(target: 80))
        XCTAssertEqual(editor, before)
    }

    func testAboveGoalDefersForYesAndUnknownDrainSemantics() throws {
        for behavior in [LoweringBehavior.yes, .unknown] {
            var editor = try ChargeLimitEditor(
                acceptedTargets: nativeTargets, committedTarget: 100,
                effectiveTarget: 100, loweringBehavior: behavior
            )
            try editor.setDraftTarget(80)
            let decision = try editor.prepareApply(currentChargePercent: 98)
            XCTAssertEqual(decision, .pending(target: 80, effectiveTarget: 100))
            try editor.recordCommittedIntent(decision)
            XCTAssertEqual(editor.committedTarget, 80)
            XCTAssertEqual(editor.pendingTarget, 80)
            XCTAssertEqual(editor.effectiveTarget, 100)
            XCTAssertEqual(try editor.prepareApply(currentChargePercent: 98), .noChange)
            XCTAssertEqual(try editor.prepareApply(currentChargePercent: 80), .apply(target: 80))
        }
    }

    func testKnownNoDrainCanApplyAboveGoal() throws {
        var editor = try ChargeLimitEditor(
            acceptedTargets: nativeTargets, effectiveTarget: 100, loweringBehavior: .no
        )
        try editor.setDraftTarget(80)
        XCTAssertEqual(try editor.prepareApply(currentChargePercent: 98), .apply(target: 80))
    }

    func testUnknownCurrentChargeDefersLowerTargetButAllowsFullCeiling() throws {
        var editor = try ChargeLimitEditor(acceptedTargets: nativeTargets, effectiveTarget: 100)
        try editor.setDraftTarget(80)
        XCTAssertEqual(try editor.prepareApply(currentChargePercent: nil), .pending(target: 80, effectiveTarget: 100))
        try editor.setDraftTarget(100)
        XCTAssertEqual(try editor.prepareApply(currentChargePercent: nil), .apply(target: 100))
    }

    func testCommittedIntentDoesNotChangeReadbackAndCanBeRetried() throws {
        var editor = try ChargeLimitEditor(acceptedTargets: nativeTargets, effectiveTarget: 100)
        try editor.setDraftTarget(80)
        let decision = try editor.prepareApply(currentChargePercent: 70)
        try editor.recordCommittedIntent(decision)
        XCTAssertEqual(editor.committedTarget, 80)
        XCTAssertEqual(editor.effectiveTarget, 100)
        XCTAssertEqual(try editor.prepareApply(currentChargePercent: 70), .apply(target: 80))
        try editor.recordEffectiveTarget(80)
        XCTAssertEqual(try editor.prepareApply(currentChargePercent: 80), .noChange)
    }

    func testCancelReplacedPendingTargetDoesNotReviveOldPendingIntent() throws {
        var editor = try ChargeLimitEditor(
            acceptedTargets: nativeTargets, committedTarget: 100, effectiveTarget: 100
        )
        try editor.setDraftTarget(80)
        try editor.recordCommittedIntent(editor.prepareApply(currentChargePercent: 98))
        try editor.setDraftTarget(85)
        try editor.recordCommittedIntent(editor.prepareApply(currentChargePercent: 98))
        editor.cancelPendingTarget()
        XCTAssertNil(editor.pendingTarget)
        XCTAssertEqual(editor.committedTarget, 100)
        XCTAssertEqual(editor.effectiveTarget, 100)
        XCTAssertEqual(editor.draftTarget, 100)
    }

    func testPersistentHundredPercentRemainsIntentUntilExplicitlyChanged() throws {
        var editor = try ChargeLimitEditor(
            acceptedTargets: nativeTargets, committedTarget: 80, effectiveTarget: 80
        )
        try editor.setDraftTarget(100)
        try editor.recordCommittedIntent(editor.prepareApply(currentChargePercent: 98))
        try editor.recordEffectiveTarget(100)
        editor.discardDraft()
        XCTAssertEqual(editor.committedTarget, 100)
        XCTAssertEqual(editor.draftTarget, 100)
        XCTAssertNil(editor.pendingTarget)
        XCTAssertEqual(try editor.prepareApply(currentChargePercent: 100), .noChange)
    }

    func testExternalReadbackDoesNotOverwriteDraftOrAcceptStaleDecision() throws {
        var editor = try ChargeLimitEditor(acceptedTargets: nativeTargets, effectiveTarget: 100)
        try editor.setDraftTarget(80)
        let decision = try editor.prepareApply(currentChargePercent: 98)
        try editor.recordEffectiveTarget(90)
        XCTAssertEqual(editor.draftTarget, 80)
        XCTAssertThrowsError(try editor.recordCommittedIntent(decision)) { error in
            XCTAssertEqual(error as? ChargeLimitEditorError, .staleDecision)
        }
    }

    func testReportedSettingOutsideWritableSetIsRetainedHonestly() throws {
        let editor = try ChargeLimitEditor(acceptedTargets: nativeTargets, effectiveTarget: 75)
        XCTAssertEqual(editor.effectiveTarget, 75)
        XCTAssertEqual(editor.draftTarget, 80)
        XCTAssertNil(editor.committedTarget)
    }

    func testInvalidCurrentPercentageCannotDriveDecision() throws {
        let editor = try ChargeLimitEditor(acceptedTargets: nativeTargets)
        XCTAssertThrowsError(try editor.prepareApply(currentChargePercent: 101)) { error in
            XCTAssertEqual(error as? ChargeLimitEditorError, .invalidPercentage(101))
        }
    }
}
