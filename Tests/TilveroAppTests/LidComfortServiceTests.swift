// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import PowerCore
import PowerTelemetry
import ComfortBackends
@testable import ClosedLidControl
@testable import TilveroApp

private final class FakeDisplay: DisplayBrightnessTransport, @unchecked Sendable {
    private let lock = NSLock()
    var brightness = 0.57
    var id: UInt32 = 1
    var failWrites = false
    var onWrite: (() -> Void)?
    var writeSticks = true
    private(set) var writes: [Double] = []
    func read() async throws -> DisplayBrightnessReading { DisplayBrightnessReading(displayID: lock.withLock { id }, value: lock.withLock { brightness }) }
    func set(_ value: Double, displayID: UInt32) async throws {
        guard displayID == lock.withLock({ id }) else { throw ComfortBackendError.noBuiltInDisplay }
        onWrite?()
        lock.withLock { writes.append(value); if writeSticks && !failWrites { brightness = value } }
        if failWrites { throw ComfortBackendError.writeRejected }
    }
    func user(_ value: Double) { lock.withLock { brightness = value } }
    func setSticks(_ value: Bool) { lock.withLock { writeSticks = value } }
    func setID(_ value: UInt32) { lock.withLock { id = value } }
}

private final class FakeAudio: OutputVolumeTransport, @unchecked Sendable {
    private let lock = NSLock()
    struct Device { var volume: Double?; var muted = false; var settable = true }
    var devices: [String: Device] = ["speakers": Device(volume: 0.5)]
    var defaultUID = "speakers"
    private(set) var writes: [(String, Double)] = []
    var handler: (@Sendable () -> Void)?
    func defaultOutput() async throws -> OutputVolumeReading {
        let d = lock.withLock { (defaultUID, devices[defaultUID]) }
        guard let device = d.1 else { throw ComfortBackendError.unavailable }
        return OutputVolumeReading(deviceUID: d.0, volume: device.volume, muted: device.muted, isSettable: device.settable)
    }
    func volume(deviceUID: String) async throws -> Double? {
        guard let device = lock.withLock({ devices[deviceUID] }) else { throw ComfortBackendError.deviceMissing }
        return device.volume
    }
    func setVolume(_ value: Double, deviceUID: String) async throws {
        try lock.withLock {
            guard devices[deviceUID] != nil else { throw ComfortBackendError.deviceMissing }
            writes.append((deviceUID, value)); devices[deviceUID]?.volume = value
        }
    }
    func observeDefaultOutputChanges(_ handler: @escaping @Sendable () -> Void) -> any ComfortSubscription {
        lock.withLock { self.handler = handler }
        return Sub { [weak self] in self?.lock.withLock { self?.handler = nil } }
    }
    private final class Sub: ComfortSubscription, @unchecked Sendable {
        let onCancel: @Sendable () -> Void
        init(_ onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }
        func cancel() { onCancel() }
    }
    func userSetVolume(_ value: Double, _ uid: String = "speakers") { lock.withLock { devices[uid]?.volume = value } }
    func switchDefault(to uid: String) { lock.withLock { defaultUID = uid }; handler?() }
}

private final class FakeClamshell: LidComfortClamshell, @unchecked Sendable {
    private let lock = NSLock()
    var current = ClamshellSample(lidClosed: false, causesSleep: true)
    func sample() -> ClamshellSample { lock.withLock { current } }
    func observe(_ handler: @escaping @Sendable (ClamshellSample) -> Void) -> any ComfortSubscription { Cancel() }
    private final class Cancel: ComfortSubscription, @unchecked Sendable { func cancel() {} }
    func set(closed: Bool, causesSleep: Bool = true) { lock.withLock { current = ClamshellSample(lidClosed: closed, causesSleep: causesSleep) } }
}

