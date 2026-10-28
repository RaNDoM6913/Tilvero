import AppKit

/// Equal identifiers can name different builds. Never silently reopen another bundle.
enum AppInstancePolicy {
    enum Action: Equatable { case reopen, requireSwitch }
    static func action(current: URL, existing: URL?) -> Action {
        guard let existing else { return .requireSwitch }
        return current.resolvingSymlinksInPath().standardizedFileURL == existing.resolvingSymlinksInPath().standardizedFileURL ? .reopen : .requireSwitch
    }

    @MainActor static func mayStart(application: NSApplication, existing: [NSRunningApplication]) -> Bool {
        guard !existing.isEmpty else { return true }
        let current = Bundle.main.bundleURL
        if existing.allSatisfy({ action(current: current, existing: $0.bundleURL) == .reopen }) {
            existing.first?.activate(options: [])
            DistributedNotificationCenter.default().postNotificationName((try? ReleaseIdentity.current().reopenNotificationName) ?? Notification.Name("local.tilvero.showDetails"), object: nil)
            return false
        }
        application.setActivationPolicy(.regular)
        application.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.text("Another Tilvero copy is running")
        alert.informativeText = L10n.text("Open this copy only after the running copy quits and restores its settings.")
            + "\n\n" + L10n.text("Running copy") + ":\n" + existing.map { $0.bundleURL?.path ?? L10n.text("Unknown") }.joined(separator: "\n")
            + "\n\n" + L10n.text("Requested copy") + ":\n" + current.path
        alert.addButton(withTitle: L10n.text("Quit running copy and open this one"))
        alert.addButton(withTitle: L10n.text("Keep running copy"))
        guard alert.runModal() == .alertFirstButtonReturn else { existing.first?.activate(options: []); return false }
        for instance in existing where !instance.isTerminated { _ = instance.terminate() }
        let deadline = Date().addingTimeInterval(20)
        while existing.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard existing.allSatisfy(\.isTerminated) else {
            let blocked = NSAlert()
            blocked.messageText = L10n.text("The running copy has not quit")
            blocked.informativeText = L10n.text("Complete recovery or quit that copy, then reopen this app. No process was forced to stop.")
            blocked.runModal()
            return false
        }
        return true
    }
}
