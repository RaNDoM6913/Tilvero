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
}
