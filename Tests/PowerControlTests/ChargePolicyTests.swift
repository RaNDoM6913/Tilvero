import XCTest
@testable import PowerCore

final class ChargePolicyTests: XCTestCase {
    func testCancellationDuringFullChargeWriteReconcilesThePriorPolicy() throws {
        var engine = try ChargePolicyEngine(acceptedTargets: [80, 100], loweringBehavior: .yes)
        let initial = try engine.submit(.ceiling(80), observation: .init(percent: 70, externalPower: true))[0]
        try engine.acknowledge(initial, effectiveTarget: 80)
        let full = try engine.submit(.fullOnce, observation: .init(percent: 70, externalPower: true))[0]
        let restored = engine.cancelOneShot(observation: .init(percent: 70, externalPower: true))
        XCTAssertEqual(restored.count, 1)
        XCTAssertThrowsError(try engine.acknowledge(full, effectiveTarget: 100))
        try engine.acknowledge(restored[0], effectiveTarget: 80)
        XCTAssertEqual(engine.state.requested, .ceiling(80)); XCTAssertEqual(engine.state.appliedTarget, 80)
    }
    func testReturnToCachedAppliedTargetStillReconcilesSupersededWrite() throws {
        var engine = try ChargePolicyEngine(acceptedTargets: [80, 90, 100], loweringBehavior: .yes)
        let initial = try engine.submit(.ceiling(80), observation: .init(percent: 70, externalPower: true))[0]
        try engine.acknowledge(initial, effectiveTarget: 80)
        let obsolete = try engine.submit(.ceiling(90), observation: .init(percent: 70, externalPower: true))[0]
        let newest = try engine.submit(.ceiling(80), observation: .init(percent: 70, externalPower: true))
        XCTAssertEqual(newest.count, 1, "An older write may still change hardware despite cached 80 readback")
        XCTAssertThrowsError(try engine.acknowledge(obsolete, effectiveTarget: 90))
        XCTAssertTrue(engine.observe(.init(percent: 70, externalPower: true, effectiveTarget: 90)).isEmpty)
        try engine.acknowledge(newest[0], effectiveTarget: 80)
        XCTAssertEqual(engine.state.requested, .ceiling(80)); XCTAssertEqual(engine.state.appliedTarget, 80)
        XCTAssertEqual(engine.state.phase, .managed)
    }

    func testLateSupersededRaiseHonorsPendingLowerSemantics() throws {
        var engine = try ChargePolicyEngine(acceptedTargets: [80, 90, 100], loweringBehavior: .yes)
        let initial = try engine.submit(.ceiling(80), observation: .init(percent: 70, externalPower: true))[0]
        try engine.acknowledge(initial, effectiveTarget: 80)
        let obsolete = try engine.submit(.ceiling(100), observation: .init(percent: 70, externalPower: true))[0]
        XCTAssertTrue(try engine.submit(.ceiling(80), observation: .init(percent: 98, externalPower: true)).isEmpty)
        XCTAssertThrowsError(try engine.acknowledge(obsolete, effectiveTarget: 100))
        XCTAssertTrue(engine.observe(.init(percent: 98, externalPower: true, effectiveTarget: 100)).isEmpty)
        XCTAssertEqual(engine.state.phase, .pendingLowerLimit); XCTAssertEqual(engine.state.appliedTarget, 100)
        XCTAssertEqual(engine.state.pendingTarget, 80)
        XCTAssertEqual(engine.observe(.init(percent: 79, externalPower: false, effectiveTarget: 100)).count, 1)
    }

