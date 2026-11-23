// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import Combine
import SwiftUI

/// How one feature row reads on Settings › Features.
enum SettingsFeatureState: Equatable, Sendable {
    case ready, needsPermission, needsVerification, unavailableInBuild, unsupported
    /// Not read yet: «—».
    case unknown

    var titleKey: String? {
        switch self {
        case .ready: "Ready"
        case .needsPermission: "requiresPermission"
        case .needsVerification: "Needs verification"
        case .unavailableInBuild: "Unavailable in this build"
        case .unsupported: "Unsupported (feature)"
        case .unknown: nil
        }
    }
    /// Unsupported and unavailable features can never become ready here, so they do not count.
    var counts: Bool { self != .unsupported && self != .unavailableInBuild }
}

enum SettingsFeatureGroup: String, CaseIterable, Sendable {
    case everyday, admin
    var titleKey: String { self == .everyday ? "Everyday (features)" : "Needs admin password" }
}

struct SettingsFeatureRow: Identifiable, Equatable, Sendable {
    let id: String
    let titleKey: String
    let group: SettingsFeatureGroup
    let state: SettingsFeatureState
}

/// What «Разрешить…» does: the one administrator prompt of the first run, or (when no password rule is missing) the
/// existing setup action of the first feature that waits for a permission.
enum SettingsFeatureAllow: Equatable, Sendable {
    case privileged
    case setup(SetupAction)
}

enum SettingsFeatures {
    static let everyday: [SetupFeature] = [.monitoring, .nativeCharging, .keepAwake, .sleepTimer, .keyboardBacklight]

    static func state(_ item: SetupReadinessItem) -> SettingsFeatureState {
        switch item.status {
        case .ready: .ready
        case .needsOSApproval, .optional: .needsPermission
        case .needsValidation: .needsVerification
        case .needsDeveloperPreparation: .unavailableInBuild
        case .unsupported: .unsupported
        }
    }

    static func state(_ status: PrivilegedPermissionsController.Status?) -> SettingsFeatureState {
        switch status {
        case .allowed, .allowedByOtherRule: .ready
        case .notAllowed: .needsPermission
        case nil: .unknown
        }
    }

    static func titleKey(_ feature: SetupFeature) -> String {
        switch feature {
        case .monitoring: "Monitoring (feature)"
        case .nativeCharging: "Charge limit"
        case .keepAwake: "Keep Awake"
        case .sleepTimer: "Sleep timer"
        case .keyboardBacklight: "Keyboard backlight"
        case .fans: "Fan control"
        default: feature.rawValue
        }
    }

    /// Rows by group. `permissions` is nil when this session has no password rules at all (DEMO, monitoring only):
    /// then those rows are left out, as on the previous Setup page. A permission map without a feature (not read yet)
    /// shows «—».
    static func rows(readiness: SetupReadiness?,
                     permissions: [PrivilegedFeature: PrivilegedPermissionsController.Status]??) -> [SettingsFeatureRow] {
        var rows = everyday.map { feature in
            SettingsFeatureRow(id: feature.rawValue, titleKey: titleKey(feature), group: .everyday,
                               state: readiness.map { state($0.item(for: feature)) } ?? .unknown)
        }
        if let permissions {
            for feature in PrivilegedFeature.allCases {
                rows.append(SettingsFeatureRow(id: "permission." + feature.rawValue,
                                               titleKey: feature == .lidClosed ? "firstRun.lidClosed" : "firstRun.chargeByTime",
                                               group: .admin, state: state(permissions?[feature])))
            }
        }
        rows.append(SettingsFeatureRow(id: SetupFeature.fans.rawValue, titleKey: titleKey(.fans), group: .admin,
                                       state: readiness.map { state($0.item(for: .fans)) } ?? .unknown))
        return rows
    }

    struct Count: Equatable, Sendable {
        let ready: Int
        let total: Int
        let needsPermission: Int
        let needsVerification: Int
    }

    static func count(_ rows: [SettingsFeatureRow]) -> Count {
        let counted = rows.filter(\.state.counts)
        return Count(ready: counted.filter { $0.state == .ready }.count, total: counted.count,
                     needsPermission: counted.filter { $0.state == .needsPermission }.count,
                     needsVerification: counted.filter { $0.state == .needsVerification }.count)
    }

