// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI
import XCTest
@testable import TilveroApp

@MainActor private final class LaunchHost: FirstRunHost {
    var frame: NSRect?
    var visible = true
    var popovers = 0, details = 0, finished = 0
    var firstRunStatusButtonFrame: NSRect? { frame }
    var firstRunStatusItemVisible: Bool { visible }
    func firstRunDrawIcon(fill: Double?) {}
    func firstRunOpenPopover() { popovers += 1 }
    func firstRunOpenDetails() { details += 1 }
    func firstRunFinished() { finished += 1 }
}

/// The real launch path with a real window (fakes for everything that touches the system). The window is shown but
/// the test process is never activated. Regression: the window used to be created at 0 × 0 (invisible, yet key).
@MainActor final class FirstRunLaunchTests: XCTestCase {
    private var suite = "", defaults: UserDefaults!
    private var requests = 0
    override func setUp() async throws { suite = TestDefaults.name("Launch"); defaults = TestDefaults.defaults(suite); requests = 0 }
    override func tearDown() async throws { TestDefaults.remove(suite) }

    private func make(frame: NSRect? = NSRect(x: 1200, y: 900, width: 40, height: 24), permission: @escaping () async -> PrivilegedOutcome = { .succeeded([]) })
        -> (FirstRunCoordinator, LaunchHost) {
        let host = LaunchHost(); host.frame = frame
        let defaults = defaults!
        let ports = FirstRunPorts(
            markIntroduced: { FirstRunDecision.markIntroduced(defaults) }, setHistory: { _ in }, setLogin: { $0 ? .enabled : nil },
            openLoginItemsSettings: {}, requestPermission: { _, _ in self.requests += 1; return await permission() },
            commandText: { _ in "x" }, nudge: {}, turnOnLid: { true })
        let session = FirstRunSession(isPreview: true)
        let coordinator = FirstRunCoordinator(session: session, ports: ports, host: host)
        coordinator.activatesApp = false
        return (coordinator, host)
    }

    private func wait(_ seconds: Double = 3, until condition: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }

