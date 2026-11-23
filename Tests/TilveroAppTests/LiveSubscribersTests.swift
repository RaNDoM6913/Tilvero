// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI
import XCTest
import PowerTelemetry
@testable import TilveroApp

private final class SampleCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
    var value: Int { lock.withLock { n } }
}

/// Live (about 1 Hz) chart data per surface: the popover's Overview as before, and the details window's charts through
/// `.liveCharts(_:surface:)`, counted only while the window is on screen. The sampler runs while any subscriber is
/// visible and the Mac is awake.
@MainActor final class LiveSubscribersTests: XCTestCase {
    private func make(counter: SampleCounter, isDemo: Bool = false) -> TilveroModel {
        let prefs = makeTestDefaults("LiveSubscribers").defaults
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = TilveroModel(isDemo: isDemo, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                                 liveSampler: {
                                     let i = counter.next()
                                     return LivePowerSample(collectedAt: Date().addingTimeInterval(0.01 * Double(i)),
                                                            systemWatts: Double(i), adapterWatts: 10, temperatureCelsius: 33)
                                 })
        addTeardownBlock { @MainActor in model.stop(); try? FileManager.default.removeItem(at: root) }
        return model
    }

    func testThePopoverOverviewSubscribesExactlyAsBefore() {
        let model = make(counter: SampleCounter())
        XCTAssertFalse(model.wantsLiveCharts)
        model.isPopoverVisible = true
        XCTAssertTrue(model.wantsLiveCharts, "Shown on Overview (the panel's first page)")
        XCTAssertEqual(model.visibleLiveSurfaces, [.popoverOverview])
        model.quickPanelSection = .charge
        XCTAssertFalse(model.wantsLiveCharts, "Another page")
        model.quickPanelSection = .overview; model.isPopoverVisible = false
        XCTAssertFalse(model.wantsLiveCharts, "Closed")
    }

    func testTheWindowSubscribesOnlyWhileItIsOnScreenAndSubscribersAreCounted() async {
        let counter = SampleCounter()
        let model = make(counter: counter)
        model.retainLiveCharts(.windowOverview)
        XCTAssertFalse(model.wantsLiveCharts, "A hidden or closed window reads nothing")
        model.isDetailVisible = true
        XCTAssertTrue(model.wantsLiveCharts)
        XCTAssertEqual(model.visibleLiveSurfaces, [.windowOverview])
        await model.liveTick()
        XCTAssertEqual(counter.value, 1, "The window's charts get live points while visible")

        model.retainLiveCharts(.windowOverview)
        model.releaseLiveCharts(.windowOverview)
        XCTAssertTrue(model.wantsLiveCharts, "One chart left on screen keeps the sampler running")
        model.isDetailVisible = false
        XCTAssertFalse(model.wantsLiveCharts)
        await model.liveTick()
        XCTAssertEqual(counter.value, 1)
        model.isDetailVisible = true
        model.releaseLiveCharts(.windowOverview)
        XCTAssertFalse(model.wantsLiveCharts, "The last chart left")
        model.releaseLiveCharts(.windowOverview)
        XCTAssertFalse(model.wantsLiveCharts, "An extra release never goes negative")
        model.retainLiveCharts(.windowOverview)
        XCTAssertTrue(model.wantsLiveCharts)
    }

    func testSleepAndDemoStopEverySurface() {
        let model = make(counter: SampleCounter())
        model.isPopoverVisible = true
        model.isDetailVisible = true; model.retainLiveCharts(.windowOverview)
        XCTAssertEqual(model.visibleLiveSurfaces, [.popoverOverview, .windowOverview])
        model.setSleeping(true)
        XCTAssertFalse(model.wantsLiveCharts, "Asleep: nothing is read")
        model.setSleeping(false)
        XCTAssertTrue(model.wantsLiveCharts)

        let demo = make(counter: SampleCounter(), isDemo: true)
        demo.isDetailVisible = true; demo.retainLiveCharts(.windowOverview)
        XCTAssertFalse(demo.wantsLiveCharts, "The simulation never reads sensors")
    }

    func testTheModifierSubscribesWhileTheViewIsShown() async throws {
        let model = make(counter: SampleCounter())
        model.isDetailVisible = true
        let host = NSHostingView(rootView: Color.clear.frame(width: 10, height: 10).liveCharts(model, surface: .windowOverview))
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<20 where !model.wantsLiveCharts {
            host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.wantsLiveCharts, "A shown chart subscribes")
        window.contentView = NSView()
        for _ in 0..<20 where model.wantsLiveCharts { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.wantsLiveCharts, "Removing it unsubscribes")
    }
}