    /// «6 / 8», «Готово», «2 функции ждут разрешения». «Готово» while every everyday feature is ready (the rest are
    /// optional); otherwise «Нужна проверка». Before the first read: «—», «Нет данных».
    static func lead(_ rows: [SettingsFeatureRow], loaded: Bool, language: String = L10n.language) -> LeadDisplay {
        // Until every row is read (the admin rows wait for the permission read), no count: «—», never a partial «6 / 8».
        guard loaded, !rows.contains(where: { $0.state == .unknown }) else {
            return LeadDisplay(value: "—", status: L10n.text("No data"), tone: .secondary, detail: L10n.text("Checking setup status…"))
        }
        let count = count(rows)
        let everydayReady = rows.filter { $0.group == .everyday && $0.state.counts }.allSatisfy { $0.state == .ready }
        let detail: String
        if count.needsPermission > 0 {
            detail = waiting(count.needsPermission, language: language)
        } else if count.needsVerification > 0 {
            detail = verifying(count.needsVerification, language: language)
        } else if count.ready == count.total {
            detail = language == "ru" ? "все функции готовы" : "all features ready"
        } else {
            detail = ""
        }
        return LeadDisplay(value: "\(count.ready) / \(count.total)",
                           status: L10n.text(everydayReady ? "Ready" : "Needs verification"),
                           tone: everydayReady ? .accent : .attention, detail: detail)
    }

    /// «1 функция ждёт разрешения», «2 функции ждут разрешения», «5 функций ждут разрешения».
    static func waiting(_ count: Int, language: String) -> String {
        guard language == "ru" else { return count == 1 ? "1 feature needs permission" : "\(count) features need permission" }
        switch russianForm(count) {
        case .one: return "\(count) функция ждёт разрешения"
        case .few: return "\(count) функции ждут разрешения"
        case .many: return "\(count) функций ждут разрешения"
        }
    }

    static func verifying(_ count: Int, language: String) -> String {
        guard language == "ru" else { return count == 1 ? "1 feature needs verification" : "\(count) features need verification" }
        switch russianForm(count) {
        case .one: return "\(count) функция требует проверки"
        case .few: return "\(count) функции требуют проверки"
        case .many: return "\(count) функций требуют проверки"
        }
    }

    private enum RussianForm { case one, few, many }
    private static func russianForm(_ count: Int) -> RussianForm {
        let tens = count % 100, ones = count % 10
        if (11...14).contains(tens) { return .many }
        if ones == 1 { return .one }
        return (2...4).contains(ones) ? .few : .many
    }

    /// The one «Разрешить…»: the password rules first (the first run's single admin prompt), else the setup action of the
    /// first shown feature that waits for a permission. Nil hides the button.
    static func allow(readiness: SetupReadiness?, privilegedMissing: Bool) -> SettingsFeatureAllow? {
        if privilegedMissing { return .privileged }
        guard let readiness else { return nil }
        for feature in everyday + [.fans] {
            let item = readiness.item(for: feature)
            guard state(item) == .needsPermission else { continue }
            if item.actions.contains(.registerHelper) { return .setup(.registerHelper) }
            if item.actions.contains(.openApprovalSettings(feature)) { return .setup(.openApprovalSettings(feature)) }
        }
        return nil
    }
}

/// Settings › Features (the former Setup page): readiness by group and one «Разрешить…». Reads through the existing
/// `SetupActionCoordinator` (read-only refresh) and acts only through its actions or the first run's permission
/// controller.
@MainActor struct SettingsFeaturesPane: View {
    var model: TilveroModel
    @State private var readiness: SetupReadiness?
    @State private var busy = false
    @State private var issue: String?

    var body: some View {
        Group {
            if let permissions = model.privilegedPermissions {
                SettingsFeaturesPermissionsHost(controller: permissions, readiness: readiness, busy: busy, issue: issue,
                                                perform: perform)
            } else {
                SettingsFeaturesContent(rows: SettingsFeatures.rows(readiness: readiness, permissions: nil),
                                        loaded: readiness != nil,
                                        allow: SettingsFeatures.allow(readiness: readiness, privilegedMissing: false),
                                        busy: busy, message: issue, perform: { perform($0) })
            }
        }
        .task { await refresh() }
        .onReceive(model.changes.debounce(for: .milliseconds(250), scheduler: RunLoop.main)) { _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let updated = await model.setupCoordinator.refresh()
        if !Task.isCancelled, readiness != updated { readiness = updated }
    }

    /// The previous Setup page's `perform`: one action at a time, readiness from the result, issue text on failure.
    private func perform(_ allow: SettingsFeatureAllow) {
        guard case .setup(let action) = allow, !busy else { return }
        busy = true
        issue = nil
        Task {
            defer { busy = false }
            let result = await model.setupCoordinator.perform(action)
            readiness = result.readiness
            switch result.outcome {
            case .performed, .alreadySatisfied: break
            case .unavailable: issue = L10n.text("This action is no longer available. Check the updated status.")
            case .busy: issue = L10n.text("Another setup action is in progress.")
            case .failed(let message):
                let title = L10n.text("The setup action could not be completed.")
                issue = message.isEmpty ? title : title + " " + L10n.text(message)
            }
        }
    }
}

/// Observes the permission controller (its own view, so only it re-renders on a permission change).
@MainActor private struct SettingsFeaturesPermissionsHost: View {
    @ObservedObject var controller: PrivilegedPermissionsController
    let readiness: SetupReadiness?
    let busy: Bool
    let issue: String?
    let perform: @MainActor (SettingsFeatureAllow) -> Void

