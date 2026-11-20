// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import PowerCore

/// Inputs of the Diagnostics lead and rows, read from the model by the page. Plain values, so the rules are testable.
struct DiagnosticsInputs: Equatable, Sendable {
    /// Title key of the native charge attention when it requires global attention (nil in DEMO and when none).
    var nativeAttentionKey: String?
    var recoveryRequired = false
    var ownsSettings = false
    /// The closed-lid override may still be set after a failed restore or a crash.
    var lidNeedsRecovery = false
    /// `SleepDisabled 1` while Tilvero holds no session.
    var systemSleepDisabled = false
    /// Tilvero currently holds something on purpose (a native limit it applied, the closed-lid override).
    var appHolds = false
    var monitoringOnly = false
    var readableFields = 0
}

/// Which admin actions Diagnostics offers: exactly the previous window's conditions (privileged-controls box and the
/// page-wide recovery banner).
enum DiagnosticsAdminActions: Hashable, Sendable {
    case enable, restore, disable
    static func visible(canRegister: Bool, ownsSettings: Bool, recoveryRequired: Bool, helperTargetPending: Bool,
                        helperEnabled: Bool) -> Set<DiagnosticsAdminActions> {
        var result: Set<DiagnosticsAdminActions> = []
        if canRegister { result.insert(.enable) }
        if ownsSettings || recoveryRequired || helperTargetPending { result.insert(.restore) }
        if helperEnabled { result.insert(.disable) }
        return result
    }
}

enum DiagnosticsSummary {
    /// Same key as `LidSleepOverrideRow.sleepDisabledWarningKey` (that one is main-actor isolated).
    static let sleepDisabledWarningKey = "Mac can’t sleep with the lid closed: sleep is disabled in macOS"
    /// Localisation keys of everything that needs review, most important first (recovery › charge › sleep).
    static func items(_ input: DiagnosticsInputs) -> [String] {
        var items: [String] = []
        // Normal ownership is not a fault (the notice offers to return control); only recovery needs review.
        if input.recoveryRequired { items.append("App-owned settings require restoration") }
        if let key = input.nativeAttentionKey { items.append(key) }
        if input.lidNeedsRecovery { items.append("Closed-lid sleep needs restoring") }
        else if input.systemSleepDisabled { items.append(sleepDisabledWarningKey) }
        return items
    }

    /// «✓ Всё в порядке» or the count, «Нужно проверить» and the first item named.
    static func lead(_ input: DiagnosticsInputs) -> LeadDisplay {
        let items = items(input)
        if let first = items.first {
            return LeadDisplay(value: "\(items.count)", status: L10n.text("Needs review"), tone: .attention, detail: L10n.text(first))
        }
        var fragments: [String] = []
        if input.monitoringOnly { fragments.append(L10n.text("monitoring only")) }
        if input.readableFields > 0 { fragments.append(L10n.text("sources readable")) }
        if !input.appHolds { fragments.append(L10n.text("nothing held by the app")) }
        return LeadDisplay(value: "✓", status: L10n.text("All good"), tone: .accent, detail: fragments.joined(separator: ", "))
    }

    /// Readable catalog fields over every known field (catalog definitions plus any extra rows a raw read added).
    static func fieldCounts(_ catalog: [CatalogReading], definitions: [String] = BatteryCatalog.definitions.map(\.id)) -> (readable: Int, total: Int) {
        let readable = Set(catalog.filter { $0.availability == .available }.map(\.id)).count
        let total = Set(definitions).union(catalog.map(\.id)).count
        return (readable, total)
    }

    /// The closed-lid row value: recovery › disabled by macOS › held by the app › not held.
    static func lidValueKey(isOn: Bool, needsRecovery: Bool, systemSleepDisabled: Bool) -> String {
        if needsRecovery { return "Needs restoring" }
        if isOn { return "Held (lid sleep)" }
        if systemSleepDisabled { return "Sleep disabled in macOS" }
        return "Not held (lid sleep)"
    }
}

/// Diagnostics page of the main window (direction C): lead, macOS charging (the existing native panels), admin controls,
/// system sleep (read-only), readings and sources. Every action is the one the previous page called, under the same
/// conditions; nothing here writes on appearance except the existing read of the macOS charge limit.
@MainActor struct DiagnosticsPage: View {
    var model: TilveroModel

    var body: some View {
        let _ = RenderProbe.hit("DiagnosticsPage")
        ScrollView {
            VStack(alignment: .leading, spacing: WindowTheme.tileGap) {
                DiagnosticsLeadView(model: model)
                WindowNoticeView(model: model)
                if let reason = model.launchPolicy.monitoringReasonKey {
                    NoticeTile(symbol: "info.circle", text: L10n.text(reason), tint: .secondary)
                }
                if !model.isDemo { DiagnosticsChargeTile(model: model) }
                DiagnosticsAdminTile(model: model)
                if model.lidSleep.isAvailable { DiagnosticsSleepTile(model: model) }
                DiagnosticsReadingsTile(model: model)
            }
            .padding(WindowTheme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle(WindowSection.entry(.diagnostics).title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.prepareExport(diagnostics: true) } label: {
                    Label(L10n.text("Export diagnostics…"), systemImage: "square.and.arrow.up")
                }
                .help(L10n.text("Export diagnostics…"))
                .accessibilityIdentifier("diagnostics-export")
            }
        }
    }
}

// MARK: Lead

