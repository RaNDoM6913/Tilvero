// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import PowerCore
import Carbon
@testable import TilveroApp

@MainActor final class SleepTimerIntegrationTests: XCTestCase {
    func testDirectSelectionStartsAndReplacesButEditingCustomDraftDoesNotApply() throws {
        let suite = "SleepDirect-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let driver = IntegrationSleepDriver(), clock = IntegrationSleepClock()
        let service = SleepTimerService(driver: driver, monotonic: { clock.value }, suspending: { clock.value }, sleeper: { _ in try await Task.sleep(for: .seconds(3600)) })
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"), sleepTimerService: service)
        try model.selectSleepTimer(minutes: 15)
        let id = service.sessionID
        XCTAssertEqual(service.remainingSeconds, 900)
        XCTAssertEqual(driver.holdSeconds, 900)
        clock.value = 10
        model.sleepTimerMinutes = "120"
        XCTAssertEqual(service.remainingSeconds, 890, "Typing must not commit a partial custom number")
        XCTAssertEqual(driver.holdSeconds, 900)
        try model.selectSleepTimer(minutes: 60)
        XCTAssertEqual(service.sessionID, id)
        XCTAssertEqual(service.remainingSeconds, 3600)
        XCTAssertEqual(driver.holdSeconds, 3600)
        XCTAssertEqual(driver.requests, 0)
        model.stop(); XCTAssertFalse(driver.hasIdleHold)
    }
    /// A fake macOS: nothing here runs pmset, sudo or touches a power setting.
    private final class ModelFakeLid: LidSleepSystem, @unchecked Sendable {
        private let lock = NSLock()
        private var disabled = false
        var sleepDisabled: Bool { lock.withLock { disabled } }
        var ruleFilePresent: Bool { true }
        func readSleepDisabled() async -> Bool? { lock.withLock { disabled } }
        func passwordlessPathWorks() async -> Bool { true }
        func setSleepDisabledPasswordless(_ value: Bool) async -> Bool { lock.withLock { disabled = value }; return true }
        func installRule() async -> Bool { true }
        func removeRule() async -> Bool { true }
        func restoreWithAuthorization() async -> Bool { lock.withLock { disabled = false }; return true }
        func lidClosedWouldSleep() -> Bool { false }
        func requestSleep() -> Bool { true }
    }

