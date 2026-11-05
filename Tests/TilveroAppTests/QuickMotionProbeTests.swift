import AppKit
import SwiftUI
import XCTest
import QuartzCore
@testable import TilveroApp

/// Opt-in: TILVERO_MOTION_PROBE=<output.json> (see QuickMotionProbe.swift for the recorder).
@MainActor final class QuickMotionProbeTests: XCTestCase {
    func testProbePageSwitchFrameTimes() async throws {
        guard let outPath = ProcessInfo.processInfo.environment["TILVERO_MOTION_PROBE"] else { throw XCTSkip("probe is opt-in") }
        let suite = "Probe-\(UUID())", prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Probe-\(UUID())")
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        prefs.set(false, forKey: "historyEnabled")
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                                 snapshotProvider: { .unavailable(reason: "fixture") })
        defer { model.stop() }
        _ = NSApplication.shared
        let anchorWindow = NSWindow(contentRect: NSRect(x: 600, y: 700, width: 200, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        let anchor = NSButton(frame: NSRect(x: 0, y: 0, width: 200, height: 24)); anchorWindow.contentView?.addSubview(anchor)
        anchorWindow.orderFrontRegardless()
        let popover = NSPopover(); popover.behavior = .applicationDefined; popover.animates = true
        let host = QuickPanelHostingController(model: model, maximumHeight: 900)
        host.onSizeChange = { size in QuickPanelPopoverSizing.apply(size, to: popover) }
        popover.contentViewController = host
        popover.contentSize = host.preferredContentSize
        await model.quickPanelWillOpen()
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        try await Task.sleep(for: .milliseconds(800))
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        func tabs(_ count: Int) -> NSSegmentedControl? { all(host.view).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == count } }
        let recorder = MotionRecorder()
        recorder.sampleHeight = { popover.contentViewController?.view.window?.frame.height ?? 0 }
        var results: [String: Any] = [:]
        func switchTo(_ label: String, _ count: Int, _ index: Int) async throws {
            let control = try XCTUnwrap(tabs(count), label)
            recorder.start(view: host.view)
            try await Task.sleep(for: .milliseconds(150))   // quiet baseline
            control.selectedSegment = index; _ = control.sendAction(control.action, to: control.target)
            try await Task.sleep(for: .milliseconds(900))
            recorder.stop()
            results[label] = recorder.summary()
        }
        try await switchTo("1 overview->charge", 4, 1)
        try await switchTo("2 charge->modes", 4, 2)
        try await switchTo("3 modes->sleep", 4, 3)
        try await switchTo("4 sleep timer->keep awake", 2, 1)
        try await switchTo("5 sleep->overview", 4, 0)
        try await switchTo("6 overview->charge again", 4, 1)
        if ProcessInfo.processInfo.environment["TILVERO_MOTION_LOOP"] != nil {
            for i in 0..<40 {
                let control = try XCTUnwrap(tabs(4)); control.selectedSegment = [1, 2, 0, 3][i % 4]; _ = control.sendAction(control.action, to: control.target)
                try await Task.sleep(for: .milliseconds(700))
            }
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: outPath))
        popover.close(); anchorWindow.orderOut(nil)
    }

    /// Structural guard (not a timing assertion): a page switch inside a real popover must reach the new height
    /// through many monotonic window sizes (one shared spring), never in a single step, and must end exactly on
    /// the new page's natural height.
    func testPageSwitchResizesThePopoverThroughManyMonotonicSteps() async throws {
        let suite = "MotionSteps-\(UUID())", prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MotionSteps-\(UUID())")
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        prefs.set(false, forKey: "historyEnabled")
        let model = TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                                 snapshotProvider: { .unavailable(reason: "fixture") })
        defer { model.stop() }
        _ = NSApplication.shared
        let anchorWindow = NSWindow(contentRect: NSRect(x: 600, y: 700, width: 200, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        let anchor = NSButton(frame: NSRect(x: 0, y: 0, width: 200, height: 24)); anchorWindow.contentView?.addSubview(anchor)
        anchorWindow.orderFrontRegardless()
        defer { anchorWindow.orderOut(nil) }
        let popover = NSPopover(); popover.behavior = .applicationDefined; popover.animates = true
        let host = QuickPanelHostingController(model: model, maximumHeight: 900)
        host.onSizeChange = { size in QuickPanelPopoverSizing.apply(size, to: popover) }
        popover.contentViewController = host
        popover.contentSize = host.preferredContentSize
        await model.quickPanelWillOpen()
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        defer { popover.close() }
        try await Task.sleep(for: .milliseconds(600))
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let tabs = try XCTUnwrap(all(host.view).compactMap { $0 as? FullWidthSegmentedTabs.FullWidthControl }.first { $0.segmentCount == 4 })
        let window = try XCTUnwrap(host.view.window)
        let start = window.frame.height
        let recorder = MotionRecorder()
        recorder.sampleHeight = { window.frame.height }
        recorder.start(view: host.view)
        tabs.selectedSegment = 2   // Modes: markedly shorter than Overview
        _ = tabs.sendAction(tabs.action, to: tabs.target)
        XCTAssertTrue(tabs.isPillSliding)
        try await Task.sleep(for: .milliseconds(900))
        recorder.stop()
        let heights = (recorder.summary()["popoverHeights"] as? [Int]) ?? []
        XCTAssertGreaterThanOrEqual(heights.count, 8, "The popover must follow the page spring, not jump: \(heights)")
        XCTAssertEqual(heights, heights.sorted(by: start > Double(heights.last ?? 0) ? (>) : (<)), "Heights must move monotonically: \(heights)")
        XCTAssertEqual(Double(popover.contentSize.height), Double(host.preferredContentSize.height), accuracy: 1.5, "The popover ends on the page's natural height.")
        XCTAssertFalse(tabs.isPillSliding || recorder.frameStamps.isEmpty)
    }
}
