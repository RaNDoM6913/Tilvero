// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI
import XCTest
@testable import TilveroApp

@MainActor final class WindowQuickMenuEditorTests: XCTestCase {
    private var savedArguments: [String: Any] = [:]
    override func setUp() async throws { savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain) }
    override func tearDown() async throws { UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain) }
    private func setLanguage(_ language: String, model: TilveroModel? = nil) {
        UserDefaults.standard.setVolatileDomain(savedArguments.merging(["language": language]) { _, value in value },
                                               forName: UserDefaults.argumentDomain)
        model?.language = language
    }

    // MARK: Editing rules

    func testInlineDurationFieldsAcceptHoursZeroToTwentyFourAndMinutesZeroToFiftyNine() {
        XCTAssertEqual(QuickPresetEdit.minutes(hours: "1", minutes: "30"), 90)
        XCTAssertEqual(QuickPresetEdit.minutes(hours: "0", minutes: "45"), 45)
        XCTAssertEqual(QuickPresetEdit.minutes(hours: "", minutes: "5"), 5)
        XCTAssertEqual(QuickPresetEdit.minutes(hours: "24", minutes: ""), 1440)
        XCTAssertNil(QuickPresetEdit.minutes(hours: "24", minutes: "1"), "over 24 h")
        XCTAssertNil(QuickPresetEdit.minutes(hours: "25", minutes: "0"))
        XCTAssertNil(QuickPresetEdit.minutes(hours: "1", minutes: "60"))
        XCTAssertNil(QuickPresetEdit.minutes(hours: "0", minutes: "0"))
        XCTAssertNil(QuickPresetEdit.minutes(hours: "", minutes: ""))
        XCTAssertNil(QuickPresetEdit.minutes(hours: "x", minutes: "5"))
    }

    func testAddEditRemoveDuplicateAndLimits() {
        let timer = [15, 30, 60]
        XCTAssertEqual(QuickPresetEdit.verdict(45, row: .sleepTimer, in: timer, editing: nil), .valid(45))
        XCTAssertEqual(QuickPresetEdit.applying(45, row: .sleepTimer, to: timer, editing: nil), [15, 30, 45, 60], "sorted automatically")
        XCTAssertEqual(QuickPresetEdit.verdict(30, row: .sleepTimer, in: timer, editing: nil), .duplicate(1), "the existing chip is named")
        XCTAssertEqual(QuickPresetEdit.verdict(30, row: .sleepTimer, in: timer, editing: 1), .valid(30), "unchanged value of the edited chip")
        XCTAssertEqual(QuickPresetEdit.verdict(nil, row: .sleepTimer, in: timer, editing: 0), .invalid)
        XCTAssertEqual(QuickPresetEdit.applying(90, row: .sleepTimer, to: timer, editing: 2), [15, 30, 90], "edit replaces in place")
        XCTAssertEqual(QuickPresetEdit.applying(5, row: .sleepTimer, to: timer, editing: 2), [5, 15, 30])
        let full = [5, 10, 15, 20, 25, 30, 35]
        XCTAssertEqual(QuickPresetEdit.verdict(40, row: .sleepTimer, in: full, editing: nil), .full)
        XCTAssertFalse(QuickPresetEdit.canAdd(full, row: .sleepTimer))
        XCTAssertEqual(QuickPresetEdit.verdict(40, row: .sleepTimer, in: full, editing: 0), .valid(40), "editing a full row is fine")
        XCTAssertFalse(QuickPresetEdit.canAdd([15, 30, 60, 240], row: .overviewAwake))
        XCTAssertEqual(QuickPresetEdit.removing(at: 0, row: .sleepTimer, from: timer), [30, 60])
        XCTAssertFalse(QuickPresetEdit.canRemove([30]))
        XCTAssertEqual(QuickPresetEdit.removing(at: 0, row: .sleepTimer, from: [30]), [30], "the last chip stays")
        let levels = [50, 30, 20, 10, 5]
        XCTAssertEqual(QuickPresetEdit.freeLevels(row: .sleepAtCharge, in: levels).count, 14)
        XCTAssertFalse(QuickPresetEdit.freeLevels(row: .sleepAtCharge, in: levels).contains(50))
        XCTAssertEqual(QuickPresetEdit.applying(60, row: .sleepAtCharge, to: levels, editing: nil), [60, 50, 30, 20, 10, 5])
        XCTAssertEqual(QuickPresetEdit.verdict(12, row: .sleepAtCharge, in: levels, editing: nil), .invalid)
        XCTAssertEqual(QuickPresetEdit.verdict(25, row: .sleepAtCharge, in: [50, 40, 30, 20, 10, 5], editing: nil), .full)
    }

    func testStoreEditsAndResetRestoreTheFiveRowsOnly() {
        let f = PresetFixture.make(); defer { f.cleanup() }
        let store = f.model.quickPresets
        let layout = f.model.overviewPreferences
        store.set(.sleepTimer, QuickPresetEdit.applying(45, row: .sleepTimer, to: store[.sleepTimer], editing: nil))
        store.set(.awakeUntilCharge, QuickPresetEdit.removing(at: 0, row: .awakeUntilCharge, from: store[.awakeUntilCharge]))
        XCTAssertEqual(store[.sleepTimer], [15, 30, 45, 60])
        XCTAssertEqual(store[.awakeUntilCharge], [30, 20, 10, 5])
        XCTAssertFalse(store.isDefault)
        store.resetToDefaults()
        XCTAssertEqual(store.presets, .defaults)
        XCTAssertEqual(f.model.overviewPreferences, layout, "the blocks are a separate reset")
    }

    func testFixedTailsAreLockedAndNeverInTheEditableList() {
        setLanguage("ru")
        XCTAssertEqual(QuickPresetEdit.fixedTail(.sleepTimer).map(\.label), [L10n.text("Custom timer time")])
        XCTAssertEqual(QuickPresetEdit.fixedTail(.keepAwake).map(\.label), ["∞", L10n.text("Until…")])
        XCTAssertEqual(QuickPresetEdit.fixedTail(.overviewAwake).map(\.label), ["∞"])
        XCTAssertTrue(QuickPresetEdit.fixedTail(.sleepAtCharge).isEmpty)
        XCTAssertEqual(QuickPresetEdit.lockedLabel(L10n.text("Until stopped")), L10n.text("Until stopped") + ", " + L10n.text("cannot be removed"))
    }

    func testVoiceOverLabelsReadFullWords() {
        setLanguage("ru")
        XCTAssertEqual(QuickPresetEdit.removeLabel(45, row: .sleepTimer), L10n.text("Remove") + " 45 минут")
        XCTAssertEqual(QuickPresetEdit.editLabel(90, row: .keepAwake), L10n.text("Change") + " 1 час 30 минут")
        XCTAssertEqual(QuickPresetEdit.removeLabel(50, row: .sleepAtCharge), L10n.text("Remove") + " 50 процентов")
        XCTAssertEqual(QuickPresetEdit.chipLabel(90, row: .sleepTimer), "1 ч 30 мин")
        XCTAssertEqual(QuickPresetEdit.chipLabel(90, row: .overviewAwake), "1 ч 30", "the Overview strip's narrow form")
        setLanguage("en")
        XCTAssertEqual(QuickPresetEdit.removeLabel(45, row: .sleepTimer), "Remove 45 minutes")
        XCTAssertEqual(QuickPresetEdit.editLabel(60, row: .sleepTimer), "Change 1 hour")
    }

    func testPreviewFollowsTheGroupBeingEdited() {
        XCTAssertEqual(QuickPresetsPreview.surface(for: .sleepTimer), .sleepTimer)
        XCTAssertEqual(QuickPresetsPreview.surface(for: .sleepAtCharge), .sleepTimer)
        XCTAssertEqual(QuickPresetsPreview.surface(for: .keepAwake), .keepAwake)
        XCTAssertEqual(QuickPresetsPreview.surface(for: .awakeUntilCharge), .keepAwake)
        XCTAssertEqual(QuickPresetsPreview.surface(for: .overviewAwake), .overview)
    }

    // MARK: Render

    /// Editor (Presets with the inline row open, Presets, Blocks) and the quick menu with two pill rows, RU/EN × light/dark.
    /// Writes PNGs when `TILVERO_RENDER_OUT` is set (display must be awake; windows flash on screen).
    func testQuickMenuEditorGallery() async throws {
        let fixture = try await WindowFixture.make()
        defer { fixture.cleanup() }
        let model = fixture.model
        model.quickPresets.replace(QuickPresets(sleepTimer: [15, 30, 45, 90], keepAwake: QuickPresets.defaults.keepAwake,
                                                overviewAwake: QuickPresets.defaults.overviewAwake,
                                                sleepAtCharge: [60, 40, 20, 10, 5], awakeUntilCharge: QuickPresets.defaults.awakeUntilCharge))
        let output = ProcessInfo.processInfo.environment["TILVERO_RENDER_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        func capture(_ window: NSWindow, _ name: String) throws {
            guard let output else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l\(window.windowNumber)", output.appendingPathComponent(name).path]
            try process.run(); process.waitUntilExit()
        }
        let draft = QuickPresetDurationDraft(row: .sleepTimer, index: 3, hours: "1", minutes: "30")
        for language in ["ru", "en"] {
            setLanguage(language, model: model)
            for dark in [false, true] {
                let variants: [(String, QuickMenuSettingsEditor.Page, QuickPresetDurationDraft?)] =
                    [("presets-edit", .presets, draft), ("presets", .presets, nil), ("blocks", .blocks, nil),
                     ("presets-overview", .presets, QuickPresetDurationDraft(row: .overviewAwake, index: 3, hours: "1", minutes: "30"))]
                for (name, page, presetDraft) in variants {
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 900),
                                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                          backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    MainWindowController.configure(window)
                    let theme = WindowTheme.resolve(dark: dark, reduceTransparency: false, increaseContrast: false)
                    let host = NSHostingView(rootView: NavigationStack {
                        ScrollView {
                            QuickMenuSettingsEditor(model: model, page: page, presetDraft: presetDraft)
                                .padding(WindowTheme.pagePadding)
                        }
                        .navigationTitle(L10n.text("Settings"))
                    }
                    .background { WindowCanvas().ignoresSafeArea() }
                    .tint(WindowTheme.accent)
                    .environment(\.windowTheme, theme)
                    .environment(\.locale, L10n.locale)
                    .font(.system(size: 13)))
                    host.sceneBridgingOptions = [.title, .toolbars]
                    window.contentView = host
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.setFrame(NSRect(x: 60, y: 60, width: 1000, height: 900), display: true)
                    window.makeKeyAndOrderFront(nil)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    try? await Task.sleep(for: .seconds(1.2))
                    try capture(window, "editor-\(name)-\(language)-\(dark ? "dark" : "light").png")
                    window.close()
                }

                // The quick menu itself with two timer pill rows (four presets + «Своё»).
                let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: QuickPanelMetrics.width, height: 700),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                let quick = NSHostingView(rootView: QuickPanel(model: model, maximumHeight: 900, section: .awake)
                    .background(.regularMaterial))
                panel.contentView = quick
                panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                panel.setContentSize(quick.fittingSize)
                panel.setFrameOrigin(NSPoint(x: 1100, y: 100))
                panel.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(1.0))
                try capture(panel, "quick-menu-two-rows-\(language)-\(dark ? "dark" : "light").png")
                panel.close()
            }
        }
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion, "rendering never starts a control")
        XCTAssertFalse(model.sleepTimer.isActive)
        XCTAssertFalse(model.sleepAtCharge.isArmed)
        XCTAssertEqual(model.quickPresets[.sleepTimer], [15, 30, 45, 90], "the open draft is never saved by rendering")
    }
}
