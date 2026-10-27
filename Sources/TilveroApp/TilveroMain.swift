import AppKit
import SwiftUI
import PowerCore
import PowerTelemetry
import PowerDiagnostics
import OSLog

@main
@MainActor
struct TilveroMain {
    static func main() {
        if CommandLine.arguments.contains("--doctor") {
            do {
                let report = try DoctorReport(snapshot: MacBatteryProvider().readSnapshot()).encodedJSON()
                FileHandle.standardOutput.write(report); FileHandle.standardOutput.write(Data("\n".utf8))
            } catch { FileHandle.standardError.write(Data("Diagnostic collection failed.\n".utf8)); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-icons"), CommandLine.arguments.count > index + 1 {
            _ = NSApplication.shared
            do { try IconFixtures.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            catch { FileHandle.standardError.write(Data("Icon rendering failed.\n".utf8)); exit(1) }
            return
        }
        let application = NSApplication.shared
        if let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [])
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.tilvero.showDetails"), object: nil)
            return
        }
        let delegate = TilveroAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class TilveroAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = TilveroModel(isDemo: CommandLine.arguments.contains("--demo"))
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var detailsWindow: NSWindow?
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    private var popoverGeneration: UInt64 = 0
    private var activationGate = QuickPanelActivationGate()
    private let popoverLog = Logger(subsystem: "local.tilvero.prototype", category: "MenuPopover")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.imagePosition = .imageTrailing
        item.button?.font = NativeStatusPresentation.font(for: model.menuBarTextSize)

        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 360, height: 440)
        popover.contentViewController = NSHostingController(rootView: QuickPanel(model: model))
        popover.delegate = self

