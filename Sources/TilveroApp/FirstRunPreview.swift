// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI

/// `--first-run-preview`: play the real first-run UI safely. Honored only in debug builds and non-production
/// identities (local prototype, laboratory). It runs a monitoring-only session with an isolated preference suite and
/// a temporary history store, a fake administrator prompt and a fake login item: it never touches charging, fans,
/// sleep, the real login item, the production preferences or the installed app.
enum FirstRunPreview {
    static let flag = "--first-run-preview"

    static func isAllowed(isProductionIdentity: Bool) -> Bool {
        #if DEBUG
        true
        #else
        !isProductionIdentity
        #endif
    }

    static func requested(arguments: [String], isProductionIdentity: Bool) -> Bool {
        arguments.contains(flag) && isAllowed(isProductionIdentity: isProductionIdentity)
    }

    /// The isolated environment: its own suite (removed at quit) and a temporary history folder.
    struct Environment {
        let suiteName: String
        let defaults: UserDefaults
        let historyURL: URL

        static func make() -> Environment {
            let name = "local.tilvero.first-run-preview.\(UUID().uuidString)"
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroFirstRunPreview-\(UUID().uuidString)", isDirectory: true)
            return Environment(suiteName: name, defaults: UserDefaults(suiteName: name)!, historyURL: root.appendingPathComponent("History.sqlite"))
        }

        func discard() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: historyURL.deletingLastPathComponent())
        }
    }

    /// Never runs `pmset`, `sudo` or `osascript`.
    struct InertLidSystem: LidSleepSystem {
        var ruleFilePresent: Bool { false }
        func readSleepDisabled() async -> Bool? { false }
        func passwordlessPathWorks() async -> Bool { false }
        func setSleepDisabledPasswordless(_ disabled: Bool) async -> Bool { false }
        func installRule() async -> Bool { false }
        func removeRule() async -> Bool { false }
        func restoreWithAuthorization() async -> Bool { false }
        func lidClosedWouldSleep() -> Bool { false }
        func requestSleep() -> Bool { false }
    }

    @MainActor static var sideEffects: TilveroModelSideEffects {
        TilveroModelSideEffects(loginStatus: { "Not enabled" }, toggleLogin: {}, openBatterySettings: {}, rawCatalog: { [] })
    }

    /// What the fake administrator prompt answers (chosen in the debug panel).
    enum PromptOutcome: String, CaseIterable, Identifiable { case success, cancel, error; var id: String { rawValue } }

    @MainActor final class Controls: ObservableObject {
        @Published var promptOutcome: PromptOutcome = .success
        @Published var loginNeedsApproval = false
        @Published var forceHiddenIcon = false
        @Published var dark = false
    }

    @MainActor static func ports(controls: Controls, defaults: UserDefaults) -> FirstRunPorts {
        FirstRunPorts(
            markIntroduced: { FirstRunDecision.markIntroduced(defaults) },
            setHistory: { defaults.set($0, forKey: "historyEnabled") },
            registerLogin: { controls.loginNeedsApproval ? .requiresApproval : .enabled },
            openLoginItemsSettings: {},
            install: { features in
                // Stands in for the macOS prompt; cancelling the task (card "Cancel") ends it like a dismissed prompt.
                do { try await Task.sleep(for: .seconds(1.6)) } catch { return .cancelled }
                switch controls.promptOutcome {
                case .success: return .granted(features)
                case .cancel: return .cancelled
                case .error: return .failed
                }
            },
            turnOnLid: {})
    }
}

/// Small debug panel of the preview: restart, jump to scenes, speed, Reduce Motion, hidden icon, prompt outcome.
struct FirstRunDebugPanel: View {
    @ObservedObject var session: FirstRunSession
    @ObservedObject var controls: FirstRunPreview.Controls
    var restart: () -> Void
    var jump: (FirstRunStep) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("First-run preview · step: \(session.step.rawValue)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            Button("Restart first run") { restart() }.keyboardShortcut("r")
            Divider()
            Text("Jump to").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                ForEach([FirstRunStep.whereIcon, .hiddenIcon, .card, .confirmPreview, .systemPrompt, .done, .declined, .bubble], id: \.self) { step in
                    Button(step.rawValue) { jump(step) }.controlSize(.small)
                }
            }
            Divider()
            Picker("Speed", selection: $session.speed) { Text("0.25×").tag(0.25); Text("0.5×").tag(0.5); Text("1×").tag(1.0) }.pickerStyle(.segmented)
            Toggle("Reduce Motion", isOn: $session.forceReduceMotion)
            Toggle("Icon hidden (notch)", isOn: $controls.forceHiddenIcon)
            Toggle("Login needs approval", isOn: $controls.loginNeedsApproval)
            Picker("Password", selection: $controls.promptOutcome) {
                ForEach(FirstRunPreview.PromptOutcome.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Toggle("Dark appearance", isOn: $controls.dark)
                .onChange(of: controls.dark) { _, dark in NSApp.appearance = dark ? NSAppearance(named: .darkAqua) : nil }
        }
        .padding(16).frame(width: 300)
    }
}