    func testReplacingPendingThenCancellingReturnsOriginalPrePendingIntent() throws {
        var engine = try ChargePolicyEngine(acceptedTargets: [80, 90, 100], loweringBehavior: .yes)
        let initial = try engine.submit(.ceiling(100), observation: .init(percent: 98, externalPower: true))[0]
        try engine.acknowledge(initial, effectiveTarget: 100)
        XCTAssertTrue(try engine.submit(.ceiling(80), observation: .init(percent: 98, externalPower: true)).isEmpty)
        XCTAssertTrue(try engine.submit(.ceiling(90), observation: .init(percent: 98, externalPower: true)).isEmpty)
        XCTAssertTrue(try engine.cancelPending().isEmpty)
        XCTAssertEqual(engine.state.requested, .ceiling(100)); XCTAssertNil(engine.state.pendingTarget)
        XCTAssertEqual(engine.state.phase, .managed)
        XCTAssertTrue(engine.observe(.init(percent: 70, externalPower: false, effectiveTarget: 100)).isEmpty)
    }
    func testOneShotRequiresIndependentFullChargeEvidenceBeforeCompletion() throws {
        var engine = try ChargePolicyEngine(acceptedTargets: [80, 100], loweringBehavior: .yes)
        let initial = try engine.submit(.ceiling(80), observation: .init(percent: 70, externalPower: true))
        try engine.acknowledge(initial[0], effectiveTarget: 80)
        let full = try engine.submit(.fullOnce, observation: .init(percent: 75, externalPower: true))
        try engine.acknowledge(full[0], effectiveTarget: 100)
        XCTAssertTrue(engine.observe(.init(percent: 100, externalPower: true, isCharging: false)).isEmpty)
        XCTAssertEqual(engine.state.requested, .fullOnce)
        XCTAssertTrue(engine.observe(.init(percent: 100, externalPower: true, isCharging: false, fullyCharged: true)).isEmpty)
        XCTAssertEqual(engine.state.requested, .ceiling(80))
        XCTAssertEqual(engine.state.pendingTarget, 80)
        XCTAssertEqual(engine.state.appliedTarget, 100)
    }
    func testCorruptPersistedPolicyIsRejectedAndPersistent100IsNotOneShot() throws {
        var engine = try ChargePolicyEngine(acceptedTargets: [80, 100], loweringBehavior: .yes)
        let effects = try engine.submit(.ceiling(100), observation: .init(percent: 70, externalPower: true))
        try engine.acknowledge(effects[0], effectiveTarget: 100)
        XCTAssertTrue(engine.observe(.init(percent: 100, externalPower: true, effectiveTarget: 100, isCharging: false)).isEmpty)
        XCTAssertEqual(engine.state.requested, .ceiling(100))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(engine)) as? [String: Any])
        json["acceptedTargets"] = [100, 80]
        XCTAssertThrowsError(try JSONDecoder().decode(ChargePolicyEngine.self, from: JSONSerialization.data(withJSONObject: json)))
        json["acceptedTargets"] = [80, 100]; json["version"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(ChargePolicyEngine.self, from: JSONSerialization.data(withJSONObject: json)))
    }
    func testLowerLimitWaitsForFreshNaturalDischargeAndCancelledTargetNeverRevives() throws {
        var engine = try ChargePolicyEngine(acceptedTargets: Array(80...100), loweringBehavior: .yes)
        XCTAssertTrue(try engine.submit(.ceiling(80), observation: .init(percent: 98, externalPower: true)).isEmpty)
        XCTAssertEqual(engine.state.pendingTarget, 80)
        XCTAssertNil(engine.state.appliedTarget)
        XCTAssertTrue(engine.observe(.init(percent: 70, externalPower: false, fresh: false)).isEmpty)
        _ = try engine.cancelPending()
        XCTAssertTrue(engine.observe(.init(percent: 70, externalPower: false)).isEmpty)
        XCTAssertNil(engine.state.requested)
    }

    func testOneShotUnplugThenEarlyReconnectPreservesEffective100AndPending80() throws {
        var engine = try ChargePolicyEngine(acceptedTargets: Array(80...100), loweringBehavior: .yes)
        let first = try engine.submit(.ceiling(80), observation: .init(percent: 75, externalPower: true))
        try engine.acknowledge(first[0], effectiveTarget: 80)
        let full = try engine.submit(.fullOnce, observation: .init(percent: 75, externalPower: true))
        try engine.acknowledge(full[0], effectiveTarget: 100)
        XCTAssertTrue(engine.observe(.init(percent: 95, externalPower: false, effectiveTarget: 100)).isEmpty)
        XCTAssertEqual(engine.state.requested, .ceiling(80))
        XCTAssertEqual(engine.state.pendingTarget, 80)
        XCTAssertEqual(engine.state.appliedTarget, 100)
        XCTAssertTrue(engine.observe(.init(percent: 94, externalPower: true, effectiveTarget: 100)).isEmpty)
        let apply = engine.observe(.init(percent: 80, externalPower: false, effectiveTarget: 100))
        XCTAssertEqual(apply.count, 1)
        try engine.acknowledge(apply[0], effectiveTarget: 80)
        XCTAssertEqual(engine.state.phase, .managed)
    }

    func testOneShotCompletionAndRestartReturnThroughPendingPolicy() throws {
        var engine = try ChargePolicyEngine(acceptedTargets: [80, 90, 100], loweringBehavior: .unknown)
        let initial = try engine.submit(.ceiling(80), observation: .init(percent: 70, externalPower: true))
        try engine.acknowledge(initial[0], effectiveTarget: 80)
        let full = try engine.submit(.fullOnce, observation: .init(percent: 80, externalPower: true))
        try engine.acknowledge(full[0], effectiveTarget: 100)
        let encoded = try JSONEncoder().encode(engine)
        var recovered = try JSONDecoder().decode(ChargePolicyEngine.self, from: encoded)
        XCTAssertTrue(recovered.restart(observation: .init(percent: 96, externalPower: true, effectiveTarget: 100)).isEmpty)
        XCTAssertEqual(recovered.state.pendingTarget, 80)
        XCTAssertEqual(recovered.state.appliedTarget, 100)
    }

    func testOldReadbackCannotOverwriteNewIntentAndExternalChangesYield() throws {
        var engine = try ChargePolicyEngine(acceptedTargets: [80, 90, 100], loweringBehavior: .no)
        let old = try engine.submit(.ceiling(80), observation: .init(percent: 75, externalPower: true))[0]
        let next = try engine.submit(.ceiling(90), observation: .init(percent: 75, externalPower: true))[0]
        XCTAssertThrowsError(try engine.acknowledge(old, effectiveTarget: 80))
        try engine.acknowledge(next, effectiveTarget: 90)
        XCTAssertTrue(engine.observe(.init(percent: 75, externalPower: true, effectiveTarget: 100)).isEmpty)
        XCTAssertEqual(engine.state.phase, .externalChange)
        XCTAssertEqual(engine.state.appliedTarget, 100)
        XCTAssertTrue(engine.observe(.init(percent: 75, externalPower: true, effectiveTarget: 100)).isEmpty)
    }

    func testSystemOverrideDoesNotFightOSAndFailureNeverClaimsSuccess() throws {
        var engine = try ChargePolicyEngine(acceptedTargets: [80, 100], loweringBehavior: .no)
        let effect = try engine.submit(.ceiling(80), observation: .init(percent: 75, externalPower: true))[0]
        try engine.acknowledge(effect, effectiveTarget: 80)
        XCTAssertTrue(engine.observe(.init(percent: 89, externalPower: true, effectiveTarget: 80, systemOverride: true)).isEmpty)
        XCTAssertEqual(engine.state.phase, .systemOverride)
        engine.fail(generation: engine.state.generation, reason: "readback timed out")
        XCTAssertEqual(engine.state.phase, .fault)
        XCTAssertEqual(engine.state.appliedTarget, 80)
    }

    func testDuplicateIntentDeduplicatesAndUnsupportedTargetIsRejected() throws {
        var engine = try ChargePolicyEngine(acceptedTargets: [80, 90, 100], loweringBehavior: .yes)
        _ = try engine.submit(.ceiling(80), observation: .init(percent: 98, externalPower: true))
        let generation = engine.state.generation
        XCTAssertTrue(try engine.submit(.ceiling(80), observation: .init(percent: 98, externalPower: true)).isEmpty)
        XCTAssertEqual(engine.state.generation, generation)
        XCTAssertThrowsError(try engine.submit(.ceiling(85), observation: .init(percent: 70, externalPower: true)))
        XCTAssertEqual(engine.state.requested, .ceiling(80))
    }
}
