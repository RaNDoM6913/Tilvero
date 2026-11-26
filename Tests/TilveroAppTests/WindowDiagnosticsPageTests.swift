// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import AppKit
import SwiftUI
import PowerCore
import PowerPersistence
@testable import TilveroApp

@MainActor final class WindowDiagnosticsPageTests: XCTestCase {
    private var savedArguments: [String: Any] = [:]

    override func setUp() async throws {
        savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        setLanguage("en", model: nil)
    }
    override func tearDown() async throws {
        UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
    }

    private func setLanguage(_ language: String, model: TilveroModel?) {
        UserDefaults.standard.setVolatileDomain(savedArguments.merging(["language": language]) { _, value in value },
                                               forName: UserDefaults.argumentDomain)
        model?.language = language
    }

    // MARK: Lead and items

    func testAllGoodLead() {
        let lead = DiagnosticsSummary.lead(DiagnosticsInputs(readableFields: 84))
        XCTAssertEqual(lead.value, "✓")
        XCTAssertEqual(lead.status, L10n.text("All good"))
        XCTAssertEqual(lead.tone, .accent)
        XCTAssertEqual(lead.detail, L10n.text("sources readable") + ", " + L10n.text("nothing held by the app"))
    }

    func testAllGoodDetailNeverClaimsWhatIsNotTrue() {
        // No readable field: no "sources readable"; the app holds a limit: no "nothing held".
        let lead = DiagnosticsSummary.lead(DiagnosticsInputs(appHolds: true, readableFields: 0))
        XCTAssertEqual(lead.value, "✓")
        XCTAssertEqual(lead.detail, "")
        let monitoring = DiagnosticsSummary.lead(DiagnosticsInputs(monitoringOnly: true, readableFields: 3))
        XCTAssertTrue(monitoring.detail.hasPrefix(L10n.text("monitoring only")))
    }

    func testAttentionCountsAndNamesTheFirstItem() {
        var input = DiagnosticsInputs(nativeAttentionKey: NativeChargePresentation.Attention.sessionReview.titleKey)
        var lead = DiagnosticsSummary.lead(input)
        XCTAssertEqual(lead.value, "1")
        XCTAssertEqual(lead.tone, .attention)
        XCTAssertEqual(lead.status, L10n.text("Needs review"))
        XCTAssertEqual(lead.detail, L10n.text("Charging session needs review"))

        input.recoveryRequired = true
        input.systemSleepDisabled = true
        lead = DiagnosticsSummary.lead(input)
        XCTAssertEqual(lead.value, "3")
        XCTAssertEqual(lead.detail, L10n.text("App-owned settings require restoration"), "recovery comes first")
        XCTAssertEqual(DiagnosticsSummary.items(input),
                       ["App-owned settings require restoration", "Charging session needs review",
                        DiagnosticsSummary.sleepDisabledWarningKey])
    }

    func testOwnedSettingsAndRecoveryAreOneItem() {
        let items = DiagnosticsSummary.items(DiagnosticsInputs(recoveryRequired: true, ownsSettings: true))
        XCTAssertEqual(items, ["App-owned settings require restoration"])
    }

    func testLidRecoveryOutranksTheSleepDisabledWarning() {
        let items = DiagnosticsSummary.items(DiagnosticsInputs(lidNeedsRecovery: true, systemSleepDisabled: true))
        XCTAssertEqual(items, ["Closed-lid sleep needs restoring"])
    }

    func testMonitoringOnlyAloneIsNotAnAttentionItem() {
        XCTAssertTrue(DiagnosticsSummary.items(DiagnosticsInputs(monitoringOnly: true)).isEmpty)
    }

    func testSleepWarningKeyMatchesTheSleepPage() {
        XCTAssertEqual(DiagnosticsSummary.sleepDisabledWarningKey, LidSleepOverrideRow.sleepDisabledWarningKey)
    }

    // MARK: Rows

    func testFieldCountsUseAvailabilityOverEveryKnownField() {
        let now = Date()
        func reading(_ id: String, _ availability: TelemetryAvailability) -> CatalogReading {
            CatalogReading(definition: BatteryCatalog.definition(id), value: availability == .available ? .integer(1) : nil,
                           source: "fixture", keyPath: "Watts", collectedAt: now, provenance: .measured,
                           availability: availability, freshness: .fresh)
        }
        let catalog = [reading("011", .available), reading("027", .available), reading("054", .unavailable)]
        let counts = DiagnosticsSummary.fieldCounts(catalog)
        XCTAssertEqual(counts.readable, 2)
        XCTAssertEqual(counts.total, BatteryCatalog.definitions.count)
        XCTAssertEqual(DiagnosticsSummary.fieldCounts([]).readable, 0, "nothing read is 0, never a guess")
    }