@MainActor private struct DiagnosticsLeadView: View {
    var model: TilveroModel
    var body: some View {
        let native = model.isDemo ? nil : model.nativeCharge.presentation()
        let lid = model.lidSleep
        var input = DiagnosticsInputs()
        input.nativeAttentionKey = native.flatMap { $0.requiresGlobalAttention ? $0.attention.titleKey : nil }
        input.recoveryRequired = model.liveControl.recoveryRequired
        input.ownsSettings = model.liveControl.hasOwnedSettings
        input.lidNeedsRecovery = lid.needsRecovery
        input.systemSleepDisabled = lid.systemSleepDisabled
        input.appHolds = (native?.hasOwnership ?? false) || lid.isOn
        input.monitoringOnly = model.launchPolicy.monitoringOnly
        input.readableFields = DiagnosticsSummary.fieldCounts(model.snapshot.catalog).readable
        return LeadLine(lead: DiagnosticsSummary.lead(input)) { EmptyView() }
    }
}

// MARK: Section heading

private struct DiagnosticsHeading: View {
    let title: String
    var info: [String] = []
    var id: String = ""
    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if !info.isEmpty { SectionInfoButton(title: title, paragraphs: info, id: id) }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4).padding(.top, 6)
    }
}

// MARK: macOS charging (the existing panels, unchanged)

@MainActor private struct DiagnosticsChargeTile: View {
    var model: TilveroModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DiagnosticsHeading(title: L10n.text("macOS charging"),
                               info: [L10n.text("Validation writes 80%, 85%, 95% and 100% in turn and restores your setting, after a confirmed persistent baseline and a battery level below 80%."),
                                      L10n.text("Lower targets wait for natural discharge.")],
                               id: "diagnostics-charge-info")
            WindowTile {
                VStack(alignment: .leading, spacing: 12) {
                    NativeChargeStatusPanel(model: model)
                    Divider()
                    SystemChargeLimitPanel(model: model)
                }
            }
        }
    }
}

// MARK: Admin controls

@MainActor private struct DiagnosticsAdminTile: View {
    var model: TilveroModel
    var body: some View {
        let live = model.liveControl
        let owned = live.hasOwnedSettings || live.recoveryRequired
        let actions = DiagnosticsAdminActions.visible(canRegister: live.canRegister, ownsSettings: live.hasOwnedSettings,
                                                      recoveryRequired: live.recoveryRequired,
                                                      helperTargetPending: !model.usesNativeCharge && model.pendingTarget != nil,
                                                      helperEnabled: live.registrationState == .enabled)
        var info = [L10n.text("Monitoring works without a privileged helper. Control ownership and restoration are shown separately.")]
        if let reason = model.launchPolicy.monitoringReasonKey { info.append(L10n.text(reason)) }
        return VStack(alignment: .leading, spacing: 8) {
            DiagnosticsHeading(title: L10n.text("Admin controls"), info: info, id: "diagnostics-admin-info")
            WindowRowsTile(rows: [
                WindowRow(id: "helper", label: L10n.text("Helper"), value: model.helperStatusText,
                          dim: live.registrationState != .enabled),
                WindowRow(id: "owned", label: L10n.text("App-owned settings"),
                          value: L10n.text(live.recoveryRequired ? "Need restoration" : owned ? "In use (owned settings)" : "None (owned settings)")),
            ])
            if !model.launchPolicy.monitoringOnly, let message = live.message {
                Text(L10n.text(message)).font(.callout).foregroundStyle(.secondary).padding(.leading, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The same three actions as before, under exactly the same conditions.
            if !actions.isEmpty {
                HStack(spacing: 10) {
                    if actions.contains(.enable) {
                        Button(L10n.text("Enable supported controls")) { model.registerHelper() }
                            .accessibilityIdentifier("diagnostics.helper.enable")
                    }
                    if actions.contains(.restore) {
                        Button(L10n.text("Restore original settings")) { model.restoreAll() }
                            .accessibilityIdentifier("diagnostics.helper.restore-original-settings")
                    }
                    if actions.contains(.disable) {
                        Button(L10n.text("Disable helper after restoration")) { model.removeHelper() }
                            .accessibilityIdentifier("diagnostics.helper.disable")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 4)
            }
        }
    }
}

// MARK: System sleep (read-only)

@MainActor private struct DiagnosticsSleepTile: View {
    var model: TilveroModel
    var body: some View {
        let lid = model.lidSleep
        let key = DiagnosticsSummary.lidValueKey(isOn: lid.isOn, needsRecovery: lid.needsRecovery,
                                                 systemSleepDisabled: lid.systemSleepDisabled)
        return VStack(alignment: .leading, spacing: 8) {
            DiagnosticsHeading(title: L10n.text("System sleep"),
                               info: LidSleepOverrideRow.infoKeys(for: .keepAwake).map(L10n.text),
                               id: "diagnostics-sleep-info")
            WindowRowsTile(rows: [WindowRow(id: "lid", label: L10n.text("With lid closed"), value: L10n.text(key))])
        }
    }
}

// MARK: Readings & sources

@MainActor private struct DiagnosticsReadingsTile: View {
    var model: TilveroModel
    var body: some View {
        let counts = DiagnosticsSummary.fieldCounts(model.snapshot.catalog)
        let locale = L10n.locale
        let value = counts.readable.formatted(.number.locale(locale)) + " / " + counts.total.formatted(.number.locale(locale))
        return VStack(alignment: .leading, spacing: 8) {
            DiagnosticsHeading(title: L10n.text("Readings & sources"))
            WindowRowsTile(rows: [
                WindowRow(id: "fields", label: L10n.text("Readable fields"), value: value,
                          action: { model.navigation.navigate(to: .battery(.catalog)) }),
                WindowRow(id: "copy", label: L10n.text("Running copy"), value: Bundle.main.bundleURL.path),
            ])
            HStack {
                Button(L10n.text("Read property inventory")) { model.inspectRawProperties() }
                    .accessibilityIdentifier("diagnostics.read-property-inventory")
                Spacer(minLength: 0)
            }
            .padding(.leading, 4)
        }
    }
}