    private func assertVisibleAndCentered(_ coordinator: FirstRunCoordinator, file: StaticString = #filePath, line: UInt = #line) throws {
        let window = try XCTUnwrap(coordinator.window, file: file, line: line)
        XCTAssertTrue(window.isVisible, file: file, line: line)
        XCTAssertEqual(window.alphaValue, 1, accuracy: 0.01, file: file, line: line)
        XCTAssertGreaterThanOrEqual(window.frame.width, 400, file: file, line: line)
        XCTAssertGreaterThanOrEqual(window.frame.height, 300, "never a 0 × 0 window", file: file, line: line)
        // The window always matches its current content (a kept measuring view lagged one state behind).
        let ideal = FirstRunWindowGeometry.usableSize(NSHostingController(rootView: FirstRunWindowView(session: coordinator.session))
            .sizeThatFits(in: NSSize(width: FirstRunWindowView.width, height: 4000)))
        XCTAssertEqual(window.frame.height, ideal.height, accuracy: 1, "sized to the current step", file: file, line: line)
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main, file: file, line: line).visibleFrame
        XCTAssertTrue(screen.contains(window.frame), "on screen", file: file, line: line)
        XCTAssertEqual(window.frame.midX, screen.midX, accuracy: 2, file: file, line: line)
        XCTAssertEqual(window.frame.midY, screen.midY, accuracy: 2, file: file, line: line)
    }

    func testTheWindowAppearsCenteredAndStaysWithoutInput() async throws {
        let (coordinator, host) = make()
        defer { coordinator.teardown() }
        coordinator.start()
        try await Task.sleep(for: .seconds(1.5))
        try assertVisibleAndCentered(coordinator)
        XCTAssertEqual(coordinator.session.step, .choosing)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(coordinator.session.step, .choosing, "nothing moves on by itself")
        XCTAssertEqual(host.popovers + host.finished + host.details, 0)
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(defaults.bool(forKey: FirstRunDecision.introducedKey), "recorded at once")
    }

    func testAZeroOrUnknownStatusButtonFrameStillCentersTheWindow() async throws {
        for frame in [NSRect.zero, nil] {
            let (coordinator, _) = make(frame: frame)
            coordinator.start()
            try await Task.sleep(for: .seconds(0.6))
            try assertVisibleAndCentered(coordinator)
            coordinator.teardown()
        }
    }

    func testTheCloseButtonSkipsAndTheRealMenuOpens() async throws {
        let (coordinator, host) = make()
        defer { coordinator.teardown() }
        coordinator.start()
        let window = try XCTUnwrap(coordinator.window)
        XCTAssertFalse(coordinator.windowShouldClose(window), "the flow closes the window itself")
        try await wait { host.finished == 1 }
        XCTAssertEqual(host.popovers, 1)
        XCTAssertNil(coordinator.window)
        try await wait { !window.isVisible }
    }

    func testStartFromTheRealWindowOpensTheMenu() async throws {
        let (coordinator, host) = make()
        defer { coordinator.teardown() }
        coordinator.start()
        coordinator.session.flow.choices.lidClosed = false; coordinator.session.flow.choices.chargeByTime = false
        coordinator.session.send(.start)
        try await wait { host.popovers == 1 }
        try await wait { host.finished == 1 }   // the real menu opens; nothing else follows
        XCTAssertEqual(requests, 0)
    }

    func testCancelKeepsTheWindowUpAndResized() async throws {
        let (coordinator, _) = make(permission: {
            do { try await Task.sleep(for: .seconds(30)) } catch { return .cancelled }
            return .cancelled
        })
        defer { coordinator.teardown() }
        coordinator.session.flow.choices.lidClosed = true
        coordinator.start()
        try await Task.sleep(for: .seconds(0.5))
        let before = try XCTUnwrap(coordinator.window).frame
        coordinator.session.send(.start)
        try await wait { coordinator.session.step == .waitingSystem }
        coordinator.session.send(.cancel)
        XCTAssertEqual(coordinator.session.step, .declined)
        try await Task.sleep(for: .seconds(0.6))
        try assertVisibleAndCentered(coordinator)
        XCTAssertEqual(try XCTUnwrap(coordinator.window).frame.midY, before.midY, accuracy: 2, "resizes around the same center")
        XCTAssertEqual(requests, 1)
    }

    func testTickingAPasswordFeatureKeepsTheWindowWhole() async throws {
        let (coordinator, _) = make()
        defer { coordinator.teardown() }
        coordinator.start()
        try await Task.sleep(for: .seconds(0.5))
        let before = try XCTUnwrap(coordinator.window).frame
        coordinator.session.flow.choices.chargeByTime = true
        try await Task.sleep(for: .seconds(0.5))
        let after = try XCTUnwrap(coordinator.window).frame
        XCTAssertEqual(after.midY, before.midY, accuracy: 2)
        XCTAssertGreaterThanOrEqual(after.height, before.height, "the Terminal link line fits")
    }

    func testNoRoomForTheIconKeepsTheWindow() async throws {
        let (coordinator, host) = make()
        defer { coordinator.teardown() }
        host.visible = false
        coordinator.start()
        coordinator.session.send(.skip)
        try await wait { coordinator.session.step == .iconHidden }
        try await Task.sleep(for: .seconds(0.4))
        try assertVisibleAndCentered(coordinator)
        XCTAssertEqual(host.popovers, 0)
    }

    func testTheSecondLaunchNeverShowsIt() async throws {
        let (coordinator, _) = make()
        coordinator.start()
        coordinator.teardown()
        let signals = FirstRunSignals.read(defaults: defaults, historyURL: URL(fileURLWithPath: "/nonexistent/History.sqlite"),
                                           fileExists: { _ in false }, loginItemEnabled: { false })
        XCTAssertEqual(LaunchPresentation.window(arguments: ["Tilvero"], firstRun: FirstRunDecision.decide(signals: signals, context: .init())), .none)
    }

    func testThePreviewRestartShowsTheWindowAgain() async throws {
        let (coordinator, host) = make()
        defer { coordinator.teardown() }
        coordinator.start()
        coordinator.session.send(.skip)
        try await wait { host.finished == 1 }
        coordinator.restart()
        try await Task.sleep(for: .seconds(0.6))
        try assertVisibleAndCentered(coordinator)
        XCTAssertEqual(coordinator.session.step, .choosing)
        coordinator.jump(to: .declined)
        try await Task.sleep(for: .seconds(0.4))
        try assertVisibleAndCentered(coordinator)
    }
}

final class FirstRunWindowSizeTests: XCTestCase {
    func testAMeasuredSizeIsNeverZero() {
        XCTAssertEqual(FirstRunWindowGeometry.usableSize(.zero), FirstRunWindowGeometry.fallbackSize)
        XCTAssertEqual(FirstRunWindowGeometry.usableSize(NSSize(width: CGFloat.nan, height: 500)), FirstRunWindowGeometry.fallbackSize)
        XCTAssertEqual(FirstRunWindowGeometry.usableSize(NSSize(width: 480, height: 1e9)), FirstRunWindowGeometry.fallbackSize)
        XCTAssertEqual(FirstRunWindowGeometry.usableSize(NSSize(width: 480, height: 512.4)), NSSize(width: 480, height: 513))
    }
}
