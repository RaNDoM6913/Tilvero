// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import AppKit
import SwiftUI
import PowerCore
@testable import TilveroApp

@MainActor final class WindowSettingsPageTests: XCTestCase {
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

    // MARK: Tabs

    func testFeaturesTabFollowsTheSetupFlag() {
        XCTAssertEqual(SettingsTabs.visible(setupPage: true), [.general, .quickPanel, .history, .updates, .setup])
        XCTAssertEqual(SettingsTabs.visible(setupPage: false), [.general, .quickPanel, .history, .updates])
        XCTAssertEqual(SettingsTabs.presented(.setup, visible: SettingsTabs.visible(setupPage: false)), .general,
                       "a remembered Features tab falls back to General where it is hidden")
        XCTAssertEqual(SettingsTabs.presented(.updates, visible: SettingsTabs.visible(setupPage: false)), .updates)
    }

    func testFeaturesHiddenInDemo() {
        let model = TilveroModel(isDemo: true, preferences: makeTestDefaults("SettingsDemo").defaults)
        defer { model.stop() }
        XCTAssertFalse(model.canShowSetup)
        XCTAssertFalse(model.features.setupPage)
        XCTAssertFalse(SettingsTabs.visible(setupPage: model.features.setupPage).contains(.setup))
        XCTAssertFalse(FeatureFlags.resolve(development: true, isDemo: true, canShowSetup: false, newWindowOverride: nil).setupPage)
    }

    func testTabTitlesUseTheRenamedKeys() {
        setLanguage("ru", model: nil)
        XCTAssertEqual(SettingsPage.allCases.map { L10n.text($0.title) }, ["Основные", "Быстрое меню", "История", "Обновления", "Функции"])
        setLanguage("en", model: nil)
        XCTAssertEqual(SettingsPage.allCases.map { L10n.text($0.title) }, ["General", "Quick menu", "History", "Updates", "Features"])
    }

    // MARK: History

    func testHistoryLeadShowsOnlyReportedValues() {
        let since = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current, year: 2026, month: 11, day: 4, hour: 12).date!
        let ru = SettingsHistory.lead(SettingsHistoryInputs(megabytes: 38, limitMegabytes: 512, since: since, enabled: true),
                                      language: "ru", locale: Locale(identifier: "ru_RU"))
        XCTAssertEqual(ru.value, "38 МБ")
        XCTAssertEqual(ru.tone, .accent)
        XCTAssertEqual(ru.detail, "из 512 МБ · с 4 ноября")
        let en = SettingsHistory.lead(SettingsHistoryInputs(megabytes: 38, limitMegabytes: 512, since: since, enabled: true),
                                      language: "en", locale: Locale(identifier: "en_US"))
        XCTAssertEqual(en.value, "38 MB")
        XCTAssertEqual(en.detail, "of 512 MB · since Nov 4")

