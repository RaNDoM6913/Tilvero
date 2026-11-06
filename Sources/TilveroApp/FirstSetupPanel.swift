// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import Combine
import SwiftUI

@MainActor struct FirstSetupPanel: View {
    @ObservedObject var model: TilveroModel
    @State private var readiness: SetupReadiness?
    @State private var busy = false
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("First-time setup"))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(L10n.text("You can monitor your Mac now and set up optional features whenever you need them."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let readiness {
                group("Monitoring and everyday tools", symbol: "checkmark.circle") {
                    rows([.monitoring, .keyboardBacklight, .keepAwake, .sleepTimer], in: readiness)
                }
                group("Additional features", symbol: "slider.horizontal.3") {
                    rows([.nativeCharging, .fans, .helperPowerModes, .closedLid], in: readiness)
                }
                group("Your choices", symbol: "person.crop.circle") {
                    Toggle(L10n.text("Save battery history"), isOn: Binding(
                        get: { readiness.inputs.historyEnabled },
                        set: { perform(.setHistoryEnabled($0)) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(busy || !readiness.item(for: .history).actions.contains(.setHistoryEnabled(!readiness.inputs.historyEnabled)))
                    .accessibilityIdentifier("setup.history")
                    Text(L10n.text("Battery history is stored locally. You can change this choice later in History settings."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    row(.launchAtLogin, in: readiness, initiallyExpanded: true)
                    Divider()
                    rows([.updateInstallation, .updateChecks], in: readiness)
                }
            } else {
                ProgressView(L10n.text("Checking setup status…"))
                    .controlSize(.small)
                    .accessibilityIdentifier("setup.loading")
            }

            if let issue {
                Label(issue, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("setup.issue")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    refreshButton
                    Spacer(minLength: 8)
                    continueButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    refreshButton
                    continueButton
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("setup.checklist")
        .task { await refresh() }
        .onReceive(model.objectWillChange.debounce(for: .milliseconds(250), scheduler: RunLoop.main)) { _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private var refreshButton: some View {
        Button(L10n.text("Refresh setup status")) { Task { await refresh(clearIssue: true) } }
            .disabled(busy)
            .accessibilityIdentifier("setup.refresh")
    }

    private var continueButton: some View {
        Button(L10n.text("Continue monitoring")) {
            model.markSetupReviewed()
            model.selectedSection = .overview
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("setup.continue")
    }

    private func group<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8, content: content)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(L10n.text(title), systemImage: symbol)
                .font(.callout.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func rows(_ features: [SetupFeature], in readiness: SetupReadiness) -> some View {
        ForEach(features) { row($0, in: readiness) }
    }

    private func row(_ feature: SetupFeature, in readiness: SetupReadiness, initiallyExpanded: Bool = false) -> some View {
        FirstSetupRow(
            item: readiness.item(for: feature),
            currentTarget: feature == .nativeCharging ? model.nativeCharge.currentReportedTarget : nil,
            storedTarget: feature == .nativeCharging ? model.nativeCharge.diagnosticStoredTarget : nil,
            busy: busy,
            initiallyExpanded: initiallyExpanded,
            perform: perform
        )
    }

    private func refresh(clearIssue: Bool = false) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if clearIssue { issue = nil }
        let updated = await model.setupCoordinator.refresh()
        if !Task.isCancelled, readiness != updated { readiness = updated }
    }

    private func perform(_ action: SetupAction) {
        guard !busy else { return }
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

@MainActor private struct FirstSetupRow: View {
    let item: SetupReadinessItem
    let currentTarget: Int?
    let storedTarget: Int?
    let busy: Bool
    let perform: (SetupAction) -> Void
    @State private var expanded: Bool

    init(item: SetupReadinessItem, currentTarget: Int?, storedTarget: Int?, busy: Bool,
         initiallyExpanded: Bool, perform: @escaping (SetupAction) -> Void) {
        self.item = item
        self.currentTarget = currentTarget
        self.storedTarget = storedTarget
        self.busy = busy
        self.perform = perform
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                detail(FirstSetupCopy.reason(item))
                if let storedTarget {
                    detail(L10n.text("Saved target reported by macOS") + ": \(storedTarget)%", localized: true)
                    detail("This diagnostic value is not a confirmed active limit; its source freshness is unknown.")
                    detail("The return time is unavailable here. Check the charging mode in macOS settings.")
                }
                ForEach(item.actions) { action in
                    if let title = FirstSetupCopy.action(action) {
                        Button(L10n.text(title)) { perform(action) }
                            .controlSize(.small)
                            .disabled(busy)
                            .accessibilityIdentifier("setup.action." + action.id)
                    }
                }
            }
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    title.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    status.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 4) {
                    title
                    status
                }
            }
        }
        .disclosureGroupStyle(ProductDisclosureStyle())
        .accessibilityIdentifier("setup.row." + item.feature.rawValue)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(L10n.text(FirstSetupCopy.title(item.feature)), systemImage: FirstSetupCopy.symbol(item.feature))
                .font(.callout.weight(.medium))
            if let currentTarget {
                detail(L10n.text("Current target reported by macOS") + ": \(currentTarget)%", localized: true)
            }
        }
    }

    private var status: some View {
        Text(L10n.text(FirstSetupCopy.status(item.status)))
            .font(.caption)
            .foregroundStyle(statusColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var statusColor: Color {
        switch item.status {
        case .ready: .green
        case .needsOSApproval, .needsValidation: .orange
        case .optional, .unsupported, .needsDeveloperPreparation: .secondary
        }
    }

    private func detail(_ text: String, localized: Bool = false) -> some View {
        Text(localized ? text : L10n.text(text))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private enum FirstSetupCopy {
    static func title(_ feature: SetupFeature) -> String {
        switch feature {
        case .monitoring: "Battery and power monitoring"
        case .nativeCharging: "Charge limit"
        case .fans: "Fans"
        case .helperPowerModes: "System power modes"
        case .keyboardBacklight: "Keyboard backlight"
        case .keepAwake: "Keep Awake"
        case .sleepTimer: "Sleep timer"
        case .closedLid: "Closed-lid operation"
        case .history: "Battery history"
        case .launchAtLogin: "Launch at login"
        case .updateChecks: "Check for new versions"
        case .updateInstallation: "Install updates"
        }
    }

    static func symbol(_ feature: SetupFeature) -> String {
        switch feature {
        case .monitoring, .history: "battery.75percent"
        case .nativeCharging: "bolt.batteryblock"
        case .fans: "fan"
        case .helperPowerModes: "slider.horizontal.3"
        case .keyboardBacklight: "light.max"
        case .keepAwake: "sun.max"
        case .sleepTimer: "timer"
        case .closedLid: "laptopcomputer"
        case .launchAtLogin: "power"
        case .updateChecks, .updateInstallation: "arrow.down.circle"
        }
    }

    static func status(_ status: SetupReadinessStatus) -> String {
        switch status {
        case .ready: "Ready"
        case .optional: "Optional"
        case .needsOSApproval: "macOS approval needed"
        case .needsValidation: "Needs verification"
        case .unsupported: "Unsupported on this Mac"
        case .needsDeveloperPreparation: "Unavailable in this build"
        }
    }

    static func reason(_ item: SetupReadinessItem) -> String {
        switch item.reason {
        case .available:
            switch item.feature {
            case .monitoring: "Battery and power readings do not require the system helper. Missing readings stay unavailable."
            case .nativeCharging: "The charge control scope has been verified on this macOS version. See Charging for the supported targets."
            case .launchAtLogin: "macOS reports that launch at login is enabled."
            case .updateInstallation: "This app can consider updates. Each update still has to pass its own checks."
            default: "Available in this session."
            }
        case .optionalChoice: "You can skip this choice and change it later."
        case .statusUnknown: "The current status is unknown. Refresh to check again."
        case .monitoringSession: "This session is limited to monitoring."
        case .nativeStateUnknown: "The current charging policy could not be confirmed. Check Charging for the latest readings and requirements."
        case .currentOSValidationRequired: "Charge control needs a separate verification on this macOS version, including restoration of the previous setting."
        case .hardwareUnsupported: "This Mac does not support the feature."
        case .capabilityUnavailable: "This feature is currently unavailable. Refresh to check again."
        case .hardwareValidationRequired: "This feature needs a compatibility and restoration check before it can be used."
        case .signedBuildRequired: "This feature needs an app and system helper with verified signatures from the same team."
        case .installationRequired: "Install Tilvero in Applications before connecting the system helper."
        case .helperNotRegistered: "You can connect the system helper for supported controls. macOS may ask you to approve it."
        case .approvalRequired: "Approve this feature in System Settings, then refresh its status."
        case .approvalDenied: "macOS reports that approval was denied. You can review this choice in System Settings."
        case .helperConnectionUnverified: "macOS reports that the helper is enabled. Its connection to Tilvero is still unverified."
        case .restorationRequired: "Restore the previous settings before enabling this feature."
        case .dedicatedTrialRequired: "Closed-lid operation requires a dedicated build and a verified recovery procedure."
        case .updateDistributionRequired: "Installing updates requires a signed distribution build and a verified update feed."
        case .updateHostIneligible: "This copy of Tilvero cannot install updates."
        case .controlsBusy: "Update installation is available only when controls are idle and recovery is complete."
        }
    }

    static func action(_ action: SetupAction) -> String? {
        switch action {
        case .refresh: "Refresh"
        case .viewRequirements(.nativeCharging): "Open Charging in Tilvero"
        case .viewRequirements: "View requirements…"
        case .openApprovalSettings: "Open System Settings…"
        case .registerHelper: "Enable supported controls"
        case .enableLogin: "Enable launch at login"
        case .setHistoryEnabled, .requestValidation: nil
        }
    }
}
