// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI
import XCTest
@testable import TilveroApp

@MainActor private final class ChargeSleepDriver: SleepTimerTransport {
    var hasIdleHold = false
    var console = true
    var sleepRequests = 0
    var failRequest = false
    var failAcquire = false
    var failRelease = false
    func acquireIdleHold(seconds: Int) throws {
        if failAcquire { throw KeepAwakeError.unconfirmed }
        hasIdleHold = true
    }
    func extendIdleHold() throws {}
    func replaceIdleHold(seconds: Int) throws {}
    func releaseIdleHold() throws {
        if failRelease { throw KeepAwakeError.releaseFailed }
        hasIdleHold = false
    }
    func isCurrentConsoleSession() -> Bool { console }
    func requestSleep() throws {
        sleepRequests += 1
        if failRequest { throw NativeSleepTimerError.rejected(1) }
    }
}

@MainActor final class SleepAtChargeTests: XCTestCase {
    private func makeService(_ driver: ChargeSleepDriver = ChargeSleepDriver(), prepare: @escaping @MainActor () async -> Bool = { true }) -> SleepAtChargeService {
        SleepAtChargeService(driver: driver, allowed: true, prepare: prepare)
    }

    func testArmsOnlyBelowThePresentCharge() async throws {
        let driver = ChargeSleepDriver(), service = makeService(driver)
        XCTAssertThrowsError(try service.arm(target: 20), "Without a reading nothing can be armed.")
        await service.observe(percent: 64, fresh: true, externalPower: false)
        XCTAssertTrue(service.canArm(target: 50))
        XCTAssertFalse(service.canArm(target: 64 + 1))
        XCTAssertThrowsError(try service.arm(target: 80))
        try service.arm(target: 20)
        XCTAssertEqual(service.target, 20)
        XCTAssertEqual(driver.sleepRequests, 0, "Arming never sleeps by itself.")
        XCTAssertTrue(driver.hasIdleHold, "While armed the Mac is held awake until the level.")
        try service.arm(target: 10)
        XCTAssertEqual(service.target, 10, "Choosing another level keeps the single hold.")
        XCTAssertTrue(driver.hasIdleHold)
        service.disarm()
        XCTAssertFalse(driver.hasIdleHold, "Cancelling releases the hold.")
    }

    func testFiresOnceOnBatteryPowerWhenTheChargeReachesTheLevel() async throws {
        let driver = ChargeSleepDriver(), service = makeService(driver)
        await service.observe(percent: 40, fresh: true, externalPower: false)
        try service.arm(target: 30)
        await service.observe(percent: 31, fresh: true, externalPower: false)
        XCTAssertEqual(driver.sleepRequests, 0)
        XCTAssertTrue(driver.hasIdleHold)
        await service.observe(percent: 30, fresh: true, externalPower: false)
        XCTAssertEqual(driver.sleepRequests, 1)
        XCTAssertFalse(driver.hasIdleHold, "The hold is released before the sleep request.")
        XCTAssertNil(service.target, "The intent is consumed when it fires.")
        await service.observe(percent: 25, fresh: true, externalPower: false)
        XCTAssertEqual(driver.sleepRequests, 1, "A consumed intent never fires again.")
    }

    func testNeverFiresOnPowerStaleReadingsOrUnknownPower() async throws {
        let driver = ChargeSleepDriver(), service = makeService(driver)
        await service.observe(percent: 40, fresh: true, externalPower: false)
        try service.arm(target: 30)
        await service.observe(percent: 10, fresh: true, externalPower: true)
        await service.observe(percent: 10, fresh: false, externalPower: false)
        await service.observe(percent: 10, fresh: true, externalPower: nil)
        await service.observe(percent: nil, fresh: true, externalPower: false)
        XCTAssertEqual(driver.sleepRequests, 0)
        XCTAssertEqual(service.target, 30, "Still armed, waiting for a fresh battery-power reading.")
        await service.observe(percent: 29, fresh: true, externalPower: false)
        XCTAssertEqual(driver.sleepRequests, 1)
    }

    func testSleepWakeStopAndSessionLossCancelWithoutSleeping() async throws {
        let cancels: [@MainActor (SleepAtChargeService) -> Void] = [{ $0.systemWillSleep() }, { $0.systemDidWake() }, { $0.stop() }, { $0.sessionResigned() }]
        for cancel in cancels {
            let driver = ChargeSleepDriver(), service = makeService(driver)
            await service.observe(percent: 40, fresh: true, externalPower: false)
            try service.arm(target: 30)
            cancel(service)
            XCTAssertNil(service.target)
            await service.observe(percent: 5, fresh: true, externalPower: false)
            XCTAssertEqual(driver.sleepRequests, 0)
        }
    }

    func testFailedPreparationOrLostConsoleDoesNotSleepAndConsumesTheIntent() async throws {
        var driver = ChargeSleepDriver()
        var service = makeService(driver, prepare: { false })
        await service.observe(percent: 40, fresh: true, externalPower: false)
        try service.arm(target: 30)
        await service.observe(percent: 20, fresh: true, externalPower: false)
        XCTAssertEqual(driver.sleepRequests, 0)
        XCTAssertNil(service.target)
        XCTAssertFalse(service.isRequesting)

        driver = ChargeSleepDriver(); service = makeService(driver)
        await service.observe(percent: 40, fresh: true, externalPower: false)
        try service.arm(target: 30)
        driver.console = false
        await service.observe(percent: 20, fresh: true, externalPower: false)
        XCTAssertEqual(driver.sleepRequests, 0)
        XCTAssertNil(service.target)
    }