        let unknown = SettingsHistory.lead(SettingsHistoryInputs(enabled: false), language: "en", locale: Locale(identifier: "en_US"))
        XCTAssertEqual(unknown.value, "—", "no store report is «—», never 0 MB")
        XCTAssertEqual(unknown.status, L10n.text("Recording is off"))
        XCTAssertEqual(unknown.detail, "")
        XCTAssertEqual(SettingsHistory.lead(SettingsHistoryInputs(megabytes: 0, enabled: true), language: "en").value, "0 MB",
                       "a reported empty store stays 0")
    }

    func testHistoryLeadInDemoSaysSimulationIsNotRecorded() {
        let lead = SettingsHistory.lead(SettingsHistoryInputs(megabytes: 38, limitMegabytes: 512, enabled: true, demo: true))
        XCTAssertEqual(lead.value, "—")
        XCTAssertEqual(lead.detail, L10n.text("Simulation is never stored in history"))
    }

    func testEraseAlertKeepsThePreviousWording() {
        XCTAssertEqual(SettingsHistory.eraseTitleKey, "Erase history")
        XCTAssertEqual(SettingsHistory.eraseButtonKey, "Erase history…")
        XCTAssertEqual(SettingsHistory.eraseMessageKey, "Delete local measurements? This does not change charging or cooling settings.")
        setLanguage("ru", model: nil)
        XCTAssertEqual(L10n.text(SettingsHistory.eraseButtonKey), "Удалить историю…")
    }

    // MARK: Updates

    private func release(_ version: String, kind: UpdateReleaseKind = .macApp, notes: String = "Notes") -> UpdateRelease {
        UpdateRelease(tag: "v" + version, name: "Tilvero " + version, version: version, build: "90", notes: notes,
                      releaseURL: URL(string: "https://github.com/RaNDoM6913/Tilvero/releases/tag/v" + version)!, kind: kind)
    }
    private func snapshot(_ availability: UpdateAvailability, release: UpdateRelease? = nil, source: UpdateRelease? = nil,
                          at date: Date) -> UpdateCheckSnapshot {
        UpdateCheckSnapshot(checkedAt: date, channel: .stable,
                            result: UpdateDiscoveryResult(availability: availability, release: release, sourceRelease: source))
    }

    func testUpdateStatusMatrix() {
        let now = Date()
        let update = snapshot(.appAvailable, release: release("0.8.0"), at: now)
        let current = snapshot(.current, release: release("0.7.1"), at: now)
        func status(_ phase: UpdateCheckPhase, last: UpdateCheckSnapshot? = nil, error: String? = nil) -> SettingsUpdateStatus {
            SettingsUpdates.status(SettingsUpdateInputs(installedVersion: "0.7.1", phase: phase, lastSuccess: last, installError: error))
        }
        XCTAssertEqual(status(.idle), .notChecked)
        XCTAssertEqual(status(.idle, last: current), .current, "after a relaunch the dated last result is shown")
        XCTAssertEqual(status(.succeeded(current)), .current)
        XCTAssertEqual(status(.succeeded(update)), .updateAvailable(version: "0.8.0"))
        XCTAssertEqual(status(.idle, last: update), .updateAvailable(version: "0.8.0"))
        XCTAssertEqual(status(.checking, last: update), .checking)
        XCTAssertEqual(status(.failed(.offline), last: update), .failed(.offline))
        XCTAssertEqual(status(.cancelled, last: update), .cancelled)
        XCTAssertEqual(status(.succeeded(snapshot(.sourceOnly, source: release("0.8.0", kind: .sourcePreview), at: now))), .sourceOnly)
        XCTAssertEqual(status(.succeeded(snapshot(.manual, at: now))), .manual)
        XCTAssertEqual(status(.succeeded(snapshot(.noCompatibleRelease, at: now))), .noCompatibleRelease)
        XCTAssertEqual(status(.succeeded(update), error: "Signature check failed"), .installPostponed)
        XCTAssertEqual(status(.checking, error: "Signature check failed"), .checking, "a new check shows as checking")
        XCTAssertEqual(status(.failed(.timedOut), error: "x"), .installPostponed)
    }

    func testUpdateDisplayActionsAndWords() {
        let now = Date()
        let ru = Locale(identifier: "ru_RU")
        setLanguage("ru", model: nil)
        func display(_ phase: UpdateCheckPhase, last: UpdateCheckSnapshot? = nil, error: String? = nil, qualified: Bool = true,
                     version: String? = "0.7.1") -> SettingsUpdateDisplay {
            SettingsUpdates.display(SettingsUpdateInputs(installedVersion: version, phase: phase, lastSuccess: last,
                                                         installError: error, installerQualified: qualified),
                                    now: now, language: "ru", locale: ru)
        }
        let checkedNow = "проверено сегодня " + now.formatted(.dateTime.hour().minute().locale(ru))

        let update = display(.succeeded(snapshot(.appAvailable, release: release("0.8.0"), at: now)))
        XCTAssertEqual(update.lead.value, "0.8.0")
        XCTAssertEqual(update.lead.status, L10n.text("Update available"))
        XCTAssertEqual(update.lead.tone, .accent)
        XCTAssertEqual(update.lead.detail, "установлена 0.7.1 · " + checkedNow)
        XCTAssertEqual(update.actions, [.install, .releaseNotes])
        XCTAssertEqual(display(.succeeded(snapshot(.appAvailable, release: release("0.8.0", notes: ""), at: now)), qualified: false).actions,
                       [.openRelease], "an unqualified build opens the release; no notes button without notes")

        let current = display(.succeeded(snapshot(.current, release: release("0.7.1"), at: now)))
        XCTAssertEqual(current.lead.value, "0.7.1")
        XCTAssertEqual(current.lead.status, L10n.text("Up to date"))
        XCTAssertEqual(current.lead.detail, checkedNow)
        XCTAssertEqual(current.actions, [.check])

        let checking = display(.checking)
        XCTAssertEqual(checking.lead.status, L10n.text("Checking (updates)"))
        XCTAssertEqual(checking.actions, [.cancel])

        let failed = display(.failed(.offline))
        XCTAssertEqual(failed.lead.status, L10n.text("Could not check"))
        XCTAssertEqual(failed.lead.tone, .attention)
        XCTAssertEqual(failed.lead.detail, L10n.text("The network is unavailable. Try again when you are connected."))
        XCTAssertEqual(failed.actions, [.retry])
        XCTAssertEqual(L10n.text(SettingsUpdateAction.retry.titleKey), "Повторить")

        XCTAssertEqual(display(.cancelled).lead.status, L10n.text("Cancelled (update check)"))
        XCTAssertEqual(display(.cancelled).actions, [.check])

        let source = display(.succeeded(snapshot(.sourceOnly, source: release("0.8.0", kind: .sourcePreview), at: now)))
        XCTAssertEqual(source.lead.status, L10n.text("Source code only"))
        XCTAssertEqual(source.actions, [.openRelease])
        XCTAssertEqual(source.release?.tag, "v0.8.0")
        XCTAssertEqual(SettingsUpdateAction.openRelease.titleKey, "Open Release")

        let postponed = display(.idle, error: "Подпись не прошла проверку")
        XCTAssertEqual(postponed.lead.status, "Установка отложена")
        XCTAssertEqual(postponed.lead.detail, "Подпись не прошла проверку")
        XCTAssertEqual(postponed.actions, [.diagnostics])
        XCTAssertEqual(L10n.text(SettingsUpdateAction.diagnostics.titleKey), "Диагностика")

        let never = display(.idle)
        XCTAssertEqual(never.lead.status, L10n.text("Not checked yet"))
        XCTAssertEqual(never.lead.detail, "")
        XCTAssertEqual(never.actions, [.check])

        XCTAssertEqual(display(.idle, version: nil).lead.value, "—", "an unknown installed version is «—»")
        XCTAssertEqual(display(.succeeded(snapshot(.manual, at: now))).lead.status, L10n.text("Updated manually"))
        XCTAssertEqual(display(.succeeded(snapshot(.noCompatibleRelease, at: now))).lead.status, L10n.text("No app release"))
    }

    func testCheckedTimeWords() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let now = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 11, day: 21, hour: 12).date!
        let en = Locale(identifier: "en_US")
        let yesterday = now.addingTimeInterval(-86_400)
        XCTAssertTrue(SettingsUpdates.when(now, now: now, calendar: calendar, language: "en", locale: en).hasPrefix("today "))
        XCTAssertTrue(SettingsUpdates.when(yesterday, now: now, calendar: calendar, language: "ru", locale: Locale(identifier: "ru_RU")).hasPrefix("вчера "))
        XCTAssertFalse(SettingsUpdates.when(now.addingTimeInterval(-5 * 86_400), now: now, calendar: calendar, language: "en", locale: en).hasPrefix("today"))
    }

    // MARK: Features

    private static func readiness(fans: SetupAvailability = .unsupported, keyboard: SetupAvailability = .available,
                                  helperRegistration: SetupRegistrationState = .unknown) -> SetupReadiness {
        var inputs = SetupReadinessInputs()
        inputs.nativeCharge = SetupNativeChargeInputs(availability: .available, hasCompletePersistentState: true, currentOSQualified: true)
        inputs.keyboardBacklight = keyboard
        inputs.fanAvailability = fans
        inputs.helper = SetupHelperInputs(sameTeamTrustVerified: true, installedInApplications: true,
                                          registration: helperRegistration, canRequestRegistration: true)
        return SetupReadiness(inputs: inputs)
    }

    func testReadinessCount() {
        let missing: [PrivilegedFeature: PrivilegedPermissionsController.Status] = [.lidClosed: .notAllowed, .chargeByTime: .notAllowed]
        let rows = SettingsFeatures.rows(readiness: Self.readiness(), permissions: .some(missing))
        XCTAssertEqual(rows.map(\.id), ["monitoring", "nativeCharging", "keepAwake", "sleepTimer", "keyboardBacklight",
                                        "permission.lidClosed", "permission.chargeByTime", "fans"])
        XCTAssertEqual(rows.last?.state, .unsupported)
        XCTAssertEqual(SettingsFeatures.count(rows), .init(ready: 5, total: 7, needsPermission: 2, needsVerification: 0),
                       "unsupported features do not count")
        let lead = SettingsFeatures.lead(rows, loaded: true, language: "ru")
        XCTAssertEqual(lead.value, "5 / 7")
        XCTAssertEqual(lead.status, L10n.text("Ready"))
        XCTAssertEqual(lead.tone, .accent)
        XCTAssertEqual(lead.detail, "2 функции ждут разрешения")
        XCTAssertEqual(SettingsFeatures.lead(rows, loaded: true, language: "en").detail, "2 features need permission")

        let allowed: [PrivilegedFeature: PrivilegedPermissionsController.Status] = [.lidClosed: .allowed, .chargeByTime: .allowedByOtherRule]
        let ready = SettingsFeatures.rows(readiness: Self.readiness(), permissions: .some(allowed))
        XCTAssertEqual(SettingsFeatures.count(ready), .init(ready: 7, total: 7, needsPermission: 0, needsVerification: 0))
        XCTAssertEqual(SettingsFeatures.lead(ready, loaded: true, language: "ru").detail, "все функции готовы")
    }

    func testReadinessLeadWhenEverydayNeedsVerificationOrNothingIsRead() {
        let rows = SettingsFeatures.rows(readiness: Self.readiness(keyboard: .unknown), permissions: nil)
        XCTAssertEqual(rows.map(\.id), ["monitoring", "nativeCharging", "keepAwake", "sleepTimer", "keyboardBacklight", "fans"],
                       "no password rows without a permission controller")
        let lead = SettingsFeatures.lead(rows, loaded: true, language: "ru")
        XCTAssertEqual(lead.value, "4 / 5")
        XCTAssertEqual(lead.status, L10n.text("Needs verification"))
        XCTAssertEqual(lead.tone, .attention)
        XCTAssertEqual(lead.detail, "1 функция требует проверки")

        let loading = SettingsFeatures.rows(readiness: nil, permissions: .some(nil))
        XCTAssertTrue(loading.allSatisfy { $0.state == .unknown })
        XCTAssertEqual(SettingsFeatures.lead(loading, loaded: false).value, "—")
        XCTAssertEqual(SettingsFeatures.lead(loading, loaded: false).status, L10n.text("No data"))
    }

    func testRussianPluralForms() {
        XCTAssertEqual(SettingsFeatures.waiting(1, language: "ru"), "1 функция ждёт разрешения")
        XCTAssertEqual(SettingsFeatures.waiting(3, language: "ru"), "3 функции ждут разрешения")
        XCTAssertEqual(SettingsFeatures.waiting(5, language: "ru"), "5 функций ждут разрешения")
        XCTAssertEqual(SettingsFeatures.waiting(11, language: "ru"), "11 функций ждут разрешения")
        XCTAssertEqual(SettingsFeatures.waiting(21, language: "ru"), "21 функция ждёт разрешения")
        XCTAssertEqual(SettingsFeatures.waiting(1, language: "en"), "1 feature needs permission")
    }

    func testFeatureStateMapping() {
        func item(_ status: SetupReadinessStatus) -> SetupReadinessItem {
            SetupReadinessItem(feature: .fans, status: status, reason: .available, permission: .none, actions: [])
        }
        XCTAssertEqual(SettingsFeatures.state(item(.ready)), .ready)
        XCTAssertEqual(SettingsFeatures.state(item(.needsOSApproval)), .needsPermission)
        XCTAssertEqual(SettingsFeatures.state(item(.optional)), .needsPermission)
        XCTAssertEqual(SettingsFeatures.state(item(.needsValidation)), .needsVerification)
        XCTAssertEqual(SettingsFeatures.state(item(.needsDeveloperPreparation)), .unavailableInBuild)
        XCTAssertEqual(SettingsFeatures.state(item(.unsupported)), .unsupported)
        XCTAssertEqual(SettingsFeatures.state(PrivilegedPermissionsController.Status?.none), .unknown)
    }

    func testAllowUsesTheExistingActions() {
        XCTAssertEqual(SettingsFeatures.allow(readiness: Self.readiness(), privilegedMissing: true), .privileged)
        XCTAssertNil(SettingsFeatures.allow(readiness: Self.readiness(), privilegedMissing: false), "nothing waits: no button")
        XCTAssertNil(SettingsFeatures.allow(readiness: nil, privilegedMissing: false))
        // Fans: the helper is not registered yet -> the existing «Enable supported controls» action.
        let helper = Self.readiness(fans: .available, helperRegistration: .notRegistered)
        XCTAssertEqual(SettingsFeatures.allow(readiness: helper, privilegedMissing: false), .setup(.registerHelper))
        XCTAssertTrue(helper.item(for: .fans).actions.contains(.registerHelper))
        let approval = Self.readiness(fans: .available, helperRegistration: .requiresApproval)
        XCTAssertEqual(SettingsFeatures.allow(readiness: approval, privilegedMissing: false), .setup(.openApprovalSettings(.fans)))
    }

    // MARK: Render

    private func host<Content: View>(_ content: Content, dark: Bool) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1000, height: 720),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        MainWindowController.configure(window)
        let host = NSHostingView(rootView:
            WindowThemeResolver {
                NavigationStack { content }
                    .background { WindowCanvas().ignoresSafeArea() }
                    .tint(WindowTheme.accent)
            }
            .environment(\.locale, L10n.locale)
            .font(.system(size: 13)))
        host.sceneBridgingOptions = [.title, .toolbars]
        window.contentView = host
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrame(NSRect(x: 60, y: 60, width: 1000, height: 720), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return window
    }

    private func capture(_ window: NSWindow, _ name: String, to output: URL?) throws {
        guard let output else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l\(window.windowNumber)", output.appendingPathComponent(name + ".png").path]
        try process.run(); process.waitUntilExit()
    }

    /// Every tab in a window configured like the main window; RU/EN × light/dark PNGs when `TILVERO_RENDER_OUT` is set.
    /// The fixture model has its own preference suite and history store; rendering writes no control setting.
    func testSettingsGallery() async throws {
        let fixture = try await WindowFixture.make()
        defer { fixture.cleanup() }
        let model = fixture.model
        RenderProbe.isEnabled = true; RenderProbe.reset()
        defer { RenderProbe.isEnabled = false }
        let output = ProcessInfo.processInfo.environment["TILVERO_RENDER_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        XCTAssertFalse(model.features.setupPage, "a fixture build hides Features")
        let tabs: [(SettingsPage, String)] = [(.general, "general"), (.quickPanel, "quick"), (.history, "history"), (.updates, "updates")]
        let before = (model.menuBarBatteryAppearance, model.displayStyle, model.historyEnabled, model.retentionDays,
                      model.updates.channel, model.updates.automaticallyChecks)
        for language in ["ru", "en"] {
            setLanguage(language, model: model)
            for dark in [false, true] {
                let suffix = "\(language)-\(dark ? "dark" : "light")"
                for (tab, name) in tabs {
                    model.navigation.settingsPage = tab
                    let window = host(SettingsHostPage(model: model), dark: dark)
                    try? await Task.sleep(for: .seconds(1.2))
                    XCTAssertEqual(window.title, L10n.text("Settings"))
                    try capture(window, "settings-\(name)-\(suffix)", to: output)
                    window.close()
                }
                // Features (hidden in fixture builds): the pane's content with fixture readiness.
                let rows = SettingsFeatures.rows(readiness: Self.readiness(),
                                                 permissions: .some([.lidClosed: .notAllowed, .chargeByTime: .notAllowed]))
                let features = SettingsFeaturesContent(rows: rows, loaded: true, allow: .privileged, perform: { _ in })
                    .navigationTitle(WindowSection.entry(.settings).title)
                    .toolbar { ToolbarItem(placement: .principal) { SettingsTabPicker(selection: .constant(.setup), tabs: SettingsPage.allCases) } }
                var window = host(features, dark: dark)
                try? await Task.sleep(for: .seconds(1.2))
                try capture(window, "settings-features-\(suffix)", to: output)
                window.close()
                // Updates with an available release (fixture values), to compare with the render.
                let now = Date()
                let input = SettingsUpdateInputs(installedVersion: "0.7.1",
                                                 phase: .succeeded(UpdateCheckSnapshot(checkedAt: now, channel: .stable,
                                                     result: UpdateDiscoveryResult(availability: .appAvailable, release: release("0.8.0"), sourceRelease: nil))),
                                                 installerQualified: true)
                let updates = SettingsScroll { SettingsUpdatesContent(display: SettingsUpdates.display(input), showsNotes: .constant(false), perform: { _, _ in }) }
                    .navigationTitle(WindowSection.entry(.settings).title)
                    .toolbar { ToolbarItem(placement: .principal) { SettingsTabPicker(selection: .constant(.updates), tabs: SettingsPage.allCases) } }
                window = host(updates, dark: dark)
                try? await Task.sleep(for: .seconds(1.0))
                try capture(window, "settings-updates-available-\(suffix)", to: output)
                window.close()
            }
        }
        XCTAssertGreaterThanOrEqual(RenderProbe.counts["SettingsHostPage"] ?? 0, 1)
        XCTAssertTrue(before == (model.menuBarBatteryAppearance, model.displayStyle, model.historyEnabled, model.retentionDays,
                                 model.updates.channel, model.updates.automaticallyChecks), "rendering changes no setting")
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
        XCTAssertFalse(model.lidSleep.isOn)
        XCTAssertNil(model.nativeCharge.observed)
    }

    /// The History tab carries the erase confirmation: closed by default, shown as a sheet when requested (the state the
    /// «Удалить историю…» button sets); presenting it erases nothing.
    func testEraseAlertIsPresentedFromTheHistoryTab() async throws {
        let fixture = try await WindowFixture.make()
        defer { fixture.cleanup() }
        let model = fixture.model
        let samples = model.history.count
        XCTAssertGreaterThan(samples, 0)

        let closed = host(SettingsHistoryPane(model: model), dark: false)
        try? await Task.sleep(for: .seconds(1.0))
        XCTAssertNil(closed.attachedSheet, "no alert until the button is pressed")
        closed.close()

        let window = host(SettingsHistoryPane(model: model, confirmingErase: true), dark: false)
        defer { window.close() }
        try? await Task.sleep(for: .seconds(1.2))
        let sheet = try XCTUnwrap(window.attachedSheet, "the confirmation alert is shown")
        if let output = ProcessInfo.processInfo.environment["TILVERO_RENDER_OUT"].map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            try capture(window, "settings-history-erase-alert-en-light", to: output)
        }
        XCTAssertEqual(model.history.count, samples, "presenting the alert erases nothing")
        window.endSheet(sheet)
    }
}
