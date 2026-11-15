// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI

/// Settings > Setup: which features run without the password, ask for them later (same installer, same two routes),
/// and take every Tilvero line out again ("Remove all Tilvero permissions", the exact inverse of the install).
@MainActor final class PrivilegedPermissionsController: ObservableObject {
    @Published private(set) var present: Set<PrivilegedFeature>?
    @Published private(set) var working: PermissionRoute?
    /// Localization key of the last result, nil when there is nothing to say.
    @Published private(set) var message: String?
    let installer: PrivilegedRuleInstaller
    private weak var model: TilveroModel?
    private var task: Task<Void, Never>?

    init(installer: PrivilegedRuleInstaller, model: TilveroModel?) {
        self.installer = installer; self.model = model
    }

    var missing: Set<PrivilegedFeature> { Set(PrivilegedFeature.allCases).subtracting(present ?? []) }
    var removalCommand: String? { installer.commandText(.remove(Set(PrivilegedFeature.allCases))) }

    /// Removing the permission under a running override or a scheduled wake would strand it: those end first.
    var removalBlocker: String? {
        guard let model else { return nil }
        if model.lidSleep.isOn { return "setup.permissions.blocked.lid" }
        if model.chargeBy.wakeConfirmed { return "setup.permissions.blocked.wake" }
        return nil
    }

    /// Read-only: `sudo -n -l` through the installer (falls back to the files when sudo cannot answer).
    func refresh() async {
        guard working == nil else { return }
        let read = await installer.presence()
        present = read ?? Set(PrivilegedFeature.allCases.filter { PrivilegedRulePresence.isPresent($0) })
    }

    func allow(route: PermissionRoute) {
        let features = missing
        guard working == nil, !features.isEmpty else { return }
        start(.install(features), route: route)
    }

    func removeAll(route: PermissionRoute) {
        guard working == nil, removalBlocker == nil else { message = removalBlocker; return }
        start(.remove(Set(PrivilegedFeature.allCases)), route: route)
    }

    func cancel() { task?.cancel() }

    func nudge() { if working == .terminal { installer.nudge() } }

    private func start(_ operation: PrivilegedOperation, route: PermissionRoute) {
        working = route; message = nil
        task = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.installer.run(operation, route: route)
            if case .succeeded = outcome, operation.isRemoval, let lid = self.model?.lidSleep {
                // The options that need the permission go off with it (nothing is running: see `removalBlocker`).
                await lid.setPreferred(false, for: .keepAwake)
                await lid.setPreferred(false, for: .scheduledSleep)
            }
            self.working = nil
            self.message = Self.message(outcome, operation: operation, route: route)
            self.model?.objectWillChange.send()
            await self.refresh()
        }
    }

    static func message(_ outcome: PrivilegedOutcome, operation: PrivilegedOperation, route: PermissionRoute) -> String? {
        switch outcome {
        case .succeeded: operation.isRemoval ? "setup.permissions.removed" : "setup.permissions.granted"
        case .cancelled: "firstRun.declined"
        case .failed(let code): route == .terminal && code == 1 ? "firstRun.failed.password" : "firstRun.failed"
        case .timedOut: "firstRun.timedOut"
        }
    }
}

struct PrivilegedPermissionsSection: View {
    @ObservedObject var controller: PrivilegedPermissionsController
    @State private var showsCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(PrivilegedFeature.allCases, id: \.self) { feature in
                HStack {
                    Label(L10n.text(feature == .lidClosed ? "firstRun.lidClosed" : "firstRun.chargeByTime"),
                          systemImage: feature == .lidClosed ? "laptopcomputer" : "alarm").font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    status(feature)
                }
            }
            if let route = controller.working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text(route == .terminal ? "firstRun.waiting.terminal" : "firstRun.waiting.system")).font(.callout)
                    Spacer(minLength: 8)
                    Button(L10n.text("firstRun.cancel")) { controller.cancel() }.controlSize(.small)
                }
            } else {
                HStack(spacing: 10) {
                    if !controller.missing.isEmpty, controller.present != nil {
                        Button(L10n.text("setup.permissions.allow")) { controller.allow(route: .systemPrompt) }
                            .controlSize(.small).accessibilityIdentifier("setup.permissions.allow")
                        Button(L10n.text("firstRun.useTerminal")) { controller.allow(route: .terminal) }
                            .buttonStyle(.link).font(.caption)
                    }
                    Spacer(minLength: 8)
                    Button(L10n.text("setup.permissions.removeAll")) { controller.removeAll(route: .systemPrompt) }
                        .controlSize(.small).disabled(controller.removalBlocker != nil)
                        .accessibilityIdentifier("setup.permissions.removeAll")
                }
            }
            if let key = controller.message ?? controller.removalBlocker {
                Text(L10n.text(key)).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("setup.permissions.message")
            }
            if let command = controller.removalCommand {
                DisclosureGroup(isExpanded: $showsCommand) {
                    VStack(alignment: .trailing, spacing: 6) {
                        ScrollView {
                            Text(command).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                        .frame(height: 140)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                        HStack {
                            Button(L10n.text("firstRun.copy")) {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
                            }.controlSize(.small)
                            Button(L10n.text("setup.permissions.removeInTerminal")) { controller.removeAll(route: .terminal) }
                                .controlSize(.small).disabled(controller.working != nil || controller.removalBlocker != nil)
                        }
                    }
                } label: {
                    Text(L10n.text("setup.permissions.removalCommand")).font(.caption)
                }
            }
        }
        .task { await controller.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in controller.nudge() }
        .accessibilityIdentifier("setup.permissions")
    }

    @ViewBuilder private func status(_ feature: PrivilegedFeature) -> some View {
        if let present = controller.present {
            Text(L10n.text(present.contains(feature) ? "setup.permissions.allowed" : "setup.permissions.notAllowed"))
                .font(.caption).foregroundStyle(present.contains(feature) ? Color.green : Color.secondary)
        } else {
            ProgressView().controlSize(.mini)
        }
    }
}