    func testLidRowValue() {
        XCTAssertEqual(DiagnosticsSummary.lidValueKey(isOn: false, needsRecovery: false, systemSleepDisabled: false), "Sleep normal (lid sleep)")
        XCTAssertEqual(DiagnosticsSummary.lidValueKey(isOn: true, needsRecovery: false, systemSleepDisabled: false), "Held (lid sleep)")
        XCTAssertEqual(DiagnosticsSummary.lidValueKey(isOn: false, needsRecovery: false, systemSleepDisabled: true), "Sleep disabled in macOS")
        XCTAssertEqual(DiagnosticsSummary.lidValueKey(isOn: true, needsRecovery: true, systemSleepDisabled: true), "Needs restoring")
    }

    /// The charge tile reads as rows: a missing reading is «—», available levels read as a range or a list, none = «—».
    func testChargeRowValues() {
        XCTAssertEqual(DiagnosticsChargeRows.limitText(preference: nil, reported: nil), "—", "nothing read is «—», never a guess")
        XCTAssertEqual(DiagnosticsChargeRows.limitText(preference: (false, 80), reported: nil), DiagnosticsChargeRows.percent(100), "limit off reads as 100 %")
        XCTAssertEqual(DiagnosticsChargeRows.limitText(preference: nil, reported: 90), DiagnosticsChargeRows.percent(90))
        XCTAssertEqual(DiagnosticsChargeRows.verifiedText([100, 80, 85, 90, 95]), "80–" + DiagnosticsChargeRows.percent(100))
        XCTAssertEqual(DiagnosticsChargeRows.verifiedText([80, 95]),
                       [80, 95].map(DiagnosticsChargeRows.percent).joined(separator: ", "), "a gap is a list, not a range")
        XCTAssertEqual(DiagnosticsChargeRows.verifiedText([85]), DiagnosticsChargeRows.percent(85))
        XCTAssertEqual(DiagnosticsChargeRows.verifiedText([]), "—")
    }

