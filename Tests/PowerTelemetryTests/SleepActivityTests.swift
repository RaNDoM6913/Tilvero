import XCTest
import IOKit.pwr_mgt
@testable import PowerTelemetry

@MainActor final class SleepActivityTests: XCTestCase {
    func testSuccessfulEmptyIsDistinctFromFailedAPIAndBranchesAreIndependent() {
        let empty = SleepActivityProvider(statusReader: { .success([:]) }, processReader: { .success([:]) }).readSnapshot()
        XCTAssertEqual(empty.aggregateAvailability, .available)
        XCTAssertEqual(empty.processAvailability, .available)
        XCTAssertTrue(empty.activeTypes.isEmpty)
        XCTAssertTrue(empty.rows.isEmpty)
        let failed = SleepActivityProvider(statusReader: { .failure }, processReader: { .success([:]) }).readSnapshot()
        XCTAssertEqual(failed.aggregateAvailability, .unavailable)
        XCTAssertEqual(failed.processAvailability, .available)
    }
    func testLevelsAndKnownSDKTypesAreDecodedWithoutLeakingRawProcessDetails() {
        let type = kIOPMAssertionTypePreventUserIdleSystemSleep as String
        let status: [AnyHashable: Any] = [type: NSNumber(value: kIOPMAssertionLevelOn), kIOPMAssertionTypePreventSystemSleep as String: 0]
        let raw: [AnyHashable: Any] = [NSNumber(value: 42): [
            [kIOPMAssertionTypeKey as String: type, kIOPMAssertionLevelKey as String: NSNumber(value: kIOPMAssertionLevelOn),
             "AssertName": "PRIVATE_DOCUMENT", "Process Name": "PRIVATE_NAME", "Path": "/private/path", "CommandLine": "SECRET"],
            [kIOPMAssertionTypeKey as String: kIOPMAssertionTypePreventUserIdleDisplaySleep as String, kIOPMAssertionLevelKey as String: 0],
            [kIOPMAssertionTypeKey as String: "Unrecognized_SECRET_type", kIOPMAssertionLevelKey as String: NSNumber(value: kIOPMAssertionLevelOn)]
        ]]
        let result = SleepActivityProvider(statusReader: { .success(status) }, processReader: { .success(raw) }).readSnapshot()
        XCTAssertEqual(result.activeTypes, [.systemIdle])
        XCTAssertEqual(result.rows.map(\.type), [.systemIdle, .unknown])
        XCTAssertEqual(result.rows.first?.processID, 42)
        XCTAssertTrue(result.rows.allSatisfy { $0.processName == nil })
        XCTAssertFalse(String(describing: result).contains("PRIVATE"))
        XCTAssertFalse(String(describing: result).contains("SECRET"))
        XCTAssertFalse(String(describing: result).contains("/private/path"))
    }
    func testMalformedSuccessfulPayloadIsUnavailableRatherThanFalseEmpty() {
        let snapshot = SleepActivityProvider(statusReader: { .success(["PreventSystemSleep": "bad level"]) },
            processReader: { .success([NSNumber(value: 42): "not rows"]) }).readSnapshot()
        XCTAssertEqual(snapshot.aggregateAvailability, .unavailable)
        XCTAssertEqual(snapshot.processAvailability, .unavailable)
        XCTAssertTrue(snapshot.rows.isEmpty)
    }
    func testPIDReusedBetweenAssertionSnapshotAndNameLookupHasNoName() {
        let raw: [AnyHashable: Any] = [NSNumber(value: 42): [[
            kIOPMAssertionTypeKey as String: kIOPMAssertionTypePreventSystemSleep as String,
            kIOPMAssertionLevelKey as String: 1]]]
        let old = SleepProcessIdentity(launchDate: Date(timeIntervalSince1970: 100), displayName: "Old app")
        let replacement = SleepProcessIdentity(launchDate: Date(timeIntervalSince1970: 200), displayName: "Wrong new app")
        var sampled = false
        let result = SleepActivityProvider(statusReader: { .success([:]) }, processReader: { sampled = true; return .success(raw) },
            processIdentity: { _ in sampled ? replacement : old }, processIdentities: { [42: old] }).readSnapshot()
        XCTAssertNil(result.rows.first?.processName)
        XCTAssertEqual(result.rows.first?.processID, 42)
    }

    func testOnlyStableLaunchIdentityPermitsLiveDisplayName() {
        let raw: [AnyHashable: Any] = [NSNumber(value: 42): [[
            kIOPMAssertionTypeKey as String: kIOPMAssertionTypePreventSystemSleep as String,
            kIOPMAssertionLevelKey as String: 1]]]
        let launched = Date(timeIntervalSince1970: 1_700_000_000)
        let stable = SleepActivityProvider(statusReader: { .success([:]) }, processReader: { .success(raw) },
            processIdentity: { _ in .init(launchDate: launched, displayName: "Preview") },
            processIdentities: { [42: .init(launchDate: launched, displayName: "Preview")] }).readSnapshot()
        XCTAssertEqual(stable.rows.first?.processName, "Preview")
        var calls = 0
        let reused = SleepActivityProvider(statusReader: { .success([:]) }, processReader: { .success(raw) }, processIdentity: { _ in
            calls += 1
            return .init(launchDate: launched.addingTimeInterval(Double(calls)), displayName: "Wrong process")
        }, processIdentities: { [42: .init(launchDate: launched, displayName: "Wrong process")] }).readSnapshot()
        XCTAssertNil(reused.rows.first?.processName)
        let path = SleepActivityProvider(statusReader: { .success([:]) }, processReader: { .success(raw) },
            processIdentity: { _ in .init(launchDate: launched, displayName: "/private/executable") },
            processIdentities: { [42: .init(launchDate: launched, displayName: "/private/executable")] }).readSnapshot()
        XCTAssertNil(path.rows.first?.processName)
    }
}
