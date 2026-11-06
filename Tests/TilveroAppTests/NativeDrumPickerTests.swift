import AppKit
import SwiftUI
import XCTest
@testable import TilveroApp

@MainActor final class NativeDrumPickerTests: XCTestCase {
    // A shorter clip must preserve the same visible-row hit mapping, snap,
    // keyboard bounds and accessibility steps as the existing regular wheel.
    func testAllWheelStylesSelectVisibleNeighborsAndRespectBounds() async throws {
        for style in [NativeDrumPicker.Style.regular, .compact, .unified] {
            var selected = 30
            var submissions = 0, cancellations = 0
            let host = NSHostingController(rootView: NativeDrumPicker(
                selection: Binding(get: { selected }, set: { selected = $0 }), range: 0...59,
                unit: "min", accessibilityName: "Minutes", style: style,
                onSubmit: { submissions += 1 }, onCancel: { cancellations += 1 }))
            let window = NSWindow(contentViewController: host)
            defer { window.orderOut(nil) }
            window.setContentSize(host.sizeThatFits(in: NSSize(width: 400, height: 400)))
            host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            host.view.layoutSubtreeIfNeeded()
            let wheel = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSScrollView }.first)
            let rows = try XCTUnwrap(wheel.documentView)
            let clip = wheel.contentView

            try click(rows, in: clip, deltaFromCenter: -40, window: window)
            XCTAssertEqual(selected, 29, "The visible row above the band must be the previous minute.")
            try click(rows, in: clip, deltaFromCenter: 40, window: window)
            XCTAssertEqual(selected, 30, "Selecting the next visible row must snap it into the center band.")
            XCTAssertTrue(wheel.accessibilityPerformIncrement())
            XCTAssertEqual(selected, 31)
            XCTAssertTrue(wheel.accessibilityPerformDecrement())
            XCTAssertEqual(selected, 30)
            try key(119, to: wheel, window: window)
            XCTAssertEqual(selected, 59)
            XCTAssertTrue(wheel.accessibilityPerformIncrement())
            XCTAssertEqual(selected, 59)
            try key(115, to: wheel, window: window)
            XCTAssertEqual(selected, 0)
            try key(126, to: wheel, window: window)
            XCTAssertEqual(selected, 0)
            XCTAssertEqual(clip.bounds.origin.y, 0, accuracy: 0.5)
            XCTAssertEqual(submissions, 0)
            XCTAssertEqual(cancellations, 0)
            try key(36, to: wheel, window: window)
            try key(53, to: wheel, window: window)
            XCTAssertEqual(submissions, 1)
            XCTAssertEqual(cancellations, 1)
        }
    }

    func testCyclicWheelContinuesPastTheEndsAndKeepsTurningBackAfterRecentering() async throws {
        var selected = 23
        let host = NSHostingController(rootView: NativeDrumPicker(
            selection: Binding(get: { selected }, set: { selected = $0 }), range: 0...23,
            unit: "h", accessibilityName: "Hours", style: .unified, wraps: true))
        let window = NSWindow(contentViewController: host)
        defer { window.orderOut(nil) }
        window.setContentSize(host.sizeThatFits(in: NSSize(width: 400, height: 400)))
        host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        host.view.layoutSubtreeIfNeeded()
        let wheel = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSScrollView }.first)
        XCTAssertTrue(wheel.accessibilityPerformIncrement())
        XCTAssertEqual(selected, 0, "After 23 the cyclic wheel continues with 0.")
        XCTAssertTrue(wheel.accessibilityPerformDecrement())
        XCTAssertEqual(selected, 23, "And 0 turns back to 23.")
        for expected in [0, 1, 2] { XCTAssertTrue(wheel.accessibilityPerformIncrement()); XCTAssertEqual(selected, expected) }
        // Many full turns in one direction never run out of rows.
        for _ in 0..<(24 * 12) { XCTAssertTrue(wheel.accessibilityPerformIncrement()) }
        XCTAssertEqual(selected, 2, "Twelve full turns return to the same hour.")
        XCTAssertEqual(wheel.accessibilityValue() as? Int, 2)
        for _ in 0..<(24 * 12 + 3) { XCTAssertTrue(wheel.accessibilityPerformDecrement()) }
        XCTAssertEqual(selected, 23)
    }

    private func click(_ rows: NSView, in clip: NSClipView, deltaFromCenter: CGFloat, window: NSWindow) throws {
        let point = clip.convert(NSPoint(x: clip.bounds.midX, y: clip.bounds.midY + deltaFromCenter), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        rows.mouseDown(with: down)
        rows.mouseUp(with: up)
    }

    private func key(_ code: UInt16, to wheel: NSScrollView, window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code))
        wheel.keyDown(with: event)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