@MainActor final class LidComfortServiceTests: XCTestCase {
    fileprivate struct Rig {
        let service: LidComfortService, display: FakeDisplay, audio: FakeAudio, lid: FakeClamshell, defaults: UserDefaults
        let cleanUp: () -> Void
    }
    fileprivate func make(allowed: Bool = true, consoleUserIsUs: Bool = true, journalFrom: UserDefaults? = nil,
                          debounce: Duration = .milliseconds(5)) -> Rig {
        let suite = "LidComfort-\(UUID())"
        let defaults = journalFrom ?? UserDefaults(suiteName: suite)!
        let display = FakeDisplay(), audio = FakeAudio(), lid = FakeClamshell()
        let service = LidComfortService(display: display, audio: audio, clamshell: lid, defaults: defaults, allowed: allowed,
                                        consoleUserIsUs: { consoleUserIsUs }, debounce: debounce, retryDelay: .milliseconds(1),
                                        restoreRetryDelay: .milliseconds(15))
        return Rig(service: service, display: display, audio: audio, lid: lid, defaults: defaults,
                   cleanUp: { defaults.removePersistentDomain(forName: suite) })
    }
    private func settle(_ ms: Int = 120) async { try? await Task.sleep(for: .milliseconds(ms)) }
    fileprivate func close(_ r: Rig, causesSleep: Bool = true) async {
        r.lid.set(closed: true, causesSleep: causesSleep)
        r.service.sampleChanged(r.lid.sample()); await settle()
    }
    fileprivate func open(_ r: Rig) async {
        r.lid.set(closed: false); r.service.sampleChanged(r.lid.sample()); await settle()
    }

    // MARK: Apply and restore

    func testClosingTheLidDimsTheScreenAndCapsTheVolumeThenOpeningRestoresBoth() async {
        let r = make(); defer { r.cleanUp() }
        r.service.armedChanged(.keepAwake)
        await close(r)
        XCTAssertEqual(r.display.brightness, 0, "The screen goes to the configured level (default 0).")
        XCTAssertEqual(r.audio.devices["speakers"]?.volume ?? 1, 0.25, accuracy: 0.001)
        XCTAssertTrue(r.service.isApplied)
        XCTAssertNotNil(r.defaults.data(forKey: LidComfortService.journalKey))
        await open(r)
        XCTAssertEqual(r.display.brightness, 0.57, accuracy: 0.001, "The value from lid close comes back, not an older one.")
        XCTAssertEqual(r.audio.devices["speakers"]?.volume ?? 0, 0.5, accuracy: 0.001)
        XCTAssertFalse(r.service.isApplied)
        XCTAssertNil(r.defaults.data(forKey: LidComfortService.journalKey))
    }

    func testAQuieterVolumeIsNeverRaisedAndNothingIsRecorded() async {
        let r = make(); defer { r.cleanUp() }
        r.audio.devices["speakers"]?.volume = 0.13
        r.service.armedChanged(.keepAwake)
        await close(r)
        XCTAssertTrue(r.audio.writes.isEmpty)
        await open(r)
        XCTAssertTrue(r.audio.writes.isEmpty, "Nothing was written, so nothing is restored.")
        XCTAssertEqual(r.audio.devices["speakers"]?.volume ?? 0, 0.13, accuracy: 0.001)
    }

    func testNothingHappensWithoutAConfirmedOverride() async {
        let r = make(); defer { r.cleanUp() }
        await close(r)
        XCTAssertTrue(r.display.writes.isEmpty); XCTAssertTrue(r.audio.writes.isEmpty)
    }

    func testOpeningInsideTheDebounceWritesNothing() async {
        let r = make(); defer { r.cleanUp() }
        r.service.armedChanged(.keepAwake)
        r.lid.set(closed: true); r.service.sampleChanged(r.lid.sample())
        r.lid.set(closed: false); r.service.sampleChanged(r.lid.sample()); await settle()
        XCTAssertTrue(r.display.writes.isEmpty); XCTAssertTrue(r.audio.writes.isEmpty)
    }

