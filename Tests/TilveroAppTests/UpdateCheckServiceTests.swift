// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import TilveroApp

@MainActor final class UpdateCheckServiceTests: XCTestCase {
    private func defaults() -> UserDefaults { makeTestDefaults("UpdateTests").defaults }

    private func release(_ version: String, build: String?, kind: UpdateReleaseKind = .sourcePreview) -> UpdateRelease {
        UpdateRelease(tag: "v" + version, name: "", version: version, build: build, notes: "",
                      releaseURL: URL(string: "https://github.com/RaNDoM6913/Tilvero/releases/tag/v" + version)!, kind: kind)
    }
    private func identity(build: String?) -> UpdateIdentity {
        var info: [String: Any] = ["CFBundleIdentifier": "io.github.random6913.tilvero", "CFBundleShortVersionString": "0.7.0"]
        if let build { info["CFBundleVersion"] = build }
        return UpdateIdentity(info: info)
    }

    func testNewerReleaseOnlyForHigherBuildThanInstalled() {
        let installed = identity(build: "85")
        // The published source of the installed version (or an older build) is not news.
        XCTAssertNil(UpdateCheckService.newerRelease(in: .init(availability: .sourceOnly, release: nil, sourceRelease: release("0.7.0", build: "84")), than: installed))
        XCTAssertNil(UpdateCheckService.newerRelease(in: .init(availability: .sourceOnly, release: nil, sourceRelease: release("0.7.0", build: "85")), than: installed))
        XCTAssertEqual(UpdateCheckService.newerRelease(in: .init(availability: .sourceOnly, release: nil, sourceRelease: release("0.7.1", build: "90")), than: installed)?.version, "0.7.1")
        // Numeric, not lexical: build 100 is newer than 85.
        XCTAssertEqual(UpdateCheckService.newerRelease(in: .init(availability: .sourceOnly, release: nil, sourceRelease: release("1.0.0", build: "100")), than: installed)?.version, "1.0.0")
        // An app release counts only when discovery marked it available; it wins over the source record.
        let app = release("0.8.0", build: "95", kind: .macApp)
        XCTAssertEqual(UpdateCheckService.newerRelease(in: .init(availability: .appAvailable, release: app, sourceRelease: release("0.8.0", build: "95")), than: installed)?.kind, .macApp)
        XCTAssertNil(UpdateCheckService.newerRelease(in: .init(availability: .current, release: release("0.7.0", build: "85", kind: .macApp), sourceRelease: nil), than: installed))
        // "Current" app with a newer source-only release: the Updates page names the current app, so no notice either.
        XCTAssertNil(UpdateCheckService.newerRelease(in: .init(availability: .current, release: release("0.7.0", build: "85", kind: .macApp), sourceRelease: release("0.7.1", build: "90")), than: installed))
        // Unknown builds never produce a notice.
        XCTAssertNil(UpdateCheckService.newerRelease(in: .init(availability: .sourceOnly, release: nil, sourceRelease: release("0.7.1", build: nil)), than: installed))
        XCTAssertNil(UpdateCheckService.newerRelease(in: .init(availability: .sourceOnly, release: nil, sourceRelease: release("0.7.1", build: "90")), than: identity(build: nil)))
    }

    func testFailedAutomaticCheckIsRetriedAfterAnHour() async throws {
        let fixture = UpdateMetadataFixture.source(), transport = UpdateFixtureTransport(responses: fixture.responses)
        await transport.setFailure(URLError(.notConnectedToInternet))
        var delays: [Double] = []
        let service = UpdateCheckService(identity: fixture.identity, defaults: defaults(), discovery: UpdateDiscovery(transport: transport),
            sleeper: { delays.append($0); if delays.count > 1 { try await Task.sleep(for: .seconds(60)) } })
        service.start()
        while delays.count < 2 { await Task.yield() }
        service.stop()
        XCTAssertEqual(delays, [UpdateCheckService.firstCheckDelay, UpdateCheckService.retryAfterFailureDelay])
    }

    func testFirstAutomaticCheckComesShortlyAfterLaunchThenDaily() async throws {
        let fixture = UpdateMetadataFixture.source(), transport = UpdateFixtureTransport(responses: fixture.responses)
        var delays: [Double] = []
        let service = UpdateCheckService(identity: fixture.identity, defaults: defaults(), discovery: UpdateDiscovery(transport: transport),
            sleeper: { delays.append($0); if delays.count > 1 { try await Task.sleep(for: .seconds(60)) } })
        service.setChannel(.beta)
        service.start()
        while service.lastSuccess == nil { await Task.yield() }
        while delays.count < 2 { await Task.yield() }
        service.stop()
        XCTAssertEqual(delays, [UpdateCheckService.firstCheckDelay, 86_400])
    }

    func testAutomaticCheckingStartsOnWithoutAnImmediateRequestAndStopCancelsInFlightWork() async throws {
        let fixture = UpdateMetadataFixture.source(), transport = UpdateFixtureTransport(responses: [:])
        await transport.suspend()
        let service = UpdateCheckService(identity: fixture.identity, defaults: defaults(), discovery: UpdateDiscovery(transport: transport))
        XCTAssertTrue(service.automaticallyChecks)
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
        service.setAutomaticallyChecks(false)
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
