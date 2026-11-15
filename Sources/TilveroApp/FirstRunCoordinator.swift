// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import PowerCore
import ServiceManagement
import SwiftUI

/// Everything the first run changes on the system, injected so tests and the preview never touch the real thing.
@MainActor struct FirstRunPorts {
    var markIntroduced: () -> Void
    var setHistory: (Bool) -> Void
    /// SMAppService registration; called only when "Done" is pressed with the switch on.
    var registerLogin: () -> FirstRunLoginResult
    var openLoginItemsSettings: () -> Void
    /// One administrator prompt for all chosen features.
    var install: (Set<PrivilegedFeature>) async -> PrivilegedInstallOutcome
    /// Turns the closed-lid option on after its permission was granted (no further prompt); true when it is on.
    var turnOnLid: () async -> Bool
}

enum FirstRunLogin {
    /// Maps the SMAppService status read after `register()` to what the card shows.
    static func result(statusAfter status: SMAppService.Status, threw: Bool) -> FirstRunLoginResult {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        // `register()` may throw while still leaving the item waiting for approval; the status decides.
        default: .failed
        }
    }

    @MainActor static func registerNative() -> FirstRunLoginResult {
        let service = SMAppService.mainApp
        if service.status == .enabled { return .enabled }
        var threw = false
        do { try service.register() } catch { threw = true }
        return result(statusAfter: service.status, threw: threw)
    }

    static func outcome(_ install: PrivilegedInstallOutcome) -> FirstRunPromptResult {
        switch install {
        case .granted(let features): .success(features)
        case .cancelled: .cancelled
        case .failed: .failed
        }
    }
}

/// What the coordinator needs from the app delegate (status item, popover).
@MainActor protocol FirstRunHost: AnyObject {
    var firstRunStatusButtonFrame: NSRect? { get }
    var firstRunPopoverShown: Bool { get }
    func firstRunSetPopoverBehavior(_ behavior: NSPopover.Behavior)
    func firstRunShowPopover()
    func firstRunClosePopover()
    /// nil = the real level; otherwise the fraction of it drawn during the first-launch fill.
    func firstRunDrawIcon(fill: Double?)
    func firstRunFinished()
}

/// Thin AppKit glue: runs the effects of `FirstRunFlow` (window, beacon, bubble, popover behavior, prompt).
@MainActor final class FirstRunCoordinator: NSObject, NSWindowDelegate {
    let session: FirstRunSession
    private let ports: FirstRunPorts
    private weak var host: FirstRunHost?
    private var window: NSWindow?
    private var beacon: NSPanel?
    private var bubble: NSPanel?
    private var permissionTask: Task<Void, Never>?
    private var scheduled: [Task<Void, Never>] = []
    private var iconTask: Task<Void, Never>?
    private var lidTask: Task<Void, Never>?
    private var token = 0
    /// Debug: open the window on the "icon hidden" scene.
    var startsHidden = false

    init(session: FirstRunSession, ports: FirstRunPorts, host: FirstRunHost) {
        self.session = session; self.ports = ports; self.host = host
        super.init()
        session.perform = { [weak self] effect in self?.run(effect) }
    }

    // MARK: Lifecycle

    func start() {
        token += 1
        let my = token
        fillIcon()
        after(0.3) { [weak self] in
            guard let self, my == self.token, self.session.step == .iconFill else { return }
            self.session.send(.iconFilled)
            if self.startsHidden { self.session.send(.showHidden) }
        }
    }

    /// Debug: tear everything down and play again from the icon fill.
    func restart() {
        teardown()
        session.flow = FirstRunFlow()
        session.restartScene()
        start()
    }

    /// `closesPopover` is false only when the flow ends by itself: a popover the user opened during the bubble stays.
    func teardown(closesPopover: Bool = true) {
        token += 1
        ignoreClosesUntil = Date().addingTimeInterval(0.8)
        scheduled.forEach { $0.cancel() }; scheduled.removeAll()
        permissionTask?.cancel(); permissionTask = nil
        iconTask?.cancel(); iconTask = nil
        lidTask?.cancel(); lidTask = nil
        host?.firstRunDrawIcon(fill: nil)
        closeWindow(intoIcon: false)
        beacon?.orderOut(nil); beacon = nil
        bubble?.orderOut(nil); bubble = nil
        if closesPopover { host?.firstRunClosePopover() }
        host?.firstRunSetPopoverBehavior(.transient)
    }

