import XCTest
import PowerCore
import ChargeBackends
@testable import TilveroApp

@MainActor final class NativeChargeRecallTests: XCTestCase {
    func testQualificationAcceptsVerifiedBaselineRecalledByEnableWithoutExtraSetter() async throws {
        let f = Fixture(); defer { f.cleanup() }
        try await f.service.qualify()
        XCTAssertTrue(f.service.admitted)
        XCTAssertFalse(f.service.hasOwnedSettings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.journal.path))
        XCTAssertTrue(NativeChargeAdmission.load(from: f.admission, environment: "fixture"))
        XCTAssertEqual(f.service.observed?.configuration, .init(enabled: true, target: 80, optimizedCharging: true))
        let writes = await f.client.writes; XCTAssertEqual(writes, ["limit100", "enable"])
    }
    func testFreshBatteryRecheckBlocksEnableWhenItWouldRecallAnUnsafeBaseline() async throws {
        let f = Fixture(rising: true); defer { f.cleanup() }
        do { try await f.service.qualify(); XCTFail("Natural discharge is required") } catch {}
        XCTAssertFalse(f.service.admitted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.admission.path))
        let writes = await f.client.writes; XCTAssertEqual(writes, ["limit100"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.journal.path))
    }
    func testUnconfirmedOrDifferentRecalledStateCannotGrantAdmissionOrStartFollowUp() async throws {
        for invalid in ["target", "obc", "policy", "throw"] {
            let f = Fixture(invalid: invalid); defer { f.cleanup() }
            do { try await f.service.qualify(); XCTFail("Must remain unqualified: \(invalid)") } catch {}
            XCTAssertFalse(f.service.admitted)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.admission.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.journal.path))
            let writes = await f.client.writes; XCTAssertEqual(writes, ["limit100", "enable"])
        }
    }
    @MainActor private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroRecall-\(UUID())")
        let client: RecallTransport
        let service: NativeChargeService
        var journal: URL { directory.appendingPathComponent("session.json") }
        var admission: URL { directory.appendingPathComponent("admission.json") }
        init(rising: Bool = false, invalid: String? = nil) {
            client = RecallTransport(rising: rising, invalid: invalid)
            let transport = client
            service = NativeChargeService(client: client, journalURL: directory.appendingPathComponent("session.json"), verificationAttempts: 2,
                environment: "fixture", batteryProvider: { await transport.battery() }, admissionURL: directory.appendingPathComponent("admission.json"))
        }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }
}
private actor RecallTransport: NativeChargeTransport {
    var writes: [String] = []
    let rising: Bool
    let invalid: String?
    private var target = 80, enabled = true, optimized = true, policy = true
    private var batteryReads = 0
    init(rising: Bool, invalid: String?) { self.rising = rising; self.invalid = invalid }
    func battery() -> ChargeObservation {
        batteryReads += 1
        return .init(percent: rising && batteryReads >= 5 ? 80 : 68, externalPower: true)
    }
    func read() -> NativeChargeSnapshot {
        .init(configuration: .init(enabled: enabled, target: target, optimizedCharging: optimized), supportedTargets: [80,85,90,95,100],
              registeredManualLimit: enabled && policy ? target : nil)
    }
    func setLimit(_ target: Int) throws {
        writes.append("limit\(target)"); self.target = target; enabled = target != 100
    }
    func setEnabled(_ enabled: Bool) throws {
        writes.append(enabled ? "enable" : "disable"); self.enabled = enabled
        if enabled {
            target = invalid == "target" ? 85 : 80
            optimized = invalid != "obc"; policy = invalid != "policy"
            if invalid == "throw" { throw NativeChargeServiceError.readbackMismatch }
        }
    }
}
