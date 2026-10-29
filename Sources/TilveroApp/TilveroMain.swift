import AppKit
import SwiftUI
import PowerCore
import PowerTelemetry
import PowerDiagnostics
import OSLog
import ChargeBackends

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
        if CommandLine.arguments.contains("--native-charge-status") {
            let completed = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let value = try await PowerUIChargeClient().read()
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                    FileHandle.standardOutput.write(try encoder.encode(value)); FileHandle.standardOutput.write(Data("\n".utf8))
                } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
                completed.signal()
            }
            guard completed.wait(timeout: .now() + 15) == .success else {
                FileHandle.standardError.write(Data("The read-only native query timed out.\n".utf8)); exit(2)
            }
            return
        }
        if CommandLine.arguments.contains("--charge-status") {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            do {
                FileHandle.standardOutput.write(try encoder.encode(SystemChargeLimitObservation.read()))
                FileHandle.standardOutput.write(Data("\n".utf8))
            } catch { FileHandle.standardError.write(Data("Charge status collection failed.\n".utf8)); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--sleep-status") {
            let observed = SleepActivityProvider().readSnapshot()
            let payload: [String: Any] = [
                "collectedAt": ISO8601DateFormatter().string(from: observed.collectedAt),
                "aggregateAvailability": observed.aggregateAvailability.rawValue,
                "processAvailability": observed.processAvailability.rawValue,
                "activeTypes": observed.activeTypes.map(\.rawValue),
                "activeAssertionCount": observed.rows.count,
                "processNamesIncluded": false,
                "historicalAttributionAvailable": false
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
            } catch { FileHandle.standardError.write(Data("Sleep status collection failed.\n".utf8)); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-icons"), CommandLine.arguments.count > index + 1 {
            _ = NSApplication.shared
            do { try IconFixtures.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            catch { FileHandle.standardError.write(Data("Icon rendering failed.\n".utf8)); exit(1) }
            return
        }
        let application = NSApplication.shared
        let startup = TilveroStartupDelegate()
        application.delegate = startup
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(startup) { application.run() }
    }

    fileprivate static func prepare(application: NSApplication) -> TilveroAppDelegate? {
        if let bundleID = Bundle.main.bundleIdentifier {
            let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
            guard AppInstancePolicy.mayStart(application: application, existing: existing) else { return nil }
        }
        let identity: ReleaseIdentity
        do {
            identity = try ReleaseIdentity.current()
            if identity.isProduction {
                let defaults = UserDefaults.standard
                let source = defaults.persistentDomain(forName: ReleaseIdentity.prototypeBundleIdentifier) ?? [:]
                let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                let result = try PrototypeMigration.prepare(environment: .init(
                    sourcePreferences: source, destinationPreferences: defaults,
                    sourceStore: root.appendingPathComponent("Tilvero/History.sqlite"),
                    destinationStore: identity.historyURL(applicationSupport: root),
                    isPrototypeRunning: {
                        NSRunningApplication.runningApplications(withBundleIdentifier: ReleaseIdentity.prototypeBundleIdentifier)
                            .contains { !$0.isTerminated }
                    }))
                switch result {
                case .needsPrototypeQuit:
                    showStartupBlock(
                        english: "Quit the Tilvero prototype, then reopen this app to copy your history safely. The prototype and its data have been preserved.",
                        russian: "Закройте прототип Tilvero и снова откройте приложение для безопасного переноса истории. Прототип и его данные сохранены.")
                    return nil
                case .conflictingIdentity:
                    showStartupBlock(
                        english: "History and battery identity cannot be paired safely. Startup is blocked; both data stores and preferences have been preserved. Resolve the conflict before reopening. No fresh history was created.",
                        russian: "Не удалось безопасно сопоставить историю и идентификатор батареи. Запуск остановлен; обе базы и настройки сохранены. Устраните конфликт перед повторным запуском. Новая история не создавалась.")
                    return nil
                case .notNeeded, .migrated: break
                }
            }
        } catch {
            showStartupBlock(
                english: "Tilvero could not prepare its data safely. Startup is blocked and the migration can be retried after the problem is resolved. Existing data has been preserved.",
                russian: "Tilvero не смог безопасно подготовить данные. Запуск остановлен. После устранения проблемы перенос можно повторить; существующие данные сохранены.")
            return nil
        }
        return TilveroAppDelegate(historyURL: identity.historyURL())
    }

    // Do not read app localization/defaults before migration has committed.
    private static func showStartupBlock(english: String, russian: String) {
        let useRussian = Locale.preferredLanguages.first?.hasPrefix("ru") == true
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = useRussian ? "Tilvero: запуск остановлен" : "Tilvero: startup blocked"
        alert.informativeText = useRussian ? russian : english
        alert.addButton(withTitle: useRussian ? "Закрыть" : "Close")
        alert.runModal()
    }
}

/// Finish AppKit launch before presenting modal startup decisions. Keep domain
/// initialization behind those decisions so two copies cannot open the store.
@MainActor
private final class TilveroStartupDelegate: NSObject, NSApplicationDelegate {
    private var runningDelegate: TilveroAppDelegate?
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let application = NSApplication.shared
            guard let delegate = TilveroMain.prepare(application: application) else {
                application.terminate(nil)
                return
            }
            runningDelegate = delegate
            application.delegate = delegate
            application.setActivationPolicy(.accessory)
            delegate.start()
        }
    }
}