    func testTheTimerLidOptionSetsAndLiftsTheOverrideThroughTheModel() async throws {
        let suite = "SleepTimerLid-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let driver = IntegrationSleepDriver(), clock = IntegrationSleepClock(), system = ModelFakeLid()
        let service = SleepTimerService(driver: driver, monotonic: { clock.value }, suspending: { clock.value }, sleeper: { _ in try await Task.sleep(for: .seconds(3600)) })
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                                 sleepTimerService: service, lidSleepSystem: system)
        defer { model.stop() }
        await model.lidSleep.setPreferred(true, for: .scheduledSleep)
        XCTAssertFalse(system.sleepDisabled, "The option alone sets nothing and starts no timer.")
        XCTAssertFalse(service.isActive)
        try model.selectSleepTimer(minutes: 15)
        for _ in 0..<40 where !system.sleepDisabled { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(system.sleepDisabled, "An armed timer with its switch on keeps the Mac awake with the lid closed.")
        XCTAssertTrue(model.lidSleep.isOn)
        service.cancel()
        for _ in 0..<40 where system.sleepDisabled { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(system.sleepDisabled, "Cancelling the timer restores normal sleep.")
        XCTAssertFalse(model.lidSleep.isOn)
    }
    func testTheSameSwitchCoversSleepAtChargeThroughTheModel() async throws {
        let suite = "SleepChargeLid-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let driver = IntegrationSleepDriver(), system = ModelFakeLid()
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                                 sleepTimerTransport: driver, lidSleepSystem: system)
        defer { model.stop() }
        await model.lidSleep.setPreferred(true, for: .scheduledSleep)
        await model.sleepAtCharge.observe(percent: 64, fresh: true, externalPower: false)
        XCTAssertFalse(system.sleepDisabled, "The switch alone sets nothing.")
        try model.sleepAtCharge.arm(target: 20)
        for _ in 0..<40 where !system.sleepDisabled { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(system.sleepDisabled, "An armed Sleep at charge continues with the lid closed through the same switch.")
        model.sleepAtCharge.stop()
        for _ in 0..<40 where system.sleepDisabled { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(system.sleepDisabled, "Cancelling restores normal sleep.")
    }
    /// Owner 2026-11-07: the "With lid closed" info is short (the old text was ~125 words) and has no "not verified" line.
    func testTheLidInfoTextsAreShortAndExistInRussianAndEnglish() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TilveroApp/Resources/Localizable.xcstrings")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        for mode in [LidMode.keepAwake, .scheduledSleep] {
            let keys = LidSleepOverrideRow.infoKeys(for: mode)
            XCTAssertEqual(keys.count, 2, "\(mode): what it does, then the permission and the warning - nothing else")
            var words = [String: Int]()
            for key in keys {
                let entry = try XCTUnwrap(strings[key] as? [String: Any], "missing key: \(key.prefix(50))")
                let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
                for language in ["en", "ru"] {
                    let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any]
                    XCTAssertEqual(unit?["state"] as? String, "translated", "\(language): \(key.prefix(50))")
                    let value = unit?["value"] as? String ?? ""
                    XCTAssertFalse(value.isEmpty)
                    XCTAssertFalse(value.localizedCaseInsensitiveContains("verified") || value.contains("проверен"), "No caveat line: \(value)")
                    words[language, default: 0] += value.split(separator: " ").count
                }
            }
            XCTAssertLessThanOrEqual(words["ru"] ?? 999, 60, "\(mode): the Russian info must stay short")
            XCTAssertLessThanOrEqual(words["en"] ?? 999, 60, "\(mode): the English info must stay short")
        }
        let timer = LidSleepOverrideRow.infoKeys(for: .scheduledSleep), awake = LidSleepOverrideRow.infoKeys(for: .keepAwake)
        XCTAssertNotEqual(timer.first, awake.first)
        XCTAssertEqual(timer.last, awake.last, "The permission and warning paragraph is shared")
        XCTAssertTrue(try XCTUnwrap(timer.first).contains("Sleep at charge"), "The timer text names both functions")
    }
    func testSavedNonPresetDurationRemainsSelectedAsCustomWithoutStarting() {
        let suite = "SleepCustomReload-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(45, forKey: "sleepTimerMinutes")
        let model = TilveroModel(isDemo: true, preferences: prefs)
        XCTAssertEqual(model.sleepTimerMinutes, "45")
        XCTAssertTrue(model.sleepTimerUsesCustom)
        XCTAssertFalse(model.sleepTimer.isActive)
    }
    func testFirstNormalQuitCannotPassWhenTimerHoldReleaseFailsAndSystemQuitDoesNotWait() async throws {
        let suite = "SleepHoldQuit-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let driver = IntegrationSleepDriver()
        let service = SleepTimerService(driver: driver, sleeper: { _ in try await Task.sleep(for: .seconds(3600)) })
        let model = TilveroModel(isDemo: true, preferences: prefs, sleepTimerService: service)
        try service.start(minutes: 30)
        driver.releaseFails = true
        let normalQuit = await model.prepareForTermination()
        XCTAssertFalse(normalQuit)
        XCTAssertTrue(service.needsHoldRelease)
        XCTAssertFalse(service.isEditable)
        XCTAssertEqual(driver.requests, 0)
        let systemQuit = await model.prepareForTermination(systemInitiated: true)
        XCTAssertTrue(systemQuit, "Process-owned idle assertions cannot block OS logout/shutdown")
        driver.releaseFails = false; service.cancel()
        XCTAssertFalse(service.needsHoldRelease)
        XCTAssertFalse(driver.hasIdleHold)
    }
    func testSystemQuitReasonsDoNotUseTheInteractiveTimerQuitPolicy() {
        for reason in [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut, kAELogOut] {
            XCTAssertTrue(SleepTimerQuitReason.isSystem(reason))
        }
        XCTAssertFalse(SleepTimerQuitReason.isSystem(nil))
        XCTAssertFalse(SleepTimerQuitReason.isSystem(kAEQuitApplication))
    }
    func testCustomInputRejectsFractionsOverflowSignsAndOutOfRange() {
        for value in ["", "0", "1441", "-1", "+30", "1.5", "30 min", String(repeating: "9", count: 50)] {
            XCTAssertNil(SleepTimerInput.minutes(value), value)
        }
        XCTAssertEqual(SleepTimerInput.minutes(" 1440\n"), 1440)
        XCTAssertEqual(SleepTimerInput.minutes("1"), 1)
    }
    func testDefaultSimulationCannotStartPhysicalSleepAndOnlyDraftPersists() throws {
        let suite = "SleepDraft-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let driver = IntegrationSleepDriver()
        let model = TilveroModel(isDemo: true, preferences: prefs, sleepTimerTransport: driver)
        model.sleepTimerMinutes = "45"
        XCTAssertThrowsError(try model.startSleepTimer())
        let reopened = TilveroModel(isDemo: true, preferences: prefs, sleepTimerTransport: driver)
        XCTAssertEqual(reopened.sleepTimerMinutes, "45")
        XCTAssertFalse(reopened.sleepTimer.isActive)
        XCTAssertEqual(driver.requests, 0)
    }
    func testInFlightRefreshFinishesBeforeExpiryCanSubmitAndNewAutoActionsAreGated() async throws {
        let suite = "SleepRefresh-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let driver = IntegrationSleepDriver(), clock = IntegrationSleepClock(), gate = IntegrationSnapshotGate()
        let service = SleepTimerService(driver: driver, monotonic: { clock.value }, suspending: { clock.value }, sleeper: { _ in try await Task.sleep(for: .seconds(3600)) })
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
            snapshotProvider: { await gate.wait() }, sleepTimerService: service)
        try service.start(minutes: 1)
        let refresh = Task { await model.refresh() }
        while !(await gate.waiting) { await Task.yield() }
        clock.value = 60
        let expiry = Task { await service.reconcile() }
        while service.phase != .preparing { await Task.yield() }
        XCTAssertEqual(driver.requests, 0, "The earlier refresh must finish before sleep is requested")
        XCTAssertTrue(model.sleepTimerBlocksControls)
        await gate.finish()
        await refresh.value; await expiry.value
        XCTAssertEqual(driver.requests, 1)
        XCTAssertEqual(service.phase, .accepted)
        service.systemDidWake(); model.stop()
    }
    func testTimerStartFailureRetainsKeepAwake() throws {
        let suite = "SleepAwakeToTimerFail-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let awake = AwakeFixture(), driver = IntegrationSleepDriver()
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
            keepAwakeTransport: awake, sleepTimerTransport: driver)
        try model.startKeepAwakeDraft()
        XCTAssertTrue(model.keepAwake.hasOwnedAssertion)
        driver.acquireFails = true
        XCTAssertThrowsError(try model.startSleepTimer(replacingAwake: true))
        XCTAssertFalse(model.sleepTimer.isActive)
        XCTAssertTrue(model.keepAwake.hasOwnedAssertion, "A failed timer start must not also end Keep Awake.")
        driver.acquireFails = false
        try model.startSleepTimer(replacingAwake: true)
        XCTAssertTrue(model.sleepTimer.isActive)
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
        model.stop()
    }
    func testOppositeModesRequireConfirmationAndFailedAwakeAcquisitionRetainsTimer() throws {
        let suite = "SleepModes-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let awake = AwakeFixture(), driver = IntegrationSleepDriver()
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
            keepAwakeTransport: awake, sleepTimerTransport: driver)
        try model.startSleepTimer()
        let id = model.sleepTimer.sessionID
        XCTAssertThrowsError(try model.startKeepAwakeDraft())
        awake.failCreate = true
        XCTAssertThrowsError(try model.startKeepAwakeDraft(replacingSleepTimer: true))
        XCTAssertEqual(model.sleepTimer.sessionID, id)
        XCTAssertTrue(model.sleepTimer.isActive)
        awake.failCreate = false
        try model.startKeepAwakeDraft(replacingSleepTimer: true)
        XCTAssertFalse(model.sleepTimer.isActive)
        XCTAssertTrue(model.keepAwake.hasOwnedAssertion)
        XCTAssertThrowsError(try model.startSleepTimer())
        awake.failRelease = true
        XCTAssertThrowsError(try model.startSleepTimer(replacingAwake: true))
        XCTAssertFalse(model.sleepTimer.isActive)
        XCTAssertTrue(model.keepAwake.hasOwnedAssertion)
        awake.failRelease = false
        try model.startSleepTimer(replacingAwake: true)
        XCTAssertTrue(model.sleepTimer.isActive)
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
        model.stop(); XCTAssertEqual(driver.requests, 0)
    }
}
@MainActor private final class IntegrationSleepDriver: SleepTimerTransport {
    var requests = 0
    var hasIdleHold = false
    var holdSeconds: Int?
    var acquireFails = false
    func acquireIdleHold(seconds: Int) throws {
        if acquireFails { throw NSError(domain: "HoldFixture", code: 2) }
        hasIdleHold = true; holdSeconds = seconds
    }
    var extendFails = false
    func extendIdleHold() throws { if extendFails { throw NSError(domain: "HoldFixture", code: 3) } }
    func replaceIdleHold(seconds: Int) { hasIdleHold = true; holdSeconds = seconds }
    var releaseFails = false
    func releaseIdleHold() throws {
        if releaseFails { throw NSError(domain: "HoldFixture", code: 1) }
        hasIdleHold = false
        holdSeconds = nil
    }
    func isCurrentConsoleSession() -> Bool { true }
    func requestSleep() { requests += 1 }
}
@MainActor private final class IntegrationSleepClock { var value = 0.0 }
private actor IntegrationSnapshotGate {
    private var continuation: CheckedContinuation<BatterySnapshot, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async -> BatterySnapshot { await withCheckedContinuation { continuation = $0 } }
    func finish() {
        continuation?.resume(returning: .unavailable(reason: "Fixture only")); continuation = nil
    }
}

@MainActor final class SleepTimerWarningAttentionTests: XCTestCase {
    func testFailedExtendCancellationKeepsWarningPanelVisibleForAttention() throws {
        let driver = IntegrationSleepDriver()
        let service = SleepTimerService(driver: driver, sleeper: { _ in try await Task.sleep(for: .seconds(3600)) })
        try service.start(minutes: 30)
        XCTAssertFalse(SleepTimerWarningController.isVisible(for: service), "A healthy timer far from its deadline shows no panel.")
        driver.extendFails = true
        XCTAssertThrowsError(try service.extend())
        XCTAssertFalse(service.isActive)
        XCTAssertTrue(SleepTimerWarningController.isVisible(for: service),
                      "A cancelled timer after a failed +15 must not silently hide the warning panel.")
        service.cancel()
    }
}
