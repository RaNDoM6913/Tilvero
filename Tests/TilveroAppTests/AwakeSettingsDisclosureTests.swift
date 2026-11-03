import AppKit
import SwiftUI
import XCTest
@testable import TilveroApp

@MainActor final class AwakeSettingsDisclosureTests: XCTestCase {
    func testFirstExpansionDoesNotShrinkAfterNativeControlsMount() async throws {
        for (disablesAnimation, textSize) in [(false, DynamicTypeSize.large), (true, .large), (false, .accessibility3)] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let probe = FirstMountProbe()
            let host = NSHostingController(rootView: QuickPanelViewport(maximumHeight: 900) {
                AwakeSettingsDisclosure(model: fixture.model, isExpanded: Binding(
                    get: { probe.isExpanded }, set: { probe.isExpanded = $0 }))
                    .frame(width: 320)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { probe.heights.append($0) }
                    .padding(20)
            }
            .frame(width: 360, height: 400, alignment: .topLeading)
            .environment(\.dynamicTypeSize, textSize)
            // This checks geometry without animation. It does not override or
            // qualify the read-only system Reduce Motion environment value.
            .transaction { if disablesAnimation { $0.animation = nil; $0.disablesAnimations = true } })
            // A fixed container removes all content-size feedback: the native
            // child must have the same expanded height on its first and last pass.
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            defer { window.orderOut(nil) }
            window.setContentSize(NSSize(width: 360, height: 400))
            try await settle(host.view)
            let collapsed = try XCTUnwrap(probe.heights.last)
            probe.heights = []
            withAnimation(.default) { probe.isExpanded = true }
            try await settle(host.view)
            print("Fixed-container Settings expansion disablesAnimation=\(disablesAnimation) textSize=\(textSize): \(probe.heights)")
            let expanded = try XCTUnwrap(probe.heights.last)
            XCTAssertGreaterThan(expanded, collapsed)
            XCTAssertEqual(try XCTUnwrap(probe.heights.first), expanded, accuracy: 0.5,
                           "Opening Settings must not reserve an incorrect native-control height and then shrink.")
            XCTAssertEqual(window.contentLayoutRect.size, NSSize(width: 360, height: 400))
            XCTAssertFalse(fixture.model.keepAwake.hasOwnedAssertion)
            XCTAssertFalse(fixture.model.sleepTimer.isActive)
            XCTAssertFalse(fixture.model.closedLid.isOn)
        }
    }

    func testClosedLidExplanationKeepsItsNaturalHeightForWrappedText() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var heights: [CGFloat] = []
        for width: CGFloat in [320, 160] {
            let host = NSHostingController(rootView: ClosedLidExplanationView(model: fixture.model).frame(width: width))
            let window = NSWindow(contentViewController: host)
            defer { window.orderOut(nil) }
            window.setContentSize(NSSize(width: width, height: 400))
            try await settle(host.view)
            heights.append(host.sizeThatFits(in: NSSize(width: width, height: 1000)).height)
        }
        XCTAssertGreaterThan(heights[1], heights[0], "Only the switch row reserves a minimum height; the explanation must grow as text wraps.")
        XCTAssertFalse(fixture.model.closedLid.isOn)
    }

    // Reintroducing fitted/scrolling content copies must lose this locally owned
    // disclosure state when its expansion crosses the viewport cap.
    func testSettingsStayExpandedWhenContentCrossesTheViewportCap() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let probe = ViewportProbe()
        let host = NSHostingController(rootView: DisclosureViewport(model: fixture.model, probe: probe))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        defer { window.orderOut(nil) }
        probe.onSizeChange = { window.setContentSize($0) }
        window.setContentSize(host.sizeThatFits(in: NSSize(width: 360, height: 900)))
        try await settle(host.view)
        let collapsed = probe.contentHeight
        XCTAssertLessThan(collapsed, 260)
        let expansion = try XCTUnwrap(probe.expansion)
        probe.maximumHeight = 260
        // Drive the real DisclosureGroup's binding under its native-style
        // animated transaction, without relying on XCTest's empty AX tree.
        withAnimation(.default) { expansion.wrappedValue = true }
        try await settle(host.view)
        let expanded = probe.contentHeight
        XCTAssertGreaterThan(expanded, 260)
        for cap: CGFloat in [180, 900, 260] {
            probe.maximumHeight = cap
            try await settle(host.view)
            XCTAssertTrue(try XCTUnwrap(probe.expansion).wrappedValue)
            XCTAssertEqual(probe.mountCount, 1, "The active Settings editor must stay mounted while its viewport changes.")
            XCTAssertEqual(probe.contentHeight, expanded, accuracy: 0.5)
            XCTAssertEqual(probe.viewportHeight, min(expanded, cap), accuracy: 0.5)
            if cap < expanded {
                let scroll = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? NSScrollView }.first)
                XCTAssertGreaterThan(scroll.contentView.documentRect.height, scroll.contentView.bounds.height,
                                     "Expanded settings must stay reachable within a capped viewport.")
            }
        }
        let settledExpansion = try XCTUnwrap(probe.expansion)
        withAnimation(.default) { settledExpansion.wrappedValue = false }
        try await settle(host.view)
        XCTAssertEqual(probe.contentHeight, collapsed, accuracy: 0.5)
        XCTAssertEqual(probe.viewportHeight, collapsed, accuracy: 0.5)
        XCTAssertEqual(probe.mountCount, 1)
        XCTAssertFalse(fixture.model.keepAwake.hasOwnedAssertion)
        XCTAssertFalse(fixture.model.sleepTimer.isActive)
        XCTAssertFalse(fixture.model.closedLid.isOn)
    }

    private func settle(_ view: NSView) async throws {
        for _ in 0..<35 {
            try await Task.sleep(for: .milliseconds(16))
            view.layoutSubtreeIfNeeded()
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @Observable @MainActor final class ViewportProbe {
        var maximumHeight: CGFloat = 900
        var contentHeight: CGFloat = 0
        var viewportHeight: CGFloat = 0
        var mountCount = 0
        @ObservationIgnored var expansion: Binding<Bool>?
        @ObservationIgnored var onSizeChange: ((CGSize) -> Void)?
    }

    @Observable @MainActor final class FirstMountProbe {
        var isExpanded = false
        @ObservationIgnored var heights: [CGFloat] = []
    }

    private struct DisclosureViewport: View {
        let model: TilveroModel
        let probe: ViewportProbe
        var body: some View {
            QuickPanelViewport(maximumHeight: probe.maximumHeight) {
                StatefulSettings(model: model, probe: probe)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: {
                probe.viewportHeight = $0.height
                probe.onSizeChange?($0)
            }
        }
    }

    private struct StatefulSettings: View {
        let model: TilveroModel
        let probe: ViewportProbe
        @State private var isExpanded = false
        var body: some View {
            VStack(spacing: 8) {
                Color.clear.frame(height: 160)
                AwakeSettingsDisclosure(model: model, isExpanded: $isExpanded)
            }
            .frame(width: 320).padding(20)
            .onAppear { probe.expansion = $isExpanded; probe.mountCount += 1 }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { probe.contentHeight = $0 }
        }
    }

    @MainActor private struct Fixture {
        let suite = "AwakeSettingsDisclosure-\(UUID())"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AwakeSettingsDisclosure-\(UUID())")
        let preferences: UserDefaults
        let model: TilveroModel
        init() throws {
            preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
            preferences.set(false, forKey: "historyEnabled")
            model = TilveroModel(isDemo: true, preferences: preferences,
                historyURL: root.appendingPathComponent("History.sqlite"),
                snapshotProvider: { .unavailable(reason: "Disclosure layout fixture — no hardware read") })
        }
        func cleanUp() {
            model.stop()
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
