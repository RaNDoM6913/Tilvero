import AppKit
import SwiftUI
import PowerCore
import PowerTelemetry
import PowerDiagnostics
import OSLog
import ChargeBackends
import Carbon

enum SleepTimerQuitReason {
    static func isSystem(_ reason: AEEventID?) -> Bool {
        guard let reason else { return false }
        return [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut, kAELogOut].contains(reason)
    }
    static var currentIsSystem: Bool {
        isSystem(NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue)
    }
}

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
        var launchPolicy = AppLaunchPolicy.resolve(metadata: Bundle.main.infoDictionary ?? [:], arguments: CommandLine.arguments,
            runningBundleIdentifiers: Set(AppLaunchPolicy.knownBundleIdentifiers.flatMap {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0)
            }.filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
                .compactMap(\.bundleIdentifier)))
        var controllerLease: ControllerSessionLease?
        #if TILVERO_LAB_STUDIO
        // Studio composes memory-only ports and never takes a real control lease.
        launchPolicy = .resolve(metadata: Bundle.main.infoDictionary ?? [:], arguments: ["--monitor-only"])
        #endif
        do {
            identity = try ReleaseIdentity.current()
            #if TILVERO_LAB_STUDIO
            guard identity.isLaboratory,
                  Bundle.main.object(forInfoDictionaryKey: "TilveroStudioBuild") as? Bool == true,
                  Bundle.main.object(forInfoDictionaryKey: "TilveroStudioRoot") as? String != nil else {
                showStartupBlock(english: "The Studio build requires its isolated laboratory identity and source metadata.",
                    russian: "Для Studio нужны отдельный идентификатор лаборатории и метаданные исходников.")
                return nil
            }
            #endif
            // Acquire before constructing any domain service. Failure chooses a
            // monitoring session for this entire launch, with no later promotion.
            if !launchPolicy.monitoringOnly {
                do { controllerLease = try ControllerSessionLease.acquire() }
                catch { launchPolicy = launchPolicy.tighteningForUnavailableController() }
            }
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
        return TilveroAppDelegate(historyURL: identity.historyURL(), launchPolicy: launchPolicy, controllerLease: controllerLease)
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
    private var model: TilveroModel
    #if TILVERO_LAB_STUDIO
    private let studio: LabStudioState
    private let sandbox: LabSandboxSession
    #endif
    // Keep ownership through failed/successful quit recovery. Application stop
    // does not release it; delegate destruction/process exit does.
    private let controllerLease: ControllerSessionLease?

    init(historyURL: URL, launchPolicy: AppLaunchPolicy, controllerLease: ControllerSessionLease?) {
        #if TILVERO_LAB_STUDIO
        let root = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "TilveroStudioRoot") as! String)
        sandbox = LabSandboxSession(root: root)
        studio = LabStudioState(root: root)
        model = sandbox.model
        self.controllerLease = nil
        #else
        self.controllerLease = controllerLease
        model = TilveroModel(isDemo: CommandLine.arguments.contains("--demo"), launchPolicy: launchPolicy, historyURL: historyURL)
        #endif
        super.init()
        #if TILVERO_LAB_STUDIO
        sandbox.onModelReplacement = { [weak self] model in self?.replaceSandboxModel(model) }
        #endif
    }
    private var statusItem: NSStatusItem?
    private var menuLanguage: String?
    private var keepAwakeStatusBinding: NativeKeepAwakeStatusBinding?
    private var sleepTimerWarning: SleepTimerWarningController?
    let popover = NSPopover()
    private var detailsWindow: NSWindow?
    /// Activating the app for the quick panel raises every app window. While the panel is open the already
    /// visible details window is made invisible and click-through, then restored when the panel is gone.
    private var detailsHiddenForQuickPanel = false
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    private var popoverGeneration: UInt64 = 0
    private var activationGate = QuickPanelActivationGate()
    private var presentingWithoutActivation = false
    private var textEditingObserver: Any?
    private var detailsWindowIsOnAnotherSpace: Bool {
        guard let window = detailsWindow, window.isVisible, !window.isMiniaturized else { return false }
        return !window.isOnActiveSpace
    }
    private let popoverLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? ReleaseIdentity.prototypeBundleIdentifier, category: "MenuPopover")

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.imagePosition = .imageTrailing
        item.button?.font = NativeStatusPresentation.font(for: model.menuBarTextSize)

        popover.behavior = .transient
        // Typing needs an active application. Without activation the popover works with the mouse; the first text
        // field edit activates (and, as for any activation, hides the details window while the panel is open).
        textEditingObserver = NotificationCenter.default.addObserver(forName: NSControl.textDidBeginEditingNotification, object: nil, queue: .main) { [weak self] note in
            let editedWindow = (note.object as? NSView)?.window
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown, !NSApplication.shared.isActive,
                      editedWindow != nil, editedWindow === self.popover.contentViewController?.view.window else { return }
                self.hideDetailsForQuickPanel()
                NSApplication.shared.activate()
            }
        }
        configureQuickPanel()
        configureModelPresentation()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sessionResigned), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(powerChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(clockChanged), name: NSNotification.Name.NSSystemClockDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(clockChanged), name: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reopenDetails), name: (try? ReleaseIdentity.current().reopenNotificationName) ?? Notification.Name("local.tilvero.showDetails"), object: nil)
        buildMenu()
        updateStatusItem()
        model.start()
        runMotionProbeIfRequested()
        #if TILVERO_LAB_STUDIO
        showDetails()
        #else
        if model.canShowSetup && !model.hasReviewedSetup {
            model.selectedSettingsPage = .setup
            model.selectedSection = .settings
            showDetails()
        } else if CommandLine.arguments.contains("--show-details") {
            showDetails()
        }
        #endif
    }

    private func configureQuickPanel() {
        #if TILVERO_LAB_STUDIO
        studio.setRegistryVisible("popover", false)
        #endif
        let panel = QuickPanelHostingController(model: model, maximumHeight: panelMaximumHeight)
        #if TILVERO_LAB_STUDIO
        panel.attachStudio(studio)
        #endif
        panel.onSizeChange = { [weak self] size in if let popover = self?.popover { QuickPanelPopoverSizing.apply(size, to: popover) } }
        popover.contentViewController = panel
        popover.contentSize = panel.preferredContentSize
        popover.delegate = self

    }

    private func configureModelPresentation() {
        #if TILVERO_LAB_STUDIO
        L10n.useStudioLanguage(model.language)
        #endif
        model.openDetails = { [weak self] in self?.showDetails() }
        sleepTimerWarning = SleepTimerWarningController(service: model.sleepTimer) { [weak self] in
            guard let self else { return }
            self.model.selectedSleepPage = .timer; self.model.selectedSection = .sleep; self.showDetails()
        }
        model.onPresentationChange = { [weak self] in
            guard let self else { return }
            #if TILVERO_LAB_STUDIO
            if L10n.useStudioLanguage(self.model.language) { self.studio.objectWillChange.send() }
            #endif
            self.updateStatusItem()
            if self.menuLanguage != L10n.language { self.buildMenu() }
            self.sleepTimerWarning?.refreshPresentation()
        }
        keepAwakeStatusBinding = NativeKeepAwakeStatusBinding(service: model.keepAwake) { [weak self] _ in
            self?.updateStatusItem()
        }
    }

    #if TILVERO_LAB_STUDIO
    private func replaceSandboxModel(_ replacement: TilveroModel) {
        closePopover(reason: "Studio scenario changed")
        replacement.selectedSection = model.selectedSection
        replacement.selectedSettingsPage = model.selectedSettingsPage
        replacement.selectedSleepPage = model.selectedSleepPage
        replacement.isDetailVisible = detailsAreOnScreen
        model.onPresentationChange = nil
        keepAwakeStatusBinding = nil
        sleepTimerWarning?.close()
        sleepTimerWarning = nil
        model = replacement
        configureQuickPanel()
        configureModelPresentation()
        updateStatusItem()
        model.start()
    }
    #endif

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Sparkle can replace an extracted update when the host exits. Keep all
        // ordinary quit paths closed until explicit consent and verified handoff.
        if model.updateInstaller.installationBlocksQuit {
            guard model.updateInstaller.validatedHandoffAllowsTermination,
                  model.updateReadiness.blockers.isEmpty else {
                return .terminateCancel
            }
            return .terminateNow
        }
        let systemInitiated = SleepTimerQuitReason.currentIsSystem
        if !systemInitiated && model.sleepTimer.needsHoldRelease {
            model.sleepTimer.cancel()
            if model.sleepTimer.needsHoldRelease {
                let alert = NSAlert(); alert.messageText = L10n.text("The timer’s awake hold still needs to be released.")
                alert.informativeText = model.sleepTimer.diagnostic ?? L10n.text("Release timer hold")
                alert.runModal(); return .terminateCancel
            }
        }
        if !systemInitiated && model.sleepTimerBlocksControls {
            let alert = NSAlert(); alert.messageText = L10n.text("A sleep request is being prepared or observed.")
            alert.informativeText = L10n.text("Wait for it to finish, or cancel preparation from the timer.")
            alert.runModal(); return .terminateCancel
        }
        if !systemInitiated && model.sleepTimer.isEditable {
            let alert = NSAlert(); alert.messageText = L10n.text("Quitting cancels the sleep timer.")
            alert.addButton(withTitle: L10n.text("Keep Tilvero open"))
            alert.addButton(withTitle: L10n.text("Quit and cancel timer"))
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        Task {
            let restored = await model.prepareForTermination(systemInitiated: systemInitiated)
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
        sleepTimerWarning?.close()
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
        restoreDetailsAfterQuickPanel()
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
    @objc private func sessionResigned() { model.sleepTimer.sessionResigned() }
    @objc private func powerChanged() { Task { await model.refresh() } }
    @objc private func clockChanged() {
        try? model.keepAwake.reconcile()
        model.objectWillChange.send() // Reformat the same absolute Until target after a zone change.
    }
    @objc private func reopenDetails() { showDetails() }
    @objc private func openSettings() { model.selectedSection = .settings; showDetails() }
    @objc private func checkForUpdates() {
        model.selectedSection = .settings; model.selectedSettingsPage = .updates; showDetails()
        if model.updateInstaller.isQualified { model.updateInstaller.checkForUpdates(channel: model.updates.channel) }
        Task { await model.updates.check() }
    }
    private func buildMenu() {
        menuLanguage = L10n.language
        let main = NSMenu()
        let root = NSMenuItem(); main.addItem(root)
        let app = NSMenu(); root.submenu = app
        let quickPanel = NSMenuItem(title: L10n.text("Battery menu"), action: #selector(togglePopover), keyEquivalent: "b")
        quickPanel.keyEquivalentModifierMask = [.command, .option]
        quickPanel.target = self
        app.addItem(quickPanel)
        let settings = NSMenuItem(title: L10n.text("Settings"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self; app.addItem(settings)
        let updates = NSMenuItem(title: L10n.text("Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self; app.addItem(updates); app.addItem(.separator())
        app.addItem(withTitle: L10n.text("Quit Tilvero"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(); let editMenu = NSMenu(title: L10n.text("Edit"))
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                       ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: L10n.text(title), action: Selector(selector), keyEquivalent: key)
        }
        edit.submenu = editMenu; main.addItem(edit)
        NSApplication.shared.mainMenu = main
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown || activationGate.isWaiting {
            closePopover(reason: "status item toggled")
            return
        }
        popoverGeneration &+= 1
        button.state = .on
        button.highlight(true)
        // Activating the app switches to the Space that holds its details window. Opening the quick menu must not
        // move the user away from the desktop they are on, so in that case the popover is shown without activation
        // (mouse works as usual; a text field asks for activation when editing starts, see below).
        presentingWithoutActivation = QuickPanelActivationPolicy.avoidsActivation(
            applicationIsActive: NSApplication.shared.isActive, detailsWindowOnAnotherSpace: detailsWindowIsOnAnotherSpace)
        if activationGate.request(applicationIsActive: NSApplication.shared.isActive || presentingWithoutActivation) {
            presentPopover()
        } else {
            hideDetailsForQuickPanel()
            startPopoverEventMonitors()
            NSApplication.shared.activate(ignoringOtherApps: true)
            if NSApplication.shared.isActive, activationGate.applicationBecameActive() { presentPopover() }
        }
    }

    /// A covered, minimised or hidden details window needs neither fast polling nor live metrics.
    private var detailsAreOnScreen: Bool {
        guard let window = detailsWindow else { return false }
        return window.isVisible && window.occlusionState.contains(.visible) && !detailsHiddenForQuickPanel
    }
    private func syncDetailsVisibility() { model.isDetailVisible = detailsAreOnScreen }

    private func hideDetailsForQuickPanel() {
        guard let window = detailsWindow, window.isVisible, !NSApplication.shared.isActive else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        detailsHiddenForQuickPanel = true
        syncDetailsVisibility()
    }

    private func restoreDetailsAfterQuickPanel() {
        guard detailsHiddenForQuickPanel else { return }
        detailsHiddenForQuickPanel = false
        detailsWindow?.alphaValue = 1
        detailsWindow?.ignoresMouseEvents = false
        syncDetailsVisibility()
    }

    private func presentPopover() {
        Task { await model.refreshProcessActivity() }
        Task { await model.quickPanelWillOpen() }
        try? model.keepAwake.reconcile()
        guard NSApplication.shared.isActive || presentingWithoutActivation, let button = statusItem?.button else { return }
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
        // Setup presents and refreshes its own read-only facts.
        let observeControls = model.selectedSection != .settings || model.selectedSettingsPage != .setup
        if observeControls { try? model.keepAwake.reconcile() }
        closePopover(reason: "details opened")
        if detailsWindow == nil {
            #if TILVERO_LAB_STUDIO
            let controller = NSHostingController(rootView: LabStudioWorkspace(session: sandbox, studio: studio))
            #else
            let controller = NSHostingController(rootView: BatteryInfoView(model: model))
            #endif
            let window = NSWindow(contentViewController: controller)
            #if TILVERO_LAB_STUDIO
            window.title = "Tilvero Lab"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1280, height: 820))
            window.minSize = NSSize(width: 1040, height: 640)
            #else
            window.title = AppIdentity.displayName
            window.appearance = NSAppearance(named: .aqua)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 940, height: 680))
            window.minSize = NSSize(width: 760, height: 540)
            #endif
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            detailsWindow = window
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.syncDetailsVisibility() }
            }
        }
        model.isDetailVisible = true
        restoreDetailsAfterQuickPanel()
        NSApplication.shared.activate(ignoringOtherApps: true)
        detailsWindow?.makeKeyAndOrderFront(nil)
        syncDetailsVisibility()
        if observeControls { Task { await model.refresh() } }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let level = model.snapshot.chargePercent.availability == .available || model.snapshot.chargePercent.freshness == .stale ? ReadingPresentation.validLevel(model.snapshot.chargePercent.value) : nil
        let power = model.snapshot.isExternalPower
        let attached = power.availability == .available && power.freshness != .stale && power.value == true
        let awake = KeepAwakeStatusIndicator(service: model.keepAwake)
        button.font = NativeStatusPresentation.font(for: model.menuBarTextSize)
        let lowOnBattery = !attached && (level.map { $0 <= NativeBatteryStatusImage.lowChargeThreshold } ?? false)
        func icon(pressed: Bool) -> NSImage {
            NativeBatteryStatusImage.make(level: level, style: model.displayStyle, externalPower: attached, scale: CGFloat(model.menuBarIconScale),
                                          textSize: model.menuBarTextSize, awake: awake, highlighted: pressed,
                                          appearance: model.menuBarBatteryAppearance, redWhenLow: true, awakeColor: model.awakeIndicatorColor.nsColor)
        }
        button.image = icon(pressed: button.state == .on)
        // The coloured fill (Keep Awake blue, low-charge red) stays while the menu is open.
        button.alternateImage = awake == .active || lowOnBattery ? icon(pressed: true) : nil
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
        #if TILVERO_LAB_STUDIO
        studio.setRegistryVisible("popover", true)
        #endif
        activatePopoverWindow()
        popoverLog.info("Quick panel opened; active: \(NSApplication.shared.isActive, privacy: .public); key: \(self.popover.contentViewController?.view.window?.isKeyWindow ?? false, privacy: .public)")
    }
    func popoverDidClose(_ notification: Notification) {
        #if TILVERO_LAB_STUDIO
        studio.setRegistryVisible("popover", false)
        #endif
        popoverGeneration &+= 1
        stopPopoverEventMonitors()
        statusItem?.button?.state = .off
        statusItem?.button?.highlight(false)
        updateStatusItem()
        model.quickPanelDidClose()
        if detailsHiddenForQuickPanel {
            // The user closed the panel without asking for the details window: hand activation back to the
            // previous app instead of revealing it. A fallback guarantees the window is never left invisible.
            if NSApplication.shared.isActive { NSApplication.shared.deactivate() }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.restoreDetailsAfterQuickPanel()
            }
        }
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