    func testAClosedLidWithAnExternalDisplayNeverApplies() async {
        let r = make(); defer { r.cleanUp() }
        r.service.armedChanged(.keepAwake)
        await close(r, causesSleep: false)
        XCTAssertTrue(r.display.writes.isEmpty); XCTAssertTrue(r.audio.writes.isEmpty)
    }

    func testAnUnreadableLidFailsClosed() async {
        let r = make(); defer { r.cleanUp() }
        r.service.armedChanged(.keepAwake)
        r.lid.current = ClamshellSample(lidClosed: nil, causesSleep: nil)
        r.service.sampleChanged(r.lid.sample()); await settle()
        XCTAssertTrue(r.display.writes.isEmpty)
    }

    func testDisabledInSimulationAndMonitoringNeverWrites() async {
        let r = make(allowed: false); defer { r.cleanUp() }
        r.service.armedChanged(.keepAwake)
        await close(r)
        XCTAssertTrue(r.display.writes.isEmpty); XCTAssertTrue(r.audio.writes.isEmpty)
        XCTAssertFalse(r.service.isAvailable)
    }

    func testAnotherConsoleUserNeverApplies() async {
        let r = make(consoleUserIsUs: false); defer { r.cleanUp() }
        r.service.armedChanged(.keepAwake)
        await close(r)
        XCTAssertTrue(r.display.writes.isEmpty)
    }

    func testMutedAndUnsettableOutputsAreSkipped() async {
        let r = make(); defer { r.cleanUp() }
        r.audio.devices["speakers"] = .init(volume: 0.5, muted: true)
        r.audio.devices["hdmi"] = .init(volume: nil)
        r.service.armedChanged(.keepAwake)
        await close(r)
        XCTAssertTrue(r.audio.writes.isEmpty, "Muted output has nothing to cap.")
        await open(r)
        r.audio.devices["speakers"] = .init(volume: 0.5, settable: false); r.audio.defaultUID = "speakers"
        await close(r)
        XCTAssertTrue(r.audio.writes.isEmpty, "An output without a settable volume is skipped silently.")
    }

    func testSettingsPerModeDecideWhatIsApplied() async {
        let r = make(); defer { r.cleanUp() }
        r.service.update(LidComfortSettings(dimDisplay: false, displayLevel: 0, limitVolume: true, volumeLevel: 0.1), for: .scheduledSleep)
        r.service.armedChanged(.scheduledSleep)
        await close(r)
        XCTAssertTrue(r.display.writes.isEmpty, "The timer's own screen switch is off.")
        XCTAssertEqual(r.audio.devices["speakers"]?.volume ?? 1, 0.1, accuracy: 0.001)
        XCTAssertEqual(r.service.settings(for: .keepAwake), .default, "The other mode keeps its defaults.")
    }

    // MARK: Crash safety

    func testTheJournalIsOnDiskBeforeTheSetterRuns() async {
        let r = make(); defer { r.cleanUp() }
        var journalSeenDuringWrite = false
        r.display.onWrite = { journalSeenDuringWrite = r.defaults.data(forKey: LidComfortService.journalKey) != nil }
        r.service.armedChanged(.keepAwake)
        await close(r)
        XCTAssertTrue(journalSeenDuringWrite)
    }

    func testARefusedWriteThatNeverLandedLeavesNoEntry() async {
        let r = make(); defer { r.cleanUp() }
        r.display.failWrites = true
        r.service.armedChanged(.keepAwake)
        await close(r)
        r.display.failWrites = false
        await open(r)
        XCTAssertEqual(r.display.brightness, 0.57, accuracy: 0.001)
        XCTAssertEqual(r.display.writes.count, 1, "Only the refused attempt; nothing was restored because nothing had changed.")
    }

