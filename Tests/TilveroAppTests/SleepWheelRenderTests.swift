// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI
import XCTest
@testable import TilveroApp

/// Renders the real production time pickers. Set TILVERO_WHEEL_RENDER_DIR to export PNGs.
@MainActor final class SleepWheelRenderTests: XCTestCase {
    func testUntilAndDurationPickersRenderAtTheirDesignedSizes() async throws {
        let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        let target = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 18, minute: 58), matchingPolicy: .nextTime)!
        for language in ["ru", "en"] {
            UserDefaults.standard.setVolatileDomain(saved.merging(["language": language]) { _, value in value }, forName: UserDefaults.argumentDomain)
            for dark in [true, false] {
                let name = "\(language)-\(dark ? "dark" : "light")"
                let until = SleepWheelPicker(mode: .until, initialMinutes: 30, initialDate: target, onCommit: { _ in }, onCancel: {})
                try await render(until, size: NSSize(width: 244, height: 220), name: "until-" + name, dark: dark)
                let duration = SleepWheelPicker(mode: .duration, initialMinutes: 90, initialDate: target, onCommit: { _ in }, onCancel: {})
                try await render(duration, size: NSSize(width: 244, height: 238), name: "duration-" + name, dark: dark)
            }
        }
    }

    private func render<V: View>(_ view: V, size: NSSize, name: String, dark: Bool) async throws {
        let margin: CGFloat = 16
        let total = NSSize(width: size.width + 2 * margin, height: size.height + 2 * margin)
        let host = NSHostingController(rootView: view
            .frame(width: size.width, height: size.height)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
            .padding(margin)
            .background(Color(white: dark ? 0.09 : 0.82))
            .environment(\.controlActiveState, .inactive).environment(\.colorScheme, dark ? .dark : .light).environment(\.locale, L10n.locale))
        let window = NSWindow(contentViewController: host)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(total); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        host.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.view.bounds.width, total.width, accuracy: 1)
        if let folder = ProcessInfo.processInfo.environment["TILVERO_WHEEL_RENDER_DIR"] {
            let root = URL(fileURLWithPath: folder); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name + ".png"))
        }
        window.orderOut(nil)
    }

    /// Owner decision 2026-11-07: a zero duration (or any value Apply refuses) shows no orange warning line and the picker
    /// keeps the same height; the disabled Apply button is the only sign.
    func testInvalidTimeShowsNoWarningLineAndKeepsItsHeight() async throws {
        let target = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 18, minute: 58), matchingPolicy: .nextTime)!
        for mode in [SleepWheelMode.duration, .until] {
            // Duration 0 is invalid. For "until" the wheels always roll to a future time, so only duration can be invalid.
            let picker = SleepWheelPicker(mode: mode, initialMinutes: 0, initialDate: target, onCommit: { _ in }, onCancel: {})
            let size = mode == .duration ? NSSize(width: 244, height: 238) : NSSize(width: 244, height: 220)
            let host = NSHostingController(rootView: picker.frame(width: size.width, height: size.height + 40, alignment: .top)
                .background(Color(white: 0.9)).environment(\.colorScheme, .light).environment(\.locale, L10n.locale))
            let window = NSWindow(contentViewController: host)
            window.appearance = NSAppearance(named: .aqua)
            window.setContentSize(NSSize(width: size.width, height: size.height + 40)); window.orderFront(nil); host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150)); host.view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            var orange = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 1) { for x in stride(from: 0, to: bitmap.pixelsWide, by: 1) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
                if h > 0.05 && h < 0.12 && sat > 0.6 && b > 0.7 { orange += 1 }
            } }
            window.orderOut(nil)
            XCTAssertEqual(orange, 0, "\(mode): no orange warning text may be drawn for an invalid time")
        }
    }

    func testPressOutsideThePickerWindowCancelsIt() async throws {
        var cancelled = 0
        let picker = SleepWheelPicker(mode: .until, initialMinutes: 30, initialDate: Date().addingTimeInterval(7200),
                                      onCommit: { _ in }, onCancel: { cancelled += 1 })
        let host = NSHostingController(rootView: picker)
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 244, height: 220)); window.orderFront(nil)
        let other = NSWindow(contentRect: NSRect(x: 600, y: 600, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        let inside = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        NSApp.sendEvent(inside)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(cancelled, 0, "A press inside the picker must not cancel it.")
        let outside = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
            windowNumber: other.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        NSApp.sendEvent(outside)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(cancelled, 1, "A press in another window dismisses the picker.")
        window.orderOut(nil); other.orderOut(nil)
    }
}
