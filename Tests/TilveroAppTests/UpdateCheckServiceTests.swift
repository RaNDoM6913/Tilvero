import XCTest
@testable import TilveroApp

@MainActor final class UpdateCheckServiceTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "TilveroUpdateTests-\(UUID())")! }

    func testOptionalAutomaticCheckingStartsOffAndStopCancelsInFlightWork() async throws {
        let fixture = UpdateMetadataFixture.source(), transport = UpdateFixtureTransport(responses: [:])
        await transport.suspend()
        let service = UpdateCheckService(identity: fixture.identity, defaults: defaults(), discovery: UpdateDiscovery(transport: transport))
        XCTAssertFalse(service.automaticallyChecks)
        service.start()
        let initiallyEmpty = await transport.requests.isEmpty
        XCTAssertTrue(initiallyEmpty)
        let operation = Task { await service.check() }
        while await transport.requests.isEmpty { await Task.yield() }
        service.stop()
        await operation.value
        XCTAssertEqual(service.phase, .cancelled)
        XCTAssertNil(service.lastSuccess)
    }

    func testOfflineAndCancellationKeepDatedLastSuccessWithoutClaimingFreshness() async throws {
        let fixture = UpdateMetadataFixture.source(), transport = UpdateFixtureTransport(responses: UpdateMetadataFixture.source().responses)
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = UpdateCheckService(identity: fixture.identity, defaults: defaults(), discovery: UpdateDiscovery(transport: transport), now: { now })
        service.setChannel(.beta)
        await service.check()
        let success = service.lastSuccess
        XCTAssertEqual(success?.checkedAt, now)
        now = now.addingTimeInterval(60)
        await transport.setFailure(URLError(.notConnectedToInternet))
        await service.check()
        XCTAssertEqual(service.phase, .failed(.offline))
        XCTAssertEqual(service.lastSuccess, success)
        await transport.setFailure(nil); await transport.suspend()
        let operation = Task { await service.check() }
        while service.phase != .checking { await Task.yield() }
        service.cancel(); await operation.value
        XCTAssertEqual(service.phase, .cancelled)
        XCTAssertEqual(service.lastSuccess, success)
    }

    func testChannelSwitchInvalidatesVisibleSuccessAndCancellationCannotOverwriteNewCheck() async throws {
        let fixture = UpdateMetadataFixture.source(), transport = UpdateFixtureTransport(responses: fixture.responses)
        let service = UpdateCheckService(identity: fixture.identity, defaults: defaults(), discovery: UpdateDiscovery(transport: transport))
        service.setChannel(.beta); await service.check()
        XCTAssertNotNil(service.lastSuccess)
        service.setChannel(.stable)
        XCTAssertNil(service.lastSuccess)
        XCTAssertEqual(service.phase, .idle)
        await service.check()
        XCTAssertEqual(service.lastSuccess?.channel, .stable)
        XCTAssertNil(service.lastSuccess?.result.sourceRelease)
    }

    func testPreferencesPersistIndependentlyAndRestoredResultRemainsDated() async throws {
        let fixture = UpdateMetadataFixture.source(), preferences = defaults()
        let discovery = UpdateDiscovery(transport: UpdateFixtureTransport(responses: fixture.responses))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = UpdateCheckService(identity: fixture.identity, defaults: preferences, discovery: discovery, now: { date })
        first.setChannel(.beta); first.setAutomaticallyChecks(true)
        await first.check(); first.stop()
        let second = UpdateCheckService(identity: fixture.identity, defaults: preferences, discovery: discovery, now: { date.addingTimeInterval(60) })
        XCTAssertTrue(second.automaticallyChecks)
        XCTAssertEqual(second.channel, .beta)
        XCTAssertEqual(second.phase, .idle)
        XCTAssertEqual(second.lastSuccess?.checkedAt, date)
        XCTAssertEqual(second.lastSuccess?.result.sourceRelease?.kind, .sourcePreview)
    }

    func testAutomaticScheduleUsesInjectedAwakeSleeperAndNeverInstallsOrChecksByDefault() async throws {
        let fixture = UpdateMetadataFixture.source(), transport = UpdateFixtureTransport(responses: fixture.responses)
        var sleeps = 0
        let service = UpdateCheckService(identity: fixture.identity, defaults: defaults(), discovery: UpdateDiscovery(transport: transport),
            sleeper: { _ in sleeps += 1; try await Task.sleep(for: .seconds(60)) })
        service.start()
        await Task.yield()
        XCTAssertEqual(sleeps, 0)
        service.setAutomaticallyChecks(true)
        while sleeps == 0 { await Task.yield() }
        service.setAutomaticallyChecks(false)
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
        service.stop()
    }

    func testPersistedCacheRejectsBetaRecordInStableChannelAndVersionTagMismatch() async throws {
        for malformedVersion in [false, true] {
            let fixture = UpdateMetadataFixture.source(), preferences = defaults()
            let discovery = UpdateDiscovery(transport: UpdateFixtureTransport(responses: fixture.responses))
            let service = UpdateCheckService(identity: fixture.identity, defaults: preferences, discovery: discovery)
            service.setChannel(.beta); await service.check()
            let key = preferences.dictionaryRepresentation().keys.first { $0.hasPrefix("Tilvero.Updates.success.") }!
            var cached = try JSONSerialization.jsonObject(with: preferences.data(forKey: key)!) as! [String: Any]
            var snapshot = cached["snapshot"] as! [String: Any]
            if malformedVersion {
                var result = snapshot["result"] as! [String: Any]
                var source = result["sourceRelease"] as! [String: Any]
                source["version"] = "9.0.0"
                result["sourceRelease"] = source; snapshot["result"] = result
            } else {
                preferences.set("stable", forKey: "Tilvero.Updates.channel")
                snapshot["channel"] = "stable"
            }
            cached["snapshot"] = snapshot
            preferences.set(try JSONSerialization.data(withJSONObject: cached),
                            forKey: malformedVersion ? key : String(key.dropLast(4)) + "stable")
            let restored = UpdateCheckService(identity: fixture.identity, defaults: preferences, discovery: discovery)
            XCTAssertNil(restored.lastSuccess)
        }
    }

    func testOptedInAwakeScheduleActuallyChecksAndStopPreventsAnotherCycle() async throws {
        let fixture = UpdateMetadataFixture.source(), transport = UpdateFixtureTransport(responses: fixture.responses)
        var sleeps = 0
        let service = UpdateCheckService(identity: fixture.identity, defaults: defaults(), discovery: UpdateDiscovery(transport: transport),
            sleeper: { _ in
                sleeps += 1
                if sleeps > 1 { try await Task.sleep(for: .seconds(60)) }
            })
        service.setChannel(.beta)
        service.start(); service.setAutomaticallyChecks(true)
        while service.lastSuccess == nil { await Task.yield() }
        XCTAssertEqual(service.lastSuccess?.result.availability, .sourceOnly)
        service.stop()
        let count = await transport.requests.count
        XCTAssertEqual(count, 2)
    }
}