@MainActor
final class TilveroAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model: TilveroModel

    init(historyURL: URL) {
        model = TilveroModel(isDemo: CommandLine.arguments.contains("--demo"), historyURL: historyURL)
        super.init()
    }
    private var statusItem: NSStatusItem?
    private var keepAwakeStatusBinding: NativeKeepAwakeStatusBinding?
    private let popover = NSPopover()
    private var detailsWindow: NSWindow?
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    private var popoverGeneration: UInt64 = 0
    private var activationGate = QuickPanelActivationGate()
    private let popoverLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? ReleaseIdentity.prototypeBundleIdentifier, category: "MenuPopover")

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.imagePosition = .imageTrailing
        item.button?.font = NativeStatusPresentation.font(for: model.menuBarTextSize)

        popover.behavior = .transient
        let panel = QuickPanelHostingController(model: model, maximumHeight: panelMaximumHeight)
        panel.onSizeChange = { [weak self] size in self?.popover.contentSize = size }
        popover.contentViewController = panel
        popover.contentSize = panel.preferredContentSize
        popover.delegate = self

        model.openDetails = { [weak self] in self?.showDetails() }
        model.onPresentationChange = { [weak self] in self?.updateStatusItem() }
        keepAwakeStatusBinding = NativeKeepAwakeStatusBinding(service: model.keepAwake) { [weak self] _ in
            self?.updateStatusItem()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(powerChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(clockChanged), name: NSNotification.Name.NSSystemClockDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(clockChanged), name: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reopenDetails), name: (try? ReleaseIdentity.current().reopenNotificationName) ?? Notification.Name("local.tilvero.showDetails"), object: nil)
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
                alert.informativeText = model.terminationRecoveryMessage ?? L10n.text("Operation failed")
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
        // Restoration was admitted above; stop also retries release of our idle-sleep assertion.
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        try? model.keepAwake.reconcile()
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
    @objc private func clockChanged() {
        try? model.keepAwake.reconcile()
        model.objectWillChange.send() // Reformat the same absolute Until target after a zone change.
    }
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
        Task { await model.refreshProcessActivity() }
        try? model.keepAwake.reconcile()
        guard NSApplication.shared.isActive, let button = statusItem?.button else { return }
        (popover.contentViewController as? QuickPanelHostingController)?.updateMaximumHeight(panelMaximumHeight)
        model.isPopoverVisible = true
        QuickPanelMotion.configure(popover, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        activatePopoverWindow()
        startPopoverEventMonitors()
        Task { await model.refresh() }
    }

    private var panelMaximumHeight: CGFloat {
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main
        // Leave room for the popover arrow and screen-edge margins. The visible
        // frame already excludes the menu bar and Dock on the anchor display.
        return max(1, (screen?.visibleFrame.height ?? 700) - 32)
    }

    private func activatePopoverWindow() {
        guard popover.isShown else { return }
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        statusItem?.button?.state = .on
        statusItem?.button?.highlight(true)
        updateStatusItem()
    }

    private func closePopover(reason: String) {
        if activationGate.isWaiting {
            activationGate.cancel()
            popoverGeneration &+= 1
            stopPopoverEventMonitors()
            statusItem?.button?.state = .off
            statusItem?.button?.highlight(false)
            updateStatusItem()
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
        try? model.keepAwake.reconcile()
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
        let awake = KeepAwakeStatusIndicator(service: model.keepAwake)
        button.font = NativeStatusPresentation.font(for: model.menuBarTextSize)
        button.image = NativeBatteryStatusImage.make(level: level, style: model.displayStyle, externalPower: attached, scale: CGFloat(model.menuBarIconScale), textSize: model.menuBarTextSize, awake: awake, highlighted: button.state == .on)
        button.alternateImage = awake == .active ? NativeBatteryStatusImage.make(level: level, style: model.displayStyle, externalPower: attached, scale: CGFloat(model.menuBarIconScale), textSize: model.menuBarTextSize, awake: awake, highlighted: true) : nil
        let percentageTitle = model.displayStyle == .beside ? NativeStatusPresentation.percentageTitle(level: level) : ""
        // Development-only marker: fixtures must remain identifiable even when closed.
        button.title = percentageTitle + (model.isDemo ? " DEMO" : "")
        let mode = (model.isDemo ? L10n.text("Simulation") + " · " : "") + (model.snapshot.chargePercent.freshness == .stale ? L10n.text("Stale") + " · " : "")
        let awakeSuffix = awake.accessibilitySuffix.map { " · " + $0 } ?? ""
        button.toolTip = "\(AppIdentity.displayName) · \(mode)\(model.chargeText) · \(model.chargingStateText)\(awakeSuffix)"
        button.setAccessibilityLabel("\(AppIdentity.displayName), \(mode)\(model.chargeText), \(model.chargingStateText)\(awakeSuffix)")
    }
}

/// Read the current accessibility preference at each presentation, including
/// after it changes while the panel is closed. AppKit owns the transition.
@MainActor enum QuickPanelMotion {
    static func configure(_ popover: NSPopover, reduceMotion: Bool) {
        popover.animates = !reduceMotion
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
        updateStatusItem()
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

