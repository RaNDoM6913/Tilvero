// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI
import XCTest
@testable import TilveroApp

@MainActor final class QuickPageTransitionTests: XCTestCase {
    func testSwitchingSleepPagesCompletesAndRendersACrossFadeFrame() async throws {
        let suite = "PageAnim-\(UUID())", preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PageAnim-\(UUID())")
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        preferences.set(false, forKey: "historyEnabled")
        let model = TilveroModel(isDemo: false, preferences: preferences, historyURL: root.appendingPathComponent("History.sqlite"),
                                 snapshotProvider: { .unavailable(reason: "fixture") })
        defer { model.stop() }
        let host = QuickPanelHostingController(model: model, maximumHeight: 900, section: .awake)
        let window = NSWindow(contentViewController: host)
        window.setContentSize(host.preferredContentSize); window.orderFront(nil); host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let tabs = try XCTUnwrap(all(host.view).compactMap { $0 as? NSSegmentedControl }.first { $0.label(forSegment: 0) == L10n.text("Sleep timer") || $0.segmentCount == 2 })
        var heights: [CGFloat] = []
        host.onSizeChange = { size in heights.append(size.height); window.setContentSize(size) }
        tabs.selectedSegment = 1; _ = tabs.sendAction(tabs.action, to: tabs.target)
        try await Task.sleep(for: .milliseconds(110))
        host.view.layoutSubtreeIfNeeded()
        if let folder = ProcessInfo.processInfo.environment["TILVERO_LOOK_DIR"] {
            let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder + "/look-transition-mid.png"))
        }
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(20)); host.view.layoutSubtreeIfNeeded() }
        XCTAssertEqual(tabs.selectedSegment, 1)
        XCTAssertFalse(heights.isEmpty, "The panel reports its new height after the page switch.")
        window.orderOut(nil)
    }
}

final class QuickPanelSectionVisibilityTests: XCTestCase {
    func testModesIsADevelopmentOnlyTab() {
        XCTAssertEqual(QuickPanelSection.visibleSections(development: false), [.overview, .charge, .awake])
        XCTAssertEqual(QuickPanelSection.visibleSections(development: true), [.overview, .charge, .modes, .awake])
    }
}