    /// Debug: jump straight to a scene.
    func jump(to step: FirstRunStep) {
        teardown()
        session.jump(to: step)
        switch step {
        case .whereIcon, .hiddenIcon: showWindow(); showBeacon()
        case .card, .confirmPreview, .systemPrompt, .done, .declined:
            host?.firstRunSetPopoverBehavior(.applicationDefined)
            after(0.4) { [weak self] in self?.host?.firstRunShowPopover() }   // after the closing popover is gone
            if step == .confirmPreview { schedulePreviewEnd() }
            if step == .systemPrompt { run(.requestPermission(session.flow.requested)) }
        case .bubble: showBubble()
        case .iconFill, .finished: break
        }
    }

    // MARK: Hooks from the app delegate

    /// The real status item was clicked: the window flies into the icon and the popover continues the flow.
    func statusItemClicked() {
        if session.step == .whereIcon || session.step == .hiddenIcon { session.send(.statusItemClicked) }
    }
    func popoverDidClose() {
        // A debug restart/jump closes the popover itself; that close must not end the freshly jumped-to scene.
        guard Date() >= ignoreClosesUntil else { return }
        session.send(.popoverClosed)
    }
    private var ignoreClosesUntil = Date.distantPast
    /// While the card is up the popover only closes on the user's explicit action (X, Done, the icon, Esc).
    var holdsPopoverOpen: Bool { session.flow.popoverBehavior == .applicationDefined }

    // MARK: Effects

    private func run(_ effect: FirstRunEffect) {
        switch effect {
        case .markIntroduced: ports.markIntroduced()
        case .showWindow: showWindow()
        case .closeWindow(let intoIcon): closeWindow(intoIcon: intoIcon)
        case .showBeacon: showBeacon()
        case .hideBeacon: beacon?.orderOut(nil); beacon = nil
        case .hostCardInWindow: resizeWindowToFit()
        case .setPopoverBehavior(let behavior): host?.firstRunSetPopoverBehavior(behavior)
        case .ensurePopoverShown:
            if !session.flow.hostedInWindow, host?.firstRunPopoverShown == false { host?.firstRunShowPopover() }
            resizeWindowToFit()
        case .closePopover: host?.firstRunClosePopover()
        case .applyEverydayChoices(let login, let history):
            ports.setHistory(history)
            if login { session.send(.loginFinished(ports.registerLogin())) }
            resizeWindowToFit()
        case .requestPermission(let features):
            permissionTask?.cancel()
            permissionTask = Task { [weak self] in
                guard let self else { return }
                let outcome = await self.ports.install(features)
                guard !Task.isCancelled else { return }
                self.session.send(.promptFinished(FirstRunLogin.outcome(outcome)))
                self.resizeWindowToFit()
            }
        case .cancelPermissionRequest:
            permissionTask?.cancel(); permissionTask = nil
            resizeWindowToFit()
        case .turnOnGranted(let features):
            // The row is checked only from the real result (the option may still be refused, e.g. sleep already disabled).
            if features.contains(.lidClosed) {
                lidTask?.cancel()
                lidTask = Task { [weak self] in
                    guard let self else { return }
                    let enabled = await self.ports.turnOnLid()
                    guard !Task.isCancelled else { return }
                    self.session.send(.lidTurnedOn(enabled))
                }
            }
        case .openLoginItemsSettings: ports.openLoginItemsSettings()
        case .showBubble: showBubble()
        case .playConfirmPreview: schedulePreviewEnd(); resizeWindowToFit()
        case .finish:
            teardown(closesPopover: false)
            host?.firstRunFinished()
        }
    }

    private var previewToken = 0
    /// The drawn preview plays 1.2 s (0.2 s with Reduce Motion), then the system prompt follows.
    private func schedulePreviewEnd() {
        previewToken += 1
        let my = previewToken, sceneStart = session.sceneStart
        let delay = session.reduceMotion ? 0.2 : FirstRunMotion.confirmPreviewDuration / max(session.speed, 0.1)
        after(delay) { [weak self] in
            guard let self, my == self.previewToken, self.session.step == .confirmPreview, self.session.sceneStart == sceneStart else { return }
            self.session.send(.previewFinished)
        }
    }