    var body: some View {
        let statuses: [PrivilegedFeature: PrivilegedPermissionsController.Status]? = controller.present == nil ? nil
            : Dictionary(uniqueKeysWithValues: PrivilegedFeature.allCases.map { ($0, controller.status($0)) })
        let missing = controller.present != nil && !controller.missing.isEmpty
        SettingsFeaturesContent(rows: SettingsFeatures.rows(readiness: readiness, permissions: .some(statuses)),
                                loaded: readiness != nil,
                                allow: SettingsFeatures.allow(readiness: readiness, privilegedMissing: missing),
                                busy: busy || controller.working != nil,
                                waitingForSystem: controller.working != nil,
                                message: controller.message.map(L10n.text) ?? issue,
                                canRemove: controller.canRemove,
                                perform: { allow in
                                    if allow == .privileged { controller.allow(route: .systemPrompt) } else { perform(allow) }
                                },
                                cancel: { controller.cancel() },
                                removeAll: { controller.removeAll(route: .systemPrompt) })
            .task { await controller.refresh() }
    }
}

/// Lead, rows by group and the buttons (value input only, so a render can show any state).
struct SettingsFeaturesContent: View {
    let rows: [SettingsFeatureRow]
    let loaded: Bool
    let allow: SettingsFeatureAllow?
    var busy = false
    var waitingForSystem = false
    var message: String?
    var canRemove = false
    let perform: @MainActor (SettingsFeatureAllow) -> Void
    var cancel: @MainActor () -> Void = {}
    var removeAll: @MainActor () -> Void = {}

    var body: some View {
        SettingsScroll {
            LeadLine(lead: SettingsFeatures.lead(rows, loaded: loaded)) { EmptyView() }
            ForEach(SettingsFeatureGroup.allCases, id: \.self) { group in
                let groupRows = rows.filter { $0.group == group }
                if !groupRows.isEmpty {
                    SettingsHeading(title: L10n.text(group.titleKey),
                                    info: group == .admin ? [L10n.text("firstRun.info.what"),
                                                             L10n.text("Tilvero asks to change sleep settings without a password for the features you chose.")] : [],
                                    infoID: "settings-features-admin-info")
                    SettingsRowsTile {
                        ForEach(Array(groupRows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { SettingsRowDivider() }
                            SettingsFeatureRowView(row: row)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                if canRemove {
                    Button(L10n.text("setup.permissions.removeAll"), action: removeAll)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("settings.features.removeAll")
                }
                if let message {
                    Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.features.message")
                }
                Spacer(minLength: 8)
                if waitingForSystem {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("firstRun.waiting.system"))
                    Button(L10n.text("firstRun.cancel"), action: cancel)
                } else if let allow {
                    Button(L10n.text("setup.permissions.allow")) { perform(allow) }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                        .accessibilityIdentifier("settings.features.allow")
                }
            }
        }
    }
}

/// One feature: name left, state word right (green ready, orange waiting, tertiary unsupported). The word carries the
/// state; the colour is extra.
private struct SettingsFeatureRowView: View {
    let row: SettingsFeatureRow
    var body: some View {
        HStack(spacing: 12) {
            Text(L10n.text(row.titleKey)).lineLimit(1)
            Spacer(minLength: 12)
            Text(row.state.titleKey.map(L10n.text) ?? "—").lineLimit(1).foregroundStyle(tint)
        }
        .padding(.horizontal, 16).padding(.vertical, WindowTheme.rowVerticalPadding + 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.features.row." + row.id)
    }
    private var tint: AnyShapeStyle {
        switch row.state {
        case .ready: AnyShapeStyle(WindowTheme.accent)
        case .needsPermission, .needsVerification: AnyShapeStyle(Color.orange)
        case .unavailableInBuild, .unsupported, .unknown: AnyShapeStyle(.tertiary)
        }
    }
}
