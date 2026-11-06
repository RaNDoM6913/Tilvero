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
        let native = NativeChargeService(client: InjectionNativeTransport(), journalURL: fixture.root.appendingPathComponent("native.json"), admitted: true)
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
    let suite = "TilveroModelInjection-\(UUID().uuidString)"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    lazy var preferences = UserDefaults(suiteName: suite)!
    var loginChanges = 0
    var settingsRequests = 0
    var sideEffects: TilveroModelSideEffects {
        .init(loginStatus: { self.loginChanges == 0 ? "Sandbox disabled" : "Sandbox enabled" },
            toggleLogin: { self.loginChanges += 1 }, openBatterySettings: { self.settingsRequests += 1 },
            rawCatalog: { [CatalogReading(definition: BatteryCatalog.definition("001"), value: .text("Sandbox inventory"), source: "Injection fixture", provenance: .reported, freshness: .fresh)] })
    }
    func cleanup() { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}
@MainActor private final class InjectionAwakeClock { var now = ContinuousClock.now }
private actor InjectionNativeTransport: NativeChargeTransport {
    func read() -> NativeChargeSnapshot {
        .init(configuration: .init(enabled: true, target: 100, optimizedCharging: true), supportedTargets: [80, 85, 90, 95, 100], registeredManualLimit: 100)
    }
    func setLimit(_ target: Int) {}
    func setEnabled(_ enabled: Bool) {}
}