    private func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        scheduled.removeAll { $0.isCancelled }
        scheduled.append(Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            body()
        })
    }

    // MARK: Icon fill (real NativeBatteryStatusImage frames via the host)

    private func fillIcon() {
        iconTask?.cancel()
        guard !session.reduceMotion else { host?.firstRunDrawIcon(fill: nil); return }
        let started = Date(), speed = max(session.speed, 0.1)
        host?.firstRunDrawIcon(fill: 0)
        // About 60 frames per second for 0.7 s, then the real image again; nothing runs afterwards.
        iconTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let fill = FirstRunMotion.iconFill(Date().timeIntervalSince(started) * speed, reduceMotion: false)
                self?.host?.firstRunDrawIcon(fill: fill >= 1 ? nil : fill)
                if fill >= 1 { return }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    // MARK: Window

    private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
        // A click on the inactive app's window acts at once instead of only activating the app.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private func showWindow() {
        guard window == nil else { return }
        let hosting = FirstMouseHostingView(rootView: FirstRunWindowView(session: session))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = AppIdentity.displayName
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.delegate = self
        window.setContentSize(hosting.fittingSize)
        window.setFrameOrigin(windowOrigin(size: window.frame.size))
        self.window = window
        // The one launch-time exception: shown, never activated, never floating, no focus stealing.
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = FirstRunMotion.crossfadeDuration(reduceMotion: session.reduceMotion)
            window.animator().alphaValue = 1
        }
        // A covered or minimised window pauses its timeline: no per-frame work nobody sees.
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                self.session.windowOnScreen = window.occlusionState.contains(.visible)
            }
        }
    }
    private var occlusionObserver: NSObjectProtocol?
    private func removeOcclusionObserver() {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
    }

    private func windowOrigin(size: NSSize) -> NSPoint {
        let button = host?.firstRunStatusButtonFrame
        // The screen that holds the status item (the menu bar can be on any display), else the main one.
        let holder = button.flatMap { b in NSScreen.screens.first { $0.frame.contains(NSPoint(x: b.midX, y: b.midY)) } }
        let screen = (holder ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        guard let button else {
            return NSPoint(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 80)
        }
        let x = min(max(button.midX + 80 - size.width, screen.minX + 12), screen.maxX - size.width - 12)
        return NSPoint(x: x, y: button.minY - 72 - size.height)
    }

    private func resizeWindowToFit() {
        guard let window, let view = window.contentView else { return }
        Task { @MainActor in
            view.layoutSubtreeIfNeeded()
            let size = view.fittingSize
            guard size.width > 0, size.height > 0 else { return }
            var frame = window.frame
            frame.origin.y += frame.height - size.height
            frame.size = size
            window.setFrame(frame, display: true, animate: !session.reduceMotion)
        }
    }

    private func closeWindow(intoIcon: Bool) {
        guard let window else { return }
        self.window = nil
        window.delegate = nil
        removeOcclusionObserver()
        guard intoIcon, let button = host?.firstRunStatusButtonFrame else { window.orderOut(nil); return }
        let reduce = session.reduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = FirstRunMotion.handOffDuration(reduceMotion: reduce)
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if !reduce { window.animator().setFrame(NSRect(x: button.midX - 52, y: button.midY - 40, width: 104, height: 80), display: true) }
            window.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { window.orderOut(nil) } })
    }

    func windowWillClose(_ notification: Notification) {
        // The title bar close button means Skip (scenes) or Done (card hosted here).
        window = nil
        removeOcclusionObserver()
        guard session.flow.hostedInWindow else { session.send(.skip); return }
        if session.step == .confirmPreview || session.step == .systemPrompt { session.send(.cancelConfirmation) }
        session.send(.dismissCard)
    }

    // MARK: Beacon and bubble

    private func overlayPanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true   // the guide never intercepts clicks
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        return panel
    }

    private func showBeacon() {
        guard let button = host?.firstRunStatusButtonFrame else { return }
        let panel = beacon ?? overlayPanel(size: NSSize(width: 80, height: 70))
        panel.contentView = NSHostingView(rootView: FirstRunBeaconView(start: Date(), reduceMotion: session.reduceMotion))
        panel.setFrameOrigin(NSPoint(x: button.midX - 40, y: button.minY - 66))
        panel.orderFrontRegardless()
        beacon = panel
    }

    private func showBubble() {
        bubble?.orderOut(nil)
        let my = token
        guard let button = host?.firstRunStatusButtonFrame else {
            after(0.1) { [weak self] in if let self, my == self.token { self.session.send(.bubbleFinished) } }
            return
        }
        let panel = overlayPanel(size: NSSize(width: 220, height: 100))
        panel.contentView = NSHostingView(rootView: FirstRunBubbleView(start: Date(), reduceMotion: session.reduceMotion))
        panel.setFrameOrigin(NSPoint(x: button.midX - 110, y: button.minY - 96))
        panel.orderFrontRegardless()
        bubble = panel
        after(FirstRunMotion.bubbleDuration + 0.1) { [weak self] in
            guard let self, my == self.token else { return }
            self.bubble?.orderOut(nil); self.bubble = nil
            self.session.send(.bubbleFinished)
        }
    }
}