    func testCancelDuringPreparationPreventsTheRequest() async throws {
        let driver = ChargeSleepDriver()
        var service: SleepAtChargeService!
        service = makeService(driver, prepare: { service.stop(); return true })
        await service.observe(percent: 40, fresh: true, externalPower: false)
        try service.arm(target: 30)
        await service.observe(percent: 20, fresh: true, externalPower: false)
        XCTAssertEqual(driver.sleepRequests, 0, "Cancelling while the safe preparation runs must stop the request.")
        XCTAssertNil(service.target)
        XCTAssertFalse(service.isRequesting)
    }

    func testDeclinedSleepRequestIsReportedAndEndsTheIntent() async throws {
        let driver = ChargeSleepDriver(); driver.failRequest = true
        let service = makeService(driver)
        await service.observe(percent: 40, fresh: true, externalPower: false)
        try service.arm(target: 30)
        await service.observe(percent: 30, fresh: true, externalPower: false)
        XCTAssertEqual(driver.sleepRequests, 1)
        XCTAssertNil(service.target)
        XCTAssertEqual(service.message, "macOS declined the sleep request.")
    }

    func testAFailedHoldAcquisitionDoesNotArm() async throws {
        let driver = ChargeSleepDriver(); driver.failAcquire = true
        let service = makeService(driver)
        await service.observe(percent: 40, fresh: true, externalPower: false)
        XCTAssertThrowsError(try service.arm(target: 30))
        XCTAssertNil(service.target)
        XCTAssertFalse(driver.hasIdleHold)
    }

    func testAFailedReleaseBlocksTheSleepRequestAndCancelRetries() async throws {
        let driver = ChargeSleepDriver(), service = makeService(driver)
        await service.observe(percent: 40, fresh: true, externalPower: false)
        try service.arm(target: 30)
        driver.failRelease = true
        await service.observe(percent: 20, fresh: true, externalPower: false)
        XCTAssertEqual(driver.sleepRequests, 0, "No sleep request while the hold could not be released.")
        XCTAssertTrue(driver.hasIdleHold)
        driver.failRelease = false
        service.disarm()
        XCTAssertFalse(driver.hasIdleHold, "Cancel retries the release.")
    }

    func testTheHoldIsBoundedToTwentyFourHours() async throws {
        let driver = ChargeSleepDriver()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let service = SleepAtChargeService(driver: driver, allowed: true, now: { clock })
        await service.observe(percent: 60, fresh: true, externalPower: true)
        try service.arm(target: 30)
        clock = clock.addingTimeInterval(SleepAtChargeService.maximumHold + 1)
        await service.observe(percent: 55, fresh: true, externalPower: true)
        XCTAssertNil(service.target)
        XCTAssertFalse(driver.hasIdleHold)
    }

    func testUnavailableInDemoOrMonitoring() async throws {
        let service = SleepAtChargeService(driver: ChargeSleepDriver(), allowed: false)
        await service.observe(percent: 80, fresh: true, externalPower: false)
        XCTAssertFalse(service.canArm(target: 20))
        XCTAssertThrowsError(try service.arm(target: 20))
    }

    func testPanelRendersInTheQuickSleepPage() async throws {
        let suite = "ChargeSleep-\(UUID())", prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        prefs.set(false, forKey: "historyEnabled")
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                                 snapshotProvider: { .unavailable(reason: "fixture") },
                                 sleepTimerTransport: ChargeSleepDriver())
        defer { model.stop() }
        await model.sleepAtCharge.observe(percent: 64, fresh: true, externalPower: false)
        try model.sleepAtCharge.arm(target: 20)
        for language in ["en", "ru"] {
            let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            UserDefaults.standard.setVolatileDomain(saved.merging(["language": language]) { _, v in v }, forName: UserDefaults.argumentDomain)
            defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
            for (section, name) in [(QuickPanelSection.awake, "sleep")] {
            let host = NSHostingController(rootView: QuickPanel(model: model, section: section).frame(width: 360)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark)
                .environment(\.controlActiveState, .key).environment(\.locale, L10n.locale))
            let size = host.sizeThatFits(in: NSSize(width: 360, height: 900))
            let window = NSWindow(contentViewController: host); window.appearance = NSAppearance(named: .darkAqua)
            window.setContentSize(size); host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            host.view.layoutSubtreeIfNeeded()
            XCTAssertLessThan(host.sizeThatFits(in: NSSize(width: 360, height: 900)).height, 700, "The extra block still fits the quick panel")
            if let folder = ProcessInfo.processInfo.environment["TILVERO_LOOK_DIR"] {
                window.setContentSize(host.sizeThatFits(in: NSSize(width: 360, height: 900))); host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder + "/look-charge-\(name)-\(language).png"))
            }
            window.orderOut(nil)
            }
        }
    }
}
