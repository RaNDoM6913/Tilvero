import XCTest
@testable import TilveroApp
import ChargeBackends

@MainActor final class NativeChargeDeadlineTests: XCTestCase {
    func testTimedOutSetterCannotContinueAndBlocksRollbackUntilItReturns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeDeadline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SlowNativeChargeClient()
        let service = NativeChargeService(client: client, journalURL: root.appendingPathComponent("session.json"), admitted: true,
                                          verificationAttempts: 2, operationTimeout: .milliseconds(30))
        await service.refresh()
        do { try await service.apply(90, batteryPercent: 60, batteryFresh: true); XCTFail("Setter must time out") } catch {}
        XCTAssertTrue(service.recoveryRequired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("session.json").path))
        do { _ = try await service.restore(batteryPercent: 60, batteryFresh: true); XCTFail("An in-flight call cannot be rolled back concurrently") } catch {}
        var writes = await client.writes; XCTAssertEqual(writes, [90])
        await client.release()
        for _ in 0..<200 { await Task.yield() }
        XCTAssertTrue(service.recoveryRequired, "A late continuation must not claim applied or erase recovery")
        await service.refresh()
        let restored = try await service.restore(batteryPercent: 60, batteryFresh: true)
        XCTAssertTrue(restored)
        writes = await client.writes; XCTAssertEqual(writes, [90,85])
    }
}

private actor SlowNativeChargeClient: NativeChargeTransport {
    var writes: [Int] = []
    private var target = 85
    private var first = true
    private var continuation: CheckedContinuation<Void, Never>?
    func read() async throws -> NativeChargeSnapshot {
        .init(configuration: .init(enabled: true, target: target, optimizedCharging: true), supportedTargets: [80,85,90,95,100], registeredManualLimit: target)
    }
    func setLimit(_ target: Int) async throws {
        writes.append(target)
        if first { first = false; await withCheckedContinuation { continuation = $0 } }
        self.target = target
    }
    func setEnabled(_ enabled: Bool) async throws {}
    func release() { continuation?.resume(); continuation = nil }
}