    func testLaunchRecoveryRestoresWhatAKilledRunLeftBehind() async {
        let first = make(); defer { first.cleanUp() }
        first.service.armedChanged(.keepAwake)
        await close(first)
        XCTAssertEqual(first.display.brightness, 0)
        // A new process: same preferences, same system state, the lid is open again.
        let second = LidComfortService(display: first.display, audio: first.audio, clamshell: first.lid, defaults: first.defaults,
                                       consoleUserIsUs: { true }, debounce: .milliseconds(5), retryDelay: .milliseconds(1))
        first.lid.set(closed: false)
        await second.recoverIfNeeded()
        XCTAssertEqual(first.display.brightness, 0.57, accuracy: 0.001)
        XCTAssertEqual(first.audio.devices["speakers"]?.volume ?? 0, 0.5, accuracy: 0.001)
        XCTAssertNil(first.defaults.data(forKey: LidComfortService.journalKey))
    }

    func testRestoreLeavesValuesTheUserChangedMeanwhile() async {
        let r = make(); defer { r.cleanUp() }
        r.service.armedChanged(.keepAwake)
        await close(r)
        r.display.user(0.9); r.audio.userSetVolume(0.8)
        await open(r)
        XCTAssertEqual(r.display.brightness, 0.9, accuracy: 0.001)
        XCTAssertEqual(r.audio.devices["speakers"]?.volume ?? 0, 0.8, accuracy: 0.001)
        XCTAssertNil(r.defaults.data(forKey: LidComfortService.journalKey))
    }

    func testRestoreIsIdempotent() async {
        let r = make(); defer { r.cleanUp() }
        r.service.armedChanged(.keepAwake)
        await close(r)
        await r.service.restoreAll(); await r.service.restoreAll()
        XCTAssertEqual(r.display.brightness, 0.57, accuracy: 0.001)
        XCTAssertEqual(r.display.writes, [0, 0.57], "One dim, one restore, nothing more.")
    }

    func testAnUnreadableJournalIsDroppedNotReplayed() {
        let suite = "LidComfort-bad-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("garbage".utf8), forKey: LidComfortService.journalKey)
        let r = make(journalFrom: defaults)
        XCTAssertFalse(r.service.isApplied)
        XCTAssertNil(defaults.data(forKey: LidComfortService.journalKey))
    }

    // MARK: Ordering and switches

    func testBindingRegistersTheRestoreBeforeTheOverrideIsReleased() async {
        let r = make(); defer { r.cleanUp() }
        let lidSleep = LidSleepOverrideService(defaults: UserDefaults(suiteName: "LidComfort-hook-\(UUID())")!, allowed: true)
        r.service.bind(lidSleep); await settle()   // the initial "override off" emission arrives first
        r.service.armedChanged(.keepAwake)
        await close(r)
        XCTAssertEqual(r.display.brightness, 0)
        await lidSleep.beforeRelease()   // what restoreInline / prepareForTermination await before pmset is cleared
        XCTAssertEqual(r.display.brightness, 0.57, accuracy: 0.001, "Restored before the Mac may sleep.")
        XCTAssertEqual(r.audio.devices["speakers"]?.volume ?? 0, 0.5, accuracy: 0.001)
    }

    func testTerminationRestoresAndReportsClean() async {
        let r = make(); defer { r.cleanUp() }
        r.service.armedChanged(.keepAwake)
        await close(r)
        let clean = await r.service.prepareForTermination()
        XCTAssertTrue(clean)
        XCTAssertEqual(r.display.brightness, 0.57, accuracy: 0.001)
    }

    func testTurningOneSwitchOffWhileAppliedRestoresThatTargetOnly() async {
        let r = make(); defer { r.cleanUp() }
        r.service.armedChanged(.keepAwake)
        await close(r)
        var settings = r.service.settings(for: .keepAwake); settings.limitVolume = false
        r.service.update(settings, for: .keepAwake); await settle()
        XCTAssertEqual(r.audio.devices["speakers"]?.volume ?? 0, 0.5, accuracy: 0.001, "Volume is back.")
        XCTAssertEqual(r.display.brightness, 0, "The screen stays down until the lid opens.")
    }