        model.openDetails = { [weak self] in self?.showDetails() }
        model.onPresentationChange = { [weak self] in self?.updateStatusItem() }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(powerChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reopenDetails), name: Notification.Name("local.tilvero.showDetails"), object: nil)
        buildMenu()
        updateStatusItem()
        model.start()
        if CommandLine.arguments.contains("--show-details") { showDetails() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            let restored = await model.prepareForTermination()
            if !restored {
                let alert = NSAlert(); alert.messageText = L10n.text("Recovery required")
                alert.informativeText = model.liveControl.message ?? L10n.text("Operation failed")
                alert.runModal()
                model.selectedSection = .diagnostics; showDetails()
            }
            sender.reply(toApplicationShouldTerminate: restored)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        stopPopoverEventMonitors()
        model.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        // Live mutation authority is unavailable in this build; no hardware ownership exists.
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if activationGate.applicationBecameActive() { presentPopover() }
        else if popover.isShown { activatePopoverWindow() }
    }
    func applicationDidResignActive(_ notification: Notification) {
        closePopover(reason: "application deactivated")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDetails()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        model.isDetailVisible = false
        if !model.isPopoverVisible { model.discardDraft() }
    }

    @objc private func didWake() { model.setSleeping(false) }
    @objc private func willSleep() { model.setSleeping(true) }
    @objc private func powerChanged() { Task { await model.refresh() } }
    @objc private func reopenDetails() { showDetails() }
    @objc private func openSettings() { model.selectedSection = .settings; showDetails() }
    private func buildMenu() {
        let main = NSMenu()
        let root = NSMenuItem(); main.addItem(root)
        let app = NSMenu(); root.submenu = app
        let quickPanel = NSMenuItem(title: L10n.text("Battery menu"), action: #selector(togglePopover), keyEquivalent: "b")
        quickPanel.keyEquivalentModifierMask = [.command, .option]
        quickPanel.target = self
        app.addItem(quickPanel)
        let settings = NSMenuItem(title: L10n.text("Settings"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self; app.addItem(settings); app.addItem(.separator())
        app.addItem(withTitle: L10n.text("Quit Tilvero"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApplication.shared.mainMenu = main
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown || activationGate.isWaiting {
            closePopover(reason: "status item toggled")
            return
        }
        popoverGeneration &+= 1
        button.state = .on
        button.highlight(true)
        if activationGate.request(applicationIsActive: NSApplication.shared.isActive) {
            presentPopover()
        } else {
            startPopoverEventMonitors()
            NSApplication.shared.activate(ignoringOtherApps: true)
            if NSApplication.shared.isActive, activationGate.applicationBecameActive() { presentPopover() }
        }
    }

    private func presentPopover() {
        guard NSApplication.shared.isActive, let button = statusItem?.button else { return }
        model.isPopoverVisible = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        activatePopoverWindow()
        startPopoverEventMonitors()
        Task { await model.refresh() }
    }

    private func activatePopoverWindow() {
        guard popover.isShown else { return }
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        statusItem?.button?.state = .on
        statusItem?.button?.highlight(true)
    }

    private func closePopover(reason: String) {
        if activationGate.isWaiting {
            activationGate.cancel()
            popoverGeneration &+= 1
            stopPopoverEventMonitors()
            statusItem?.button?.state = .off
            statusItem?.button?.highlight(false)
        }
        guard popover.isShown else { return }
        popoverLog.info("Closing quick panel: \(reason, privacy: .public)")
        popover.performClose(nil)
    }

    private func startPopoverEventMonitors() {
        stopPopoverEventMonitors()
        let generation = popoverGeneration
        // Mouse-only global observation needs no keyboard monitoring permission.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.popoverGeneration == generation else { return }
                self.closePopover(reason: "outside click")
            }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.popover.isShown || self.activationGate.isWaiting else { return event }
            self.closePopover(reason: "Escape")
            return nil
        }
    }

    private func stopPopoverEventMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        outsideClickMonitor = nil
        escapeMonitor = nil
    }

    private func showDetails() {
        closePopover(reason: "details opened")
        if detailsWindow == nil {
            let controller = NSHostingController(rootView: BatteryInfoView(model: model))
            let window = NSWindow(contentViewController: controller)
            window.title = AppIdentity.displayName
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 940, height: 680))
            window.minSize = NSSize(width: 760, height: 540)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            detailsWindow = window
        }
        model.isDetailVisible = true
        NSApplication.shared.activate(ignoringOtherApps: true)
        detailsWindow?.makeKeyAndOrderFront(nil)
        Task { await model.refresh() }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let level = model.snapshot.chargePercent.availability == .available || model.snapshot.chargePercent.freshness == .stale ? ReadingPresentation.validLevel(model.snapshot.chargePercent.value) : nil
        let power = model.snapshot.isExternalPower
        let attached = power.availability == .available && power.freshness != .stale && power.value == true
        button.font = NativeStatusPresentation.font(for: model.menuBarTextSize)
        button.image = NativeBatteryStatusImage.make(level: level, style: model.displayStyle, externalPower: attached, scale: CGFloat(model.menuBarIconScale), textSize: model.menuBarTextSize)
        let percentageTitle = model.displayStyle == .beside ? NativeStatusPresentation.percentageTitle(level: level) : ""
        // Development-only marker: fixtures must remain identifiable even when closed.
        button.title = percentageTitle + (model.isDemo ? " DEMO" : "")
        let mode = (model.isDemo ? L10n.text("Simulation") + " · " : "") + (model.snapshot.chargePercent.freshness == .stale ? L10n.text("Stale") + " · " : "")
        button.toolTip = "\(AppIdentity.displayName) · \(mode)\(model.chargeText) · \(model.chargingStateText)"
        button.setAccessibilityLabel("\(AppIdentity.displayName), \(mode)\(model.chargeText), \(model.chargingStateText)")
    }
}

extension TilveroAppDelegate: NSPopoverDelegate {
    func popoverDidShow(_ notification: Notification) {
        activatePopoverWindow()
        popoverLog.info("Quick panel opened; active: \(NSApplication.shared.isActive, privacy: .public); key: \(self.popover.contentViewController?.view.window?.isKeyWindow ?? false, privacy: .public)")
    }
    func popoverDidClose(_ notification: Notification) {
        popoverGeneration &+= 1
        stopPopoverEventMonitors()
        statusItem?.button?.state = .off
        statusItem?.button?.highlight(false)
        model.quickPanelDidClose()
        popoverLog.info("Quick panel closed; event monitors removed")
    }
}

enum MenuBarDisplayStyle: String, CaseIterable, Identifiable {
    case beside, inside, iconOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .beside: L10n.text("Percent beside")
        case .inside: L10n.text("Percent inside")
        case .iconOnly: L10n.text("Icon only")
        }
    }
}

