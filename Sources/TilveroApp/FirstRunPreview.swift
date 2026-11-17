// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI

/// `--first-run-preview` (and the dedicated "Tilvero First Run" app): play the real first-run UI safely. Never for a
/// production identity. A monitoring-only session with an isolated preference suite and a temporary history store,
/// a fake administrator dialog, a fake login item and a fake permission check: it never touches charging, fans,
/// sleep, the real login item, sudo, the production preferences or the installed app. Its Terminal route opens a
/// harmless, clearly labelled demo script that only prints text and writes one file in its own temporary folder.
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

    /// What the fake dialog / fake Terminal check answers (chosen in the debug panel).
    enum Outcome: String, CaseIterable, Identifiable { case success, cancel, error, timeout; var id: String { rawValue } }

    @MainActor final class Controls: ObservableObject {
        @Published var outcome: Outcome = .success
        @Published var loginNeedsApproval = false
        @Published var lidRefused = false
        @Published var forceHiddenIcon = false
        /// Open the real Terminal with the demo script (off: the result is simulated after two seconds).
        @Published var realTerminal = true
        @Published var dark = false
    }

    /// Stands in for the macOS dialog: waits, then answers what the debug panel says. Cancelling ends it like a dismiss.
    struct FakeExecutor: AdministratorScriptExecuting {
        let outcome: @Sendable () async -> Outcome
        func run(script: String, prompt: String) async -> AdministratorScriptOutcome {
            do { try await Task.sleep(for: .seconds(1.6)) } catch { return .cancelled }
            switch await outcome() {
            case .success: return .succeeded
            case .cancel: return .cancelled
            case .error: return .failed(7)
            case .timeout:
                do { try await Task.sleep(for: .seconds(3600)) } catch { return .cancelled }
                return .cancelled
            }
        }
    }

    /// The preview never asks sudo: "present" is whatever the forced outcome says.
    struct FakeProbe: PrivilegedRuleProbing {
        let present: @Sendable () async -> Set<PrivilegedFeature>?
        func passwordless() async -> Set<PrivilegedFeature>? { await present() }
    }

    /// Writes the demo file like the real route, then either opens it in Terminal or writes its result itself.
    @MainActor struct DemoTerminal: TerminalScriptOpening {
        let controls: Controls
        func open(_ text: String) async -> URL? {
            if controls.realTerminal { return await NativeTerminalOpener().open(text) }
            guard let file = try? TerminalCommandFile.prepare(text, base: FileManager.default.temporaryDirectory) else { return nil }
            let folder = file.deletingLastPathComponent()
            if let code = FirstRunPreview.demoCode(controls.outcome) {
                Task.detached {
                    try? await Task.sleep(for: .seconds(2))
                    try? "\(code)\n".write(to: folder.appendingPathComponent(TerminalCommandFile.resultName), atomically: true, encoding: .utf8)
                }
            }
            return folder
        }
    }

    /// What the demo script writes as its result: success 0, error 1 (as a wrong password would); nothing for cancel
    /// and timeout (the window waits until "Cancel" or its waiting time ends).
    static func demoCode(_ outcome: Outcome) -> Int32? {
        switch outcome { case .success: 0; case .error: 1; case .cancel, .timeout: nil }
    }

    /// The harmless demo `.command`: prints a PREVIEW banner and the root script the real app would run, waits for
    /// Return, writes the result next to itself. No sudo, no pmset, no write outside its own temporary folder.
    static func demoCommandText(rootScript: String, code: Int32?) -> String {
        let finish = code.map { ["printf '%s\\n' \($0) > \"${0%/*}/result\""] } ?? []
        return ([
            "#!/bin/sh",
            "# TILVERO FIRST RUN PREVIEW: a harmless demo. It only prints text; nothing runs as root, nothing is changed.",
            "cd / || exit 1",
            "printf '%s\\n' '=== TILVERO FIRST RUN PREVIEW (demo: nothing is changed) ===' '' 'The real app runs this as root after sudo asks for your password:' ''",
            "/bin/cat <<'\(TerminalCommandText.marker)'",
            rootScript,
            TerminalCommandText.marker,
            "printf '%s\\n' '' 'Press Return to finish the demo.'",
            "read answer",
        ] + finish + [
            "printf '%s\\n' 'Demo finished. You can close this window.'",
        ]).joined(separator: "\n") + "\n"
    }

    @MainActor static func installer(controls: Controls, defaults: UserDefaults) -> PrivilegedRuleInstaller {
        let box = OutcomeBox(controls: controls)
        return PrivilegedRuleInstaller(
            executor: FakeExecutor(outcome: { await box.outcome() }), terminal: DemoTerminal(controls: controls),
            probe: FakeProbe(present: { await box.outcome() == .success ? Set(PrivilegedFeature.allCases) : [] }),
            defaults: defaults, fileExists: { _ in controls.outcome == .success }, signature: { "preview" },
            terminalTimeout: 25,
            commandBuilder: { _, root in FirstRunPreview.demoCommandText(rootScript: root, code: FirstRunPreview.demoCode(controls.outcome)) })
    }

    /// Reads the debug choice from any context.
    final class OutcomeBox: Sendable {
        private let controls: Controls
        init(controls: Controls) { self.controls = controls }
        func outcome() async -> Outcome { await MainActor.run { controls.outcome } }
    }

    @MainActor static func ports(controls: Controls, defaults: UserDefaults, installer: PrivilegedRuleInstaller,
                                       applyOverviewDefaults: @escaping () -> Void = {}) -> FirstRunPorts {
        FirstRunPorts(
            markIntroduced: { FirstRunDecision.markIntroduced(defaults) },
            setHistory: { defaults.set($0, forKey: "historyEnabled") },
            setLogin: { on in on ? (controls.loginNeedsApproval ? .requiresApproval : .enabled) : nil },
            openLoginItemsSettings: {},
            requestPermission: { features, route in await installer.install(features, route: route) },
            commandText: { installer.commandText(.install($0)) },
            nudge: { installer.nudge() },
            observeLateGrant: { handler in installer.observeLateSuccess { if case .install(let f) = $0 { handler(f) } } },
            turnOnLid: { !controls.lidRefused },
            applyOverviewDefaults: applyOverviewDefaults)
    }
}

/// Small debug panel of the preview: restart, jump to any step, outcomes, speed, Reduce Motion, appearance.
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
                ForEach(FirstRunStep.allCases.filter { $0 != .applying && $0 != .finished }, id: \.self) { step in
                    Button(step.rawValue) { jump(step) }.controlSize(.small)
                }
            }
            Divider()
            Picker("Password", selection: $controls.outcome) {
                ForEach(FirstRunPreview.Outcome.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Toggle("Terminal route opens the real Terminal (demo script)", isOn: $controls.realTerminal)
            Toggle("Login needs approval", isOn: $controls.loginNeedsApproval)
            Toggle("Lid option refused", isOn: $controls.lidRefused)
            Toggle("Icon hidden (no room)", isOn: $controls.forceHiddenIcon)
            Picker("Speed", selection: $session.speed) { Text("0.25×").tag(0.25); Text("0.5×").tag(0.5); Text("1×").tag(1.0) }.pickerStyle(.segmented)
            Toggle("Reduce Motion", isOn: $session.forceReduceMotion)
            Toggle("Dark appearance", isOn: $controls.dark)
                .onChange(of: controls.dark) { _, dark in NSApp.appearance = dark ? NSAppearance(named: .darkAqua) : nil }
        }
        .padding(16).frame(width: 320)
    }
}
