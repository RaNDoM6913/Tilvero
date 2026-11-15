// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI

/// `--first-run-preview`: play the real first-run UI safely. Honored only for non-production identities (local
/// prototype, laboratory, the dedicated "Tilvero First Run" app), never for a production identity. It runs a monitoring-only session with an isolated preference suite and
/// a temporary history store, a fake administrator prompt and a fake login item: it never touches charging, fans,
/// sleep, the real login item, the production preferences or the installed app.
enum FirstRunPreview {
    static let flag = "--first-run-preview"

    /// Never for a production identity, in any build configuration.
    static func isAllowed(isProductionIdentity: Bool) -> Bool { !isProductionIdentity }

    /// The dedicated "Tilvero First Run" app is always a preview; other non-production builds need the flag.
    static func requested(arguments: [String], isProductionIdentity: Bool, isPreviewIdentity: Bool = false) -> Bool {
        (arguments.contains(flag) || isPreviewIdentity) && isAllowed(isProductionIdentity: isProductionIdentity)
    }

    /// The isolated environment: one fixed suite of its own, cleared at launch and at quit (so a crashed preview never
    /// leaves extra preference files behind), and a temporary history folder.
    struct Environment {
        let suiteName: String
        let defaults: UserDefaults
        let historyURL: URL

        static let suiteName = "local.tilvero.first-run-preview"

        static func make() -> Environment {
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)   // whatever an earlier (crashed) preview left
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroFirstRunPreview-\(UUID().uuidString)", isDirectory: true)
            return Environment(suiteName: suiteName, defaults: defaults, historyURL: root.appendingPathComponent("History.sqlite"))
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
            turnOnLid: { true })
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
