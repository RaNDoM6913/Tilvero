// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import ChargeBackends
import PowerCore
@testable import TilveroApp

@MainActor final class TilveroModelInjectionTests: XCTestCase {
    func testInjectedServicesRetainTheirOwnAdmissionAndClockWithoutNativeFallback() async throws {
        let fixture = ModelInjectionFixture()
        defer { fixture.cleanup() }
        let native = NativeChargeService(client: InjectionNativeTransport(), journalURL: fixture.root.appendingPathComponent("native.json"))
        let clock = InjectionAwakeClock()
        let awake = KeepAwakeService(driver: AwakeFixture(), sleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            continuousNow: { clock.now })
        let model = TilveroModel(isDemo: false, launchPolicy: .resolve(metadata: ["TilveroReleaseMode": "monitoring"]),
            preferences: fixture.preferences, historyURL: fixture.root.appendingPathComponent("History.sqlite"),
            snapshotProvider: { .unavailable(reason: "Injection test") }, nativeCharge: native,
            keepAwakeService: awake, sideEffects: fixture.sideEffects)
        defer { model.stop() }
        XCTAssertTrue(model.nativeCharge === native)
        XCTAssertTrue(model.keepAwake === awake)
        await native.refresh()
        XCTAssertTrue(native.canApply)
        try model.startKeepAwakeDraft()
        XCTAssertTrue(model.keepAwake.isActive)
        clock.now = clock.now.advanced(by: .seconds(1801))
        try model.keepAwake.reconcile()
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
    }

    /// A test runner is no app bundle: a model built without an injected native service never reaches the live PowerUI
    /// client (no read, no admission, no native editor), even when the panel opens.
    func testWithoutAnInjectedServiceTheLiveChargeClientIsNeverReached() async {
        let fixture = ModelInjectionFixture()
        defer { fixture.cleanup() }
        XCTAssertTrue(NativeChargeService.liveTransport() is UnavailableNativeChargeTransport)
        let model = TilveroModel(isDemo: false, launchPolicy: .resolve(metadata: [:]),
            preferences: fixture.preferences, historyURL: fixture.root.appendingPathComponent("History.sqlite"),
            snapshotProvider: { .unavailable(reason: "Injection test") }, sideEffects: fixture.sideEffects)
        defer { model.stop() }
        await model.refreshNativeCharge()
        await model.quickPanelWillOpen()
        XCTAssertFalse(model.nativeCharge.admitted)
        XCTAssertNil(model.nativeCharge.nativeSetting)
        XCTAssertFalse(model.usesNativeCharge)
    }

    func testSystemActionsAndRawInspectionAreOwnedByInjectedPorts() async {
        let fixture = ModelInjectionFixture()
        defer { fixture.cleanup() }
        let model = TilveroModel(isDemo: false, launchPolicy: .resolve(metadata: ["TilveroReleaseMode": "monitoring"]),
            preferences: fixture.preferences, historyURL: fixture.root.appendingPathComponent("History.sqlite"),
            snapshotProvider: { .unavailable(reason: "Injection test") }, sideEffects: fixture.sideEffects)
        defer { model.stop() }
        XCTAssertEqual(model.loginStatus, "Sandbox disabled")
        model.toggleLogin()
        XCTAssertEqual(model.loginStatus, "Sandbox enabled")
        XCTAssertEqual(fixture.loginChanges, 1)
        model.openBatterySettings()
        XCTAssertEqual(fixture.settingsRequests, 1)
        model.inspectRawProperties()
        for _ in 0..<50 where model.snapshot.catalog.first(where: { $0.id == "001" })?.value?.stringValue != "Sandbox inventory" { await Task.yield() }
        XCTAssertEqual(model.snapshot.catalog.first { $0.id == "001" }?.value?.stringValue, "Sandbox inventory")
    }
}

@MainActor private final class ModelInjectionFixture {
    let suite = TestDefaults.name("ModelInjection")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    lazy var preferences = TestDefaults.defaults(suite)
    var loginChanges = 0
    var settingsRequests = 0
    var sideEffects: TilveroModelSideEffects {
        .init(loginStatus: { self.loginChanges == 0 ? "Sandbox disabled" : "Sandbox enabled" },
            toggleLogin: { self.loginChanges += 1 }, openBatterySettings: { self.settingsRequests += 1 },
            rawCatalog: { [CatalogReading(definition: BatteryCatalog.definition("001"), value: .text("Sandbox inventory"), source: "Injection fixture", provenance: .reported, freshness: .fresh)] })
    }
    func cleanup() { TestDefaults.remove(suite); try? FileManager.default.removeItem(at: root) }
}
@MainActor private final class InjectionAwakeClock { var now = ContinuousClock.now }
private actor InjectionNativeTransport: NativeChargeTransport {
    func read() -> NativeChargeSnapshot {
        // macOS stores 100 as "limit off": disabled, no registered row.
        .init(configuration: .init(enabled: false, target: 100, optimizedCharging: true), supportedTargets: [80, 85, 90, 95, 100], registeredManualLimit: nil)
    }
    func setLimit(_ target: Int) {}
}
