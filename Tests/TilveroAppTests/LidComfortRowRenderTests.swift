// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import SwiftUI
import AppKit
import PowerCore
import PowerTelemetry
import ComfortBackends
@testable import TilveroApp

/// Render tests never reach the real display, audio or lid.
private struct InertDisplay: DisplayBrightnessTransport {
    func read() async throws -> DisplayBrightnessReading { throw ComfortBackendError.unavailable }
    func set(_ value: Double, displayID: UInt32) async throws { throw ComfortBackendError.unavailable }
}
private struct InertAudio: OutputVolumeTransport {
    private final class Sub: ComfortSubscription, @unchecked Sendable { func cancel() {} }
    func defaultOutput() async throws -> OutputVolumeReading { throw ComfortBackendError.unavailable }
    func volume(deviceUID: String) async throws -> Double? { throw ComfortBackendError.deviceMissing }
    func setVolume(_ value: Double, deviceUID: String) async throws { throw ComfortBackendError.unavailable }
    func observeDefaultOutputChanges(_ handler: @escaping @Sendable () -> Void) -> any ComfortSubscription { Sub() }
}
private final class InertClamshell: LidComfortClamshell, @unchecked Sendable {
    private final class Sub: ComfortSubscription, @unchecked Sendable { func cancel() {} }
    func sample() -> ClamshellSample { ClamshellSample(lidClosed: false, causesSleep: true) }
    func observe(_ handler: @escaping @Sendable (ClamshellSample) -> Void) -> any ComfortSubscription { Sub() }
}

@MainActor final class LidComfortRowRenderTests: XCTestCase {
    private func model(prefs: UserDefaults) -> TilveroModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let comfort = LidComfortService(display: InertDisplay(), audio: InertAudio(), clamshell: InertClamshell(), defaults: prefs, allowed: true)
        return TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"), lidComfortService: comfort)
    }
    private func render<V: View>(_ view: V, scheme: ColorScheme, name: String) throws -> NSSize {
        let host = NSHostingController(rootView: view.padding(QuickPanelMetrics.padding).frame(width: QuickPanelMetrics.width, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme).environment(\.locale, L10n.locale))
        let window = NSWindow(contentViewController: host); window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        defer { window.close() }
        let size = host.sizeThatFits(in: NSSize(width: QuickPanelMetrics.width, height: 900))
        window.setContentSize(size); window.makeKeyAndOrderFront(nil); host.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lid-comfort-render")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        return size
    }

    func testExpandedRowIsTallerThanTheCollapsedOneInBothLanguagesAndThemes() throws {
        let suite = "LidComfortRender-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let m = model(prefs: prefs); defer { m.stop() }
        for language in ["ru", "en"] {
            let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            UserDefaults.standard.setVolatileDomain(saved.merging(["language": language]) { _, v in v }, forName: UserDefaults.argumentDomain)
            defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
            for scheme in [ColorScheme.dark, .light] {
                let closed = try render(LidComfortRow(model: m, mode: .scheduledSleep), scheme: scheme, name: "closed-\(language)-\(scheme)")
                let open = try render(LidComfortRow(model: m, mode: .scheduledSleep, startsExpanded: true), scheme: scheme, name: "open-\(language)-\(scheme)")
                XCTAssertGreaterThan(open.height, closed.height + 60, "Two capsules appear when the row is expanded.")
                XCTAssertGreaterThanOrEqual(closed.height, 32 + 2 * QuickPanelMetrics.padding - 1, "The collapsed row keeps the standard 32 pt height plus padding.")
            }
        }
    }

    func testRowIsHiddenWhenTheServiceIsUnavailable() throws {
        let suite = "LidComfortHidden-\(UUID())", prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let m = TilveroModel(isDemo: true, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"))
        defer { m.stop() }
        XCTAssertFalse(m.lidComfort.isAvailable, "DEMO never offers or runs the feature.")
        let size = try render(LidComfortRow(model: m, mode: .keepAwake), scheme: .dark, name: "hidden")
        XCTAssertLessThan(size.height, 60, "Only the padding remains.")
    }

    func testEveryNewStringHasARussianTranslation() {
        for key in ["Screen and sound", "Screen brightness", "Volume", "When the lid is closed", "Expanded", "Collapsed", "Off (short)",
                    "When you close the lid, Tilvero turns the screen down and keeps the sound no louder than the levels you choose. A quieter setting is never raised.",
                    "When you open the lid, both return to what they were, unless you changed them meanwhile. The keyboard backlight turns off by itself. Keep Awake and the timer have separate settings."] {
            let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            UserDefaults.standard.setVolatileDomain(saved.merging(["language": "ru"]) { _, v in v }, forName: UserDefaults.argumentDomain)
            defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
            XCTAssertNotEqual(L10n.text(key), key, "Missing Russian string: \(key)")
        }
    }
}
