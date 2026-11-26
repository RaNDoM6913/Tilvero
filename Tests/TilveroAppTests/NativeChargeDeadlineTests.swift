// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import TilveroApp
import ChargeBackends

@MainActor final class NativeChargeDeadlineTests: XCTestCase {
    /// A setter past its deadline is an unknown outcome: an indeterminate journal, no follow-up write, and the slider is
    /// blocked only while the gate still holds the call. A late return claims nothing; a settled clear read closes it.
    func testATimedOutSetterIsIndeterminateAndBlocksOnlyWhileItsCallIsPending() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeDeadline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("session.json")
        let client = SlowNativeChargeClient()
        let service = NativeChargeService(client: client, journalURL: journal, verificationAttempts: 2, operationTimeout: .milliseconds(30))
        await service.refresh()
        do { try await service.apply(90); XCTFail("Setter must time out") }
        catch NativeChargeOperationGate.Failure.timedOut {} catch { XCTFail("Wrong error: \(error)") }
        let saved = try JSONDecoder().decode(NativeChargeJournal.self, from: Data(contentsOf: journal))
        XCTAssertEqual(saved.phase, .indeterminate)
        XCTAssertEqual(saved.expectedMutation?.target, 90)
        XCTAssertEqual(service.presentation().pendingPurpose, .setLimit(target: 90))
        XCTAssertTrue(service.presentation().pendingTimedOut)
        XCTAssertFalse(service.canApply, "the gate still holds the call")
        do { try await service.apply(95); XCTFail("No second call while the first has not returned") } catch {}
        var writes = await client.writes; XCTAssertEqual(writes, [90])
        await client.release()
        for _ in 0..<200 where service.presentation().pendingPurpose != nil { await Task.yield() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path), "a late continuation must not claim the write")
        await service.refresh()
        XCTAssertTrue(service.canApplyTarget(95), "the slider is usable once the call returned")
        XCTAssertEqual(service.presentation().attention, .mutationUnresolved)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: journal.path)
        await service.refresh()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertEqual(service.reportedLimit, 90)
        writes = await client.writes; XCTAssertEqual(writes, [90], "no follow-up write")
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
