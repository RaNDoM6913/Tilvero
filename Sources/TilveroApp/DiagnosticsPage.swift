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
    /// "Sleep normal" only after a real read; unread, the row says only what is certain: Tilvero holds nothing.
    static func lidValueKey(isOn: Bool, needsRecovery: Bool, systemSleepDisabled: Bool, systemSleepKnown: Bool = true) -> String {
        if needsRecovery { return "Needs restoring" }
        if isOn { return "Held (lid sleep)" }
        if systemSleepDisabled { return "Sleep disabled in macOS" }
        return systemSleepKnown ? "Sleep normal (lid sleep)" : "Not held (lid sleep)"
    }
}

/// Diagnostics page of the main window (direction C): lead, macOS charging rows, admin controls, system sleep
/// (read-only), data. Actions appear only while they apply and are the ones the previous page called, under the same
/// conditions; nothing here reads or writes the system on appearance.
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

// MARK: macOS charging

/// The macOS charge limit as rows (limit, verified levels, the macOS settings), and the existing actions only while
/// they apply: restore a limit Tilvero still owns, validate when nothing is validated yet. The explanations live in (i).
@MainActor private struct DiagnosticsChargeTile: View {
    var model: TilveroModel
    var body: some View {
        let native = model.nativeCharge
        let state = native.presentation()
        let status = state.pendingPurpose == .read ? nil : NativeChargeStatusPanel(model: model).statusText(state)
        let pending = state.pendingTarget ?? state.restorationTarget
        let restores = state.hasOwnership || native.recoveryRequired || native.restorationPending
        let validates = !native.admitted && !native.recoveryRequired && !native.awaitingDiscovery
        let blocked = model.isApplying || native.isBusy || native.isQualifying || state.pendingPurpose != nil
        // The registered `pmset` manual limit when the native setting is not readable (the Charging page's fallback).
        let manualLimit: Int? = {
            guard let observation = model.systemChargeLimit, observation.isFresh(), let limits = observation.limits,
                  !limits.manualLimitIsConflicting else { return nil }
            return limits.manualLimit
        }()
        VStack(alignment: .leading, spacing: 8) {
            DiagnosticsHeading(title: L10n.text("macOS charging"),
                               info: DiagnosticsChargeRows.infoKeys.map(L10n.text), id: "diagnostics-charge-info")
            WindowRowsTile(rows: [
                WindowRow(id: "limit", label: L10n.text("Charge limit"),
                          value: DiagnosticsChargeRows.limitText(preference: state.currentPreference.map { ($0.enabled, $0.target) },
                                                                 reported: native.currentReportedTarget ?? manualLimit)),
                WindowRow(id: "verified", label: L10n.text(native.admitted && !native.hasValidationProof ? "Available (charge limits)" : "Verified (charge limits)"),
                          value: DiagnosticsChargeRows.verifiedText(native.admitted ? native.authorizedPersistentTargets : []),
                          dim: !native.admitted),
                WindowRow(id: "settings", label: L10n.text("Charging settings in macOS"), value: "",
                          action: { model.openBatterySettings() }),
            ])
            if let status {
                Text(L10n.text(status)).font(.callout)
                    .foregroundStyle(state.requiresGlobalAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
                    .accessibilityIdentifier("diagnostics-charge-status")
            }
            if let pending {
                Text(L10n.text(state.pendingTarget == nil ? "Restoration pending" : "Pending charging target")
                     + " · " + L10n.text("Waiting for discharge below") + " \(pending)%")
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            if restores || validates {
                HStack(spacing: 10) {
                    if restores {
                        Button(L10n.text("Restore previous macOS limit")) { model.releaseControl() }
                            .buttonStyle(.borderedProminent).disabled(blocked)
                            .accessibilityIdentifier("diagnostics-restore-limit")
                    }
                    if validates {
                        Button(L10n.text("Validate 80–100%…")) { model.qualifyNativeCharge() }
                            .disabled(blocked || !native.canRequestQualification)
                            .accessibilityIdentifier("diagnostics-validate-limit")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 4)
            }
        }
    }
}

/// Values of the charge rows (pure, testable).
enum DiagnosticsChargeRows {
    static let infoKeys = [
        "Validation writes each of the other verified limits in turn and restores your setting, after a confirmed persistent baseline and a battery level below 80%.",
        "Lower targets wait for natural discharge.",
        "Registered requests do not prove an exact cutoff. macOS may occasionally charge to 100% for calibration.",
    ]

    static func percent(_ value: Int) -> String { (Double(value) / 100).formatted(.percent.locale(L10n.locale)) }

    /// The setting read from macOS; "—" when nothing was read (never a guess).
    static func limitText(preference: (enabled: Bool, target: Int)?, reported: Int?) -> String {
        if let preference { return preference.enabled ? percent(preference.target) : L10n.text("System managed") }
        if let reported { return percent(reported) }
        return "—"
    }

    /// Verified persistent levels: a contiguous run of the standard levels reads as a range, anything else as a list.
    static func verifiedText(_ targets: [Int]) -> String {
        let sorted = targets.sorted()
        guard let first = sorted.first, let last = sorted.last else { return L10n.text("Not checked (charge limits)") }
        let standard = NativeChargeAdmission.persistentTargets
        if sorted.count > 1, let a = standard.firstIndex(of: first), let b = standard.firstIndex(of: last),
           Array(standard[a...b]) == sorted {
            return "\(first)–" + percent(last)
        }
        return sorted.map(percent).joined(separator: ", ")
    }
}

// MARK: Admin controls

@MainActor private struct DiagnosticsAdminTile: View {
    var model: TilveroModel
    var body: some View {
        let live = model.liveControl
        let owned = live.hasOwnedSettings || live.recoveryRequired
        let helperInUse = live.registrationState == .enabled || live.registrationState == .requiresApproval
        let actions = DiagnosticsAdminActions.visible(canRegister: live.canRegister, ownsSettings: live.hasOwnedSettings,
                                                      recoveryRequired: live.recoveryRequired,
                                                      helperTargetPending: !model.usesNativeCharge && model.pendingTarget != nil,
                                                      helperEnabled: live.registrationState == .enabled)
        var info = [L10n.text("Monitoring works without a privileged helper. Control ownership and restoration are shown separately.")]
        if let reason = model.launchPolicy.monitoringReasonKey { info.append(L10n.text(reason)) }
        return VStack(alignment: .leading, spacing: 8) {
            DiagnosticsHeading(title: L10n.text("Admin controls"), info: info, id: "diagnostics-admin-info")
            WindowRowsTile(rows: [
                WindowRow(id: "helper", label: L10n.text("Helper"),
                          value: helperInUse ? model.helperStatusText : L10n.text("Not used (helper)"),
                          dim: live.registrationState != .enabled),
                WindowRow(id: "owned", label: L10n.text("App-owned settings"),
                          value: L10n.text(live.recoveryRequired ? "Need restoration" : owned ? "In use (owned settings)" : "None (owned settings)")),
            ])
            // Helper messages only while the helper is part of the picture (release builds have no qualified control).
            if helperInUse || owned, !model.launchPolicy.monitoringOnly, let message = live.message {
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
                                                 systemSleepDisabled: lid.systemSleepDisabled, systemSleepKnown: lid.systemSleepKnown)
        return VStack(alignment: .leading, spacing: 8) {
            DiagnosticsHeading(title: L10n.text("System sleep"),
                               info: LidSleepOverrideRow.infoKeys(for: .keepAwake).map(L10n.text),
                               id: "diagnostics-sleep-info")
            WindowRowsTile(rows: [WindowRow(id: "lid", label: L10n.text("With lid closed"), value: L10n.text(key))])
        }
        .task { await lid.checkSystemSleep() }   // one `pmset -g` read, like the Sleep page (throttled, never a write)
    }
}

// MARK: Data

@MainActor private struct DiagnosticsReadingsTile: View {
    var model: TilveroModel
    var body: some View {
        let counts = DiagnosticsSummary.fieldCounts(model.snapshot.catalog)
        let locale = L10n.locale
        let value = counts.readable.formatted(.number.locale(locale)) + " / " + counts.total.formatted(.number.locale(locale))
        return VStack(alignment: .leading, spacing: 8) {
            DiagnosticsHeading(title: L10n.text("Data (diagnostics)"))
            WindowRowsTile(rows: [
                WindowRow(id: "fields", label: L10n.text("Readable fields"), value: value,
                          action: { model.navigation.navigate(to: .battery(.catalog)) }),
            ])
        }
    }
}
