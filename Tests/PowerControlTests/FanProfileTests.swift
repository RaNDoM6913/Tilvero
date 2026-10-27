import XCTest
@testable import PowerCore

final class FanProfileTests: XCTestCase {
    private let fan = FanDescriptor(id: "0", minimumRPM: 1200, maximumRPM: 6000)

    func testFanBoostLeaseExpirySleepAndOldAcknowledgement() throws {
        var engine = FanPolicyEngine(fans: [fan])
        let effect = try engine.submit(.boost(rpm: 4000, seconds: 20), now: 100, leaseSeconds: 10)[0]
        try engine.acknowledge(effect, observedRPM: ["0": 4000], auto: false)
        XCTAssertEqual(engine.state.phase, .managed)
        let release = engine.tick(now: 111, sensorTemperature: 50, sensorFresh: true)
        XCTAssertEqual(release, [.systemAuto(generation: 2)])
        XCTAssertThrowsError(try engine.acknowledge(effect, observedRPM: ["0": 4000], auto: false))
        try engine.acknowledge(release[0], observedRPM: [:], auto: true)
        XCTAssertEqual(engine.state.phase, .systemAuto)
    }

    func testStaleCurveSensorReleasesAutoAndInvalidTargetsAreRejected() throws {
        var engine = FanPolicyEngine(fans: [fan])
        let curve = try FanCurve(points: [.init(celsius: 40, rpm: 1800), .init(celsius: 80, rpm: 5000)])
        _ = try engine.submit(.curve(curve), now: 0, leaseSeconds: 30)
        XCTAssertEqual(engine.tick(now: 1, sensorTemperature: nil, sensorFresh: false), [.systemAuto(generation: 2)])
        XCTAssertThrowsError(try engine.submit(.manual(["0": 0]), now: 2, leaseSeconds: 10))
        XCTAssertEqual(engine.state.phase, .releasing)
        XCTAssertThrowsError(try FanCurve(points: [.init(celsius: 80, rpm: 5000), .init(celsius: 40, rpm: 1800)]))
    }

    func testFanlessRejectsControl() {
        var engine = FanPolicyEngine(fans: [])
        XCTAssertThrowsError(try engine.submit(.boost(rpm: 3000, seconds: 10), now: 0))
    }

    func testIndependentProfilesManualPrecedenceAndSchedulesDoNotReplay() throws {
        var arbiter = ProfileArbiter()
        let ac = PowerProfile(name: "Desk", chargeTarget: 80, mode: .low)
        let battery = PowerProfile(name: "Travel", chargeTarget: 90, mode: .automatic)
        arbiter.set(ac, for: .adapter)
        arbiter.set(battery, for: .battery)
        XCTAssertEqual(arbiter.profile(for: .adapter), ac)
        XCTAssertEqual(arbiter.profile(for: .battery), battery)
        arbiter.recordManualAction(at: Date(timeIntervalSince1970: 150))
        let rule = try ScheduleRule(id: UUID(), fireDate: Date(timeIntervalSince1970: 100), profile: ac, missedPolicy: .applyOnceWhenAvailable)
        XCTAssertNil(arbiter.evaluate(rule, now: Date(timeIntervalSince1970: 200)))
        let later = try ScheduleRule(id: UUID(), fireDate: Date(timeIntervalSince1970: 250), profile: battery, missedPolicy: .applyOnceWhenAvailable)
        XCTAssertEqual(arbiter.evaluate(later, now: Date(timeIntervalSince1970: 300)), battery)
        XCTAssertNil(arbiter.evaluate(later, now: Date(timeIntervalSince1970: 400)))
    }
}