    func testAnOutputThatAppearsWhileClosedIsCappedToo() async {
        let r = make(); defer { r.cleanUp() }
        r.audio.devices["airpods"] = .init(volume: 0.9)
        r.audio.defaultUID = "airpods"
        r.service.armedChanged(.keepAwake)
        await close(r)
        XCTAssertEqual(r.audio.devices["airpods"]?.volume ?? 1, 0.25, accuracy: 0.001)
        r.audio.switchDefault(to: "speakers"); await settle()
        XCTAssertEqual(r.audio.devices["speakers"]?.volume ?? 1, 0.25, accuracy: 0.001, "The device the sound fell back to is capped.")
        await open(r)
        XCTAssertEqual(r.audio.devices["airpods"]?.volume ?? 0, 0.9, accuracy: 0.001)
        XCTAssertEqual(r.audio.devices["speakers"]?.volume ?? 0, 0.5, accuracy: 0.001)
    }

    func testARestoreForAVanishedDeviceIsKeptForLater() async {
        let r = make(); defer { r.cleanUp() }
        r.audio.devices["airpods"] = .init(volume: 0.9); r.audio.defaultUID = "airpods"
        r.service.armedChanged(.keepAwake)
        await close(r)
        r.audio.devices["airpods"] = nil
        await open(r)
        XCTAssertNotNil(r.defaults.data(forKey: LidComfortService.journalKey), "The entry waits for the device to come back.")
    }

    // MARK: Settings storage

    func testSettingsPersistAndInvalidStoredValuesFallBackToDefaults() {
        let r = make(); defer { r.cleanUp() }
        r.service.update(LidComfortSettings(dimDisplay: true, displayLevel: 0.3, limitVolume: false, volumeLevel: 0.4), for: .keepAwake)
        let again = LidComfortService(display: r.display, audio: r.audio, clamshell: r.lid, defaults: r.defaults)
        XCTAssertEqual(again.settings(for: .keepAwake), LidComfortSettings(dimDisplay: true, displayLevel: 0.3, limitVolume: false, volumeLevel: 0.4))
        r.defaults.set("junk", forKey: LidComfortService.key(LidComfortService.dimKey, .scheduledSleep))
        r.defaults.set(Double.nan, forKey: LidComfortService.key(LidComfortService.displayLevelKey, .scheduledSleep))
        let fresh = LidComfortService(display: r.display, audio: r.audio, clamshell: r.lid, defaults: r.defaults)
        XCTAssertEqual(fresh.settings(for: .scheduledSleep), .default)
    }

    func testTheClamshellMessageConstantMatchesTheLidHelperObserver() {
        XCTAssertEqual(ClamshellStateObserver.stateChangeMessage, ClamshellNativeABI.stateMessage)
    }

    // MARK: Review fixes

    func testAKeptEntryNeverBlocksTheNextCloseAndTheOldDeviceIsRetriedWhenItReturns() async {
        let r = make(); defer { r.cleanUp() }
        r.audio.devices["airpods"] = .init(volume: 0.6); r.audio.defaultUID = "airpods"
        r.service.armedChanged(.keepAwake)
        await close(r)
        r.audio.devices["airpods"] = nil; r.audio.defaultUID = "speakers"
        await open(r)
        XCTAssertNotNil(r.defaults.data(forKey: LidComfortService.journalKey), "The AirPods entry waits for the device.")
        await close(r)
        XCTAssertEqual(r.audio.devices["speakers"]?.volume ?? 1, 0.25, accuracy: 0.001, "A later close still applies to the speakers.")
        await open(r)
        XCTAssertEqual(r.audio.devices["speakers"]?.volume ?? 0, 0.5, accuracy: 0.001)
        // The device reappears with the lid open: its entry is restored, nothing new is capped.
        r.audio.devices["airpods"] = .init(volume: 0.25); r.audio.switchDefault(to: "airpods"); await settle()
        XCTAssertEqual(r.audio.devices["airpods"]?.volume ?? 0, 0.6, accuracy: 0.001)
        XCTAssertNil(r.defaults.data(forKey: LidComfortService.journalKey))
    }

