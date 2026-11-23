// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI
import XCTest
@testable import TilveroApp

/// The popover keeps one long-lived host. Switching the language must redraw its frame (tabs, gear, footer row) in the
/// new language while it stays open, not only the pages that happen to read the model's language.
@MainActor final class QuickPanelLanguageTests: XCTestCase {
    private func setLanguage(_ language: String, model: TilveroModel) {
        var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        domain["language"] = language
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        model.language = language
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    /// The footer row ("History & reports…") is the panel's only AppKit-hosted button; its pixels show its text.
    private func footerPixels(_ view: NSView) -> Data? {
        guard let button = descendants(view).first(where: { String(describing: type(of: $0)) == "SwiftUIAppKitButton" }),
              let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return nil }
        button.cacheDisplay(in: button.bounds, to: rep)
        return rep.tiffRepresentation
    }

    private func settle(_ view: NSView) async throws {
        for _ in 0..<15 { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    }

    func testOneHostSwitchesBetweenRussianAndEnglish() async throws {
        let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        let prefs = makeTestDefaults("QuickLanguage").defaults
        prefs.set(false, forKey: "historyEnabled")
        let model = TilveroModel(isDemo: true, preferences: prefs)
        defer { model.stop() }
        setLanguage("en", model: model)
        let host = QuickPanelHostingController(model: model, maximumHeight: 900)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: QuickPanelMetrics.width, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host.view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        var shown: [String: [String]] = [:]
        var footers: [Data?] = []
        for language in ["en", "ru", "en"] {
            RenderProbe.isEnabled = true; RenderProbe.reset()
            setLanguage(language, model: model)
            try await settle(host.view)
            RenderProbe.isEnabled = false
            if language != "en" || !footers.isEmpty {
                // The root body builds the gear's accessibility label and the footer row from L10n.
                XCTAssertGreaterThanOrEqual(RenderProbe.counts["QuickPanel.overview"] ?? 0, 1, "\(language): the panel frame was rebuilt")
            }
            let tabs = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSSegmentedControl }.first)
            let labels = (0..<tabs.segmentCount).map { tabs.label(forSegment: $0) ?? "" }
            XCTAssertEqual(Array(labels.prefix(3)), [L10n.text("Overview"), L10n.text("Sleep"), L10n.text("Charge")], language)
            shown[language] = labels
            footers.append(footerPixels(host.view))
        }
        RenderProbe.reset()
        XCTAssertNotEqual(shown["en"], shown["ru"], "The tabs really changed language in the same host")
        XCTAssertNotNil(footers[0])
        XCTAssertNotEqual(footers[0], footers[1], "The footer row was redrawn in Russian")
        XCTAssertNotEqual(footers[1], footers[2], "…and back in English")
    }
}