    /// The page shows no developer tools (raw property read, running copy path) and no unconditional refresh buttons.
    func testDiagnosticsPageHasNoDeveloperTools() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TilveroApp/DiagnosticsPage.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for gone in ["inspectRawProperties", "Running copy", "bundleURL", "SystemChargeLimitPanel(", "\"Refresh\""] {
            XCTAssertFalse(source.contains(gone), gone)
        }
    }

    /// The helper messages that reach the UI are translated (the RU page showed "Helper is not enabled…" in English).
    func testHelperMessagesAreTranslated() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: url.appendingPathComponent("Sources/TilveroApp/LiveControlService.swift"), encoding: .utf8)
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("Sources/TilveroApp/Resources/Localizable.xcstrings"))) as! [String: Any]
        let strings = catalog["strings"] as! [String: Any]
        let pattern = try NSRegularExpression(pattern: #"(?:message = |: |\? |return )"([A-Z][^"\\]{20,})""#)
        let keys = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }.filter { !$0.contains("\\(") }
        XCTAssertGreaterThanOrEqual(keys.count, 10)
        for key in keys where key.hasSuffix(".") {
            let ru = ((strings[key] as? [String: Any])?["localizations"] as? [String: Any])?["ru"]
            XCTAssertNotNil(ru, "missing RU: \(key)")
        }
    }

    /// "Restore sleep" is offered whenever sleep is disabled or a restore failed.
    func testRestoreSleepIsOfferedWhileSleepIsDisabled() {
        XCTAssertTrue(LidSleepOverrideRow.offersRestore(needsRecovery: false, systemSleepDisabled: true))
        XCTAssertTrue(LidSleepOverrideRow.offersRestore(needsRecovery: true, systemSleepDisabled: false))
        XCTAssertFalse(LidSleepOverrideRow.offersRestore(needsRecovery: false, systemSleepDisabled: false))
    }

    /// "Sleep normal" only after a read; unread, only "Not held".
    func testLidRowSaysSleepNormalOnlyAfterARead() {
        XCTAssertEqual(DiagnosticsSummary.lidValueKey(isOn: false, needsRecovery: false, systemSleepDisabled: false, systemSleepKnown: false),
                       "Not held (lid sleep)")
        XCTAssertEqual(DiagnosticsSummary.lidValueKey(isOn: false, needsRecovery: false, systemSleepDisabled: false, systemSleepKnown: true),
                       "Sleep normal (lid sleep)")
    }

    /// A store failure reads as a translated sentence, never a Swift case name.
    func testStoreErrorsAreSentencesNotCaseNames() {
        let cases: [HistoryStoreError] = [.unavailable, .corruptRecord, .unsupportedSchema, .simulationExcluded, .migrationBackupFailed]
        for error in cases {
            let text = HistoryStoreErrorText.text(error)
            XCTAssertNotEqual(text, String(describing: error))
            XCTAssertTrue(text.contains(" "), "a sentence, not a case name: \(text)")
            XCTAssertTrue(text.hasSuffix("."), text)
        }
        XCTAssertEqual(HistoryStoreErrorText.text(CocoaError(.fileReadCorruptFile)), L10n.text(HistoryStoreErrorText.genericKey))
    }

    // MARK: Render

    /// Hosts the page in a window configured like the main window; RU/EN × light/dark PNGs when `TILVERO_RENDER_OUT`
    /// is set. Rendering never starts or changes a control.
    func testDiagnosticsGallery() async throws {
        let fixture = try await WindowFixture.make()
        defer { fixture.cleanup() }
        let model = fixture.model
        RenderProbe.isEnabled = true; RenderProbe.reset()
        defer { RenderProbe.isEnabled = false }
        let output = ProcessInfo.processInfo.environment["TILVERO_RENDER_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for language in ["ru", "en"] {
            setLanguage(language, model: model)
            for dark in [false, true] {
                let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 800, height: 720),
                                      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
                MainWindowController.configure(window)
                let host = NSHostingView(rootView:
                    WindowThemeResolver {
                        NavigationStack { DiagnosticsPage(model: model) }
                            .background { WindowCanvas().ignoresSafeArea() }
                            .tint(WindowTheme.accent)
                    }
                    .environment(\.locale, L10n.locale)
                    .font(.system(size: 13)))
                host.sceneBridgingOptions = [.title, .toolbars]
                window.contentView = host
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.setFrame(NSRect(x: 60, y: 60, width: 800, height: 760), display: true)
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                try? await Task.sleep(for: .seconds(1.5))
                XCTAssertEqual(window.title, L10n.text("Diagnostics"))
                if let output {
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l\(window.windowNumber)",
                                         output.appendingPathComponent("diagnostics-\(language)-\(dark ? "dark" : "light").png").path]
                    try capture.run(); capture.waitUntilExit()
                }
                window.close()
            }
        }
        XCTAssertGreaterThanOrEqual(RenderProbe.counts["DiagnosticsPage"] ?? 0, 1)
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
        XCTAssertFalse(model.lidSleep.isOn)
        XCTAssertNil(model.nativeCharge.observed)
        XCTAssertNil(model.exportPreview, "the export sheet opens only on the toolbar action")
    }
}

@MainActor final class WindowDiagnosticsAdminActionsTests: XCTestCase {
    /// The previous window's conditions: enable when registrable; restore when settings are owned, recovery is required
    /// or (helper path) a lower target is pending; disable when the helper is enabled. Each rule on both sides.
    func testAdminActionsMatchThePreviousWindow() {
        func visible(register: Bool = false, owns: Bool = false, recovery: Bool = false, pending: Bool = false, enabled: Bool = false) -> Set<DiagnosticsAdminActions> {
            DiagnosticsAdminActions.visible(canRegister: register, ownsSettings: owns, recoveryRequired: recovery,
                                            helperTargetPending: pending, helperEnabled: enabled)
        }
        XCTAssertEqual(visible(), [])
        XCTAssertEqual(visible(register: true), [.enable])
        XCTAssertEqual(visible(owns: true), [.restore])
        XCTAssertEqual(visible(recovery: true), [.restore])
        XCTAssertEqual(visible(pending: true), [.restore])
        XCTAssertEqual(visible(enabled: true), [.disable])
        XCTAssertEqual(visible(register: true, owns: true, enabled: true), [.enable, .restore, .disable])
    }

    func testOwnershipAloneIsNotAnItemButRecoveryIs() {
        XCTAssertTrue(DiagnosticsSummary.items(DiagnosticsInputs(ownsSettings: true)).isEmpty)
        XCTAssertEqual(DiagnosticsSummary.items(DiagnosticsInputs(recoveryRequired: true)), ["App-owned settings require restoration"])
        XCTAssertEqual(NoticeDisplay.choose(NoticeDisplay.Inputs(helperTargetPending: true))?.action, .restore)
        XCTAssertEqual(NoticeDisplay.choose(NoticeDisplay.Inputs(ownsSettings: true, helperTargetPending: true))?.action, .returnControl)
    }
}