    func testAnOutputChangeWithTheLidOpenNeverCapsAnything() async {
        let r = make(); defer { r.cleanUp() }
        r.service.armedChanged(.keepAwake)
        r.audio.devices["headphones"] = .init(volume: 0.9)
        r.audio.switchDefault(to: "headphones"); await settle()
        XCTAssertTrue(r.audio.writes.isEmpty)
    }

    func testAPendingDebounceCannotApplyInTheMiddleOfAReleaseAndTheNextArmingStartsClean() async {
        let r = make(debounce: .milliseconds(150)); defer { r.cleanUp() }
        let lidSleep = LidSleepOverrideService(defaults: UserDefaults(suiteName: "LidComfort-race-\(UUID())")!, allowed: true)
        r.service.bind(lidSleep); await settle()
        r.service.armedChanged(.keepAwake)
        r.lid.set(closed: true); r.service.sampleChanged(r.lid.sample())      // debounce is running
        await lidSleep.beforeRelease()                                         // the override is being released now
        await settle(300)
        XCTAssertTrue(r.display.writes.isEmpty, "Nothing is applied once the release has started.")
        XCTAssertTrue(r.audio.writes.isEmpty)
    }

    func testAFailedRestoreIsRetriedUntilTheScreenComesBack() async {
        let r = make(); defer { r.cleanUp() }
        r.service.armedChanged(.keepAwake)
        await close(r)
        r.display.setSticks(false)                       // the panel refuses writes right after the lid opens
        await open(r)
        XCTAssertEqual(r.display.brightness, 0, "Still dark: the restore did not land yet.")
        XCTAssertNotNil(r.defaults.data(forKey: LidComfortService.journalKey))
        r.display.setSticks(true)
        await settle(400)
        XCTAssertEqual(r.display.brightness, 0.57, accuracy: 0.001, "A bounded retry brings it back without another event.")
        XCTAssertNil(r.defaults.data(forKey: LidComfortService.journalKey))
    }

    func testARestoreUsesTheCurrentBuiltInDisplayIdNotTheJournaledOne() async {
        let r = make(); defer { r.cleanUp() }
        r.service.armedChanged(.keepAwake)
        await close(r)
        r.display.setID(7)                                // e.g. crash recovery after a reboot
        await open(r)
        XCTAssertEqual(r.display.brightness, 0.57, accuracy: 0.001)
        XCTAssertNil(r.defaults.data(forKey: LidComfortService.journalKey))
    }

    func testAQuickReopenAndCloseIsAppliedAfterTheRestoreNotLost() async {
        let r = make(); defer { r.cleanUp() }
        r.service.armedChanged(.keepAwake)
        await close(r)
        r.lid.set(closed: false); r.service.sampleChanged(r.lid.sample())
        r.lid.set(closed: true); r.service.sampleChanged(r.lid.sample())
        await settle(300)
        XCTAssertEqual(r.display.brightness, 0, "The second close is dimmed again.")
        XCTAssertEqual(r.audio.devices["speakers"]?.volume ?? 1, 0.25, accuracy: 0.001)
        XCTAssertTrue(r.service.isApplied)
        await open(r)
        XCTAssertEqual(r.display.brightness, 0.57, accuracy: 0.001)
    }

    func testAnOutputThatConnectsAfterANoOpApplyIsStillCapped() async {
        let r = make(); defer { r.cleanUp() }
        r.display.brightness = 0; r.audio.devices["speakers"]?.volume = 0.13   // nothing to lower at close
        r.service.armedChanged(.keepAwake)
        await close(r)
        XCTAssertFalse(r.service.isApplied)
        r.audio.devices["airpods"] = .init(volume: 0.8)
        r.audio.switchDefault(to: "airpods"); await settle()
        XCTAssertEqual(r.audio.devices["airpods"]?.volume ?? 1, 0.25, accuracy: 0.001)
        await open(r)
        XCTAssertEqual(r.audio.devices["airpods"]?.volume ?? 0, 0.8, accuracy: 0.001)
    }
}
