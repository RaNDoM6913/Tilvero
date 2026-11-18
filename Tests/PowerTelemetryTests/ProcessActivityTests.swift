// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import PowerTelemetry

final class ProcessActivityTests: XCTestCase {
    func testIdentityCacheFollowsExecIntoAnotherExecutable() {
        var cache = ProcessIdentityCache()
        let wrapper = UUID(), app = UUID()
        cache.beginScan(applications: [])
        XCTAssertEqual(cache.identity(.init(pid: 20, start: 7, image: wrapper)) { .init(path: "/usr/libexec/xpcproxy", name: "xpcproxy") }.name, "xpcproxy")
        cache.endScan()
        cache.beginScan(applications: [])
        let real = cache.identity(.init(pid: 20, start: 7, image: app)) { .init(path: "/Applications/B.app/Contents/MacOS/B", name: "B") }
        XCTAssertEqual(real.name, "B", "exec keeps pid and start time but changes the executable: read again")
        let unknown = ProcessIdentityCache.Key(pid: 21, start: 7, rawImage: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        XCTAssertNil(unknown.image)
        _ = cache.identity(unknown) { .init(path: "/bin/sh", name: "sh") }
        _ = cache.identity(unknown) { .init(path: "/usr/bin/env", name: "env") }
        XCTAssertEqual(cache.reads, 4, "Without an executable UUID a process is never cached")
        cache.endScan()
    }

    func testIdentityCacheReadsEachProcessOnceAndFollowsPIDReuseExitsAndAppChanges() {
        var cache = ProcessIdentityCache()
        let app = ProcessApplicationIdentity(key: "/A.app", name: "A", bundlePath: "/A.app")
        let first = ProcessIdentityCache.Key(pid: 10, start: 1, image: UUID())
        cache.beginScan(applications: [])
        XCTAssertEqual(cache.identity(first) { .init(path: "/A.app/Contents/MacOS/A", name: "A") }.name, "A")
        XCTAssertNil(cache.application(forPath: "/A.app/Contents/MacOS/A"), "No running app yet")
        cache.endScan()
        cache.beginScan(applications: [app])
        XCTAssertEqual(cache.identity(first) { XCTFail("A known process is not read again"); return .init(path: nil, name: "?") }.name, "A")
        XCTAssertEqual(cache.application(forPath: "/A.app/Contents/MacOS/A"), app, "A changed app list redoes the match")
        XCTAssertEqual(cache.identity(.init(pid: 10, start: 2, image: UUID())) { .init(path: "/bin/zsh", name: "zsh") }.name, "zsh", "A reused pid is a new process")
        cache.endScan()
        XCTAssertEqual(cache.reads, 2)
        cache.beginScan(applications: [app])
        cache.endScan()   // neither process listed: both exited
        cache.beginScan(applications: [app])
        _ = cache.identity(first) { .init(path: "/A.app/Contents/MacOS/A", name: "A") }
        XCTAssertEqual(cache.reads, 3, "An exited process is forgotten")
        let top = ProcessIdentityCache.Key(pid: 11, start: 1, image: UUID())
        _ = cache.identity(top) { .init(path: nil, name: "Process 11") }
        _ = cache.identity(top) { .init(path: "/usr/bin/top", name: "top") }
        XCTAssertEqual(cache.reads, 5, "A path that could not be read is read again")
    }

    func testFirstSampleIsBaselineAndMachTicksConvertBeforeCPUPercentage() throws {
        var sampler = ProcessActivitySampler(timebaseNumerator: 125, timebaseDenominator: 3)
        let first = sampler.accept(raw(1, [counter(cpu: 24_000_000, energy: 1_000_000_000)]))
        XCTAssertTrue(first.isWarmingUp); XCTAssertTrue(first.rows.isEmpty)
        let second = sampler.accept(raw(3, [counter(cpu: 48_000_000, energy: 3_000_000_000)]))
        let row = try XCTUnwrap(second.rows.first)
        XCTAssertEqual(try XCTUnwrap(row.cpuPercent), 50, accuracy: 0.001)
        XCTAssertEqual(row.cpuPowerWatts, 1)
        XCTAssertEqual(row.cpuEnergyJoules, 2)
    }
    func testPIDReuseCounterResetAndUnsupportedEnergyCannotBecomeFakeRates() throws {
        var sampler = ProcessActivitySampler()
        _ = sampler.accept(raw(1, [counter(cpu: 100, energy: 100)]))
        XCTAssertTrue(sampler.accept(raw(2, [counter(start: 2, cpu: 200, energy: 200)])).rows.isEmpty)
        let reset = sampler.accept(raw(3, [counter(start: 2, cpu: 1, energy: 0)]))
        XCTAssertNil(reset.rows.first?.cpuPercent); XCTAssertNil(reset.rows.first?.cpuPowerWatts)
        let zero = sampler.accept(raw(4, [counter(start: 2, cpu: 2, energy: 0)]))
        XCTAssertNil(zero.rows.first?.cpuPowerWatts)
        XCTAssertTrue(sampler.accept(raw(200, [counter(start: 2, cpu: 3, energy: 0)])).isWarmingUp)
    }
    func testGroupsVerifiedMembersOnceAndDoesNotTreatPartialCPUAsBatteryShare() throws {
        var sampler = ProcessActivitySampler()
        let a = ProcessApplicationIdentity(key: "app.fixture", name: "Fixture", bundlePath: "/Fixture.app")
        _ = sampler.accept(raw(1, [counter(pid: 1, cpu: 0, energy: 1, app: a),counter(pid: 2,cpu: 0,energy: 1,app: a)]))
        let next = sampler.accept(raw(2, [counter(pid: 1,cpu: 1_000_000_000,energy: 1_000_000_001,app: a),counter(pid: 2,cpu: 1_000_000_000,energy: 1_000_000_001,app: a)], denied: 1))
        XCTAssertEqual(next.rows.count, 1)
        XCTAssertEqual(next.rows[0].processCount, 2)
        XCTAssertEqual(next.rows[0].cpuPercent, 200)
        XCTAssertEqual(next.rows[0].cpuPowerWatts, 2)
        XCTAssertEqual(next.deniedCount, 1)
        sampler.reset()
        XCTAssertTrue(sampler.accept(raw(3, [counter(cpu: 2,energy: 2)])).isWarmingUp)
    }
    func testNewGroupMemberAndAccessGapKeepCoveragePartial() throws {
        var sampler = ProcessActivitySampler()
        let app = ProcessApplicationIdentity(key: "app", name: "App", bundlePath: "/App.app")
        _ = sampler.accept(raw(1, [counter(pid: 1,cpu: 0,energy: 1,app: app)]))
        let changed = sampler.accept(raw(2, [counter(pid: 1,cpu: 1_000_000,energy: 1000,app: app),counter(pid: 2,cpu: 1,energy: 1,app: app)]))
        XCTAssertEqual(changed.rows.first?.processCount, 2)
        XCTAssertEqual(changed.rows.first?.energyProcessCount, 1)
        XCTAssertEqual(changed.rows.first?.cpuProcessCount, 1)
        _ = sampler.accept(raw(3, [], denied: 1))
        XCTAssertTrue(sampler.accept(raw(4, [counter(pid: 1,cpu: 2_000_000,energy: 2000,app: app)])).rows.isEmpty)
    }
    func testEnumerationFailureAndFlavorChangeNeverBecomeZeroEnergy() throws {
        var sampler = ProcessActivitySampler()
        _ = sampler.accept(raw(1,[counter(cpu: 1,energy: 1)]))
        let failure = sampler.accept(.init(collectedAt: Date(), monotonic: 2, counters: [], collectionError: "fixture denied"))
        XCTAssertEqual(failure.collectionError, "fixture denied")
        XCTAssertTrue(failure.rows.isEmpty)
        let v4 = ProcessResourceCounter(pid: 1,start: 1,flavor: 4,name: "fixture",cpuTicks: 100)
        XCTAssertTrue(sampler.accept(raw(3,[v4])).rows.isEmpty)
        let next = sampler.accept(raw(4,[.init(pid: 1,start: 1,flavor: 4,name: "fixture",cpuTicks: 200)]))
        XCTAssertNotNil(next.rows.first?.cpuPercent)
        XCTAssertNil(next.rows.first?.cpuPowerWatts)
        XCTAssertTrue(sampler.accept(raw(4,[v4])).isWarmingUp)
    }
    private func raw(_ time: Double, _ counters: [ProcessResourceCounter], denied: Int = 0) -> ProcessResourceCollection {
        .init(collectedAt: Date(), monotonic: time, counters: counters, deniedCount: denied)
    }
    private func counter(pid: Int32 = 1, start: UInt64 = 1, cpu: UInt64, energy: UInt64, app: ProcessApplicationIdentity? = nil) -> ProcessResourceCounter {
        .init(pid: pid, start: start, name: "fixture", application: app, cpuTicks: cpu, cpuEnergyNanojoules: energy)
    }
}
