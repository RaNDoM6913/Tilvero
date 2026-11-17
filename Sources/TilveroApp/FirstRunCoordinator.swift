// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import Combine
import PowerCore
import ServiceManagement
import SwiftUI

/// Everything the first run changes on the system, injected so tests and the preview never touch the real thing.
@MainActor struct FirstRunPorts {
    var markIntroduced: () -> Void
    var setHistory: (Bool) -> Void
    /// On: register the login item and report the real status. Off: undo a registration made earlier in this run.
    var setLogin: (Bool) -> FirstRunLoginResult?
    var openLoginItemsSettings: () -> Void
    /// One password for all chosen features, through the macOS dialog or a prepared Terminal window.
    var requestPermission: (Set<PrivilegedFeature>, PermissionRoute) async -> PrivilegedOutcome
    /// The exact text the Terminal route runs for these features (shown behind "Show command").
    var commandText: (Set<PrivilegedFeature>) -> String?
    /// The Terminal wait checks again at once (the app came back to the front).
    var nudge: () -> Void
    /// Registers for Terminal runs that succeed after the window stopped waiting for them.
    var observeLateGrant: (@escaping @MainActor (Set<PrivilegedFeature>) -> Void) -> Void = { _ in }
    /// Turns the closed-lid option on after its permission was granted (no further prompt); true when it is on.
    var turnOnLid: () async -> Bool
    /// Gives a brand-new install the starter Overview right before the real quick menu opens on it. The port itself
    /// leaves an already stored layout alone.
    var applyOverviewDefaults: () -> Void = {}
}

enum FirstRunLogin {
    /// Maps the SMAppService status read after `register()` to what the window shows.
    static func result(statusAfter status: SMAppService.Status) -> FirstRunLoginResult {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        // `register()` may throw while still leaving the item waiting for approval; the status decides.
        default: .failed
        }
    }

    /// The real login item. Registers only when asked with the switch on; an "off" undoes only its own registration.
    @MainActor final class Native {
        private var registeredHere = false
        func set(_ on: Bool) -> FirstRunLoginResult? {
            let service = SMAppService.mainApp
            guard on else {
                if registeredHere { try? service.unregister(); registeredHere = false }
                return nil
            }
            if service.status == .enabled { return .enabled }
            try? service.register()
            let result = FirstRunLogin.result(statusAfter: service.status)
            registeredHere = registeredHere || result != .failed
            return result
        }
    }
}

/// What the coordinator needs from the app delegate (status item, popover, details window).
@MainActor protocol FirstRunHost: AnyObject {
    var firstRunStatusButtonFrame: NSRect? { get }
    var firstRunStatusItemVisible: Bool { get }
    /// nil = the real level; otherwise the fraction of it drawn while the window lands.
    func firstRunDrawIcon(fill: Double?)
    func firstRunOpenPopover()
    func firstRunOpenDetails()
    func firstRunFinished()
    /// After the hand-off: keep a pulsing ring on the icon while the quick menu is not open (see `FirstRunBeacon`).
    func firstRunPointAtIcon()
}

extension FirstRunHost {
    func firstRunPointAtIcon() {}
}

/// Thin AppKit glue: runs the effects of `FirstRunFlow` (window, permission request, landing in the icon).
@MainActor final class FirstRunCoordinator: NSObject, NSWindowDelegate {
    let session: FirstRunSession
    private let ports: FirstRunPorts
    private weak var host: FirstRunHost?
    private(set) var window: NSWindow?
    private var permissionTask: Task<Void, Never>?
    private var lidTask: Task<Void, Never>?
    private var scheduled: [Task<Void, Never>] = []
    private var iconTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var stepSubscription: AnyCancellable?
    private var finishPending = false
    private var overviewDefaultsApplied = false
    private var token = 0
    /// Tests run the flow without ever creating, showing or activating a window.
    var presentsWindow = true
    /// Integration tests show the real window but never activate the test process (focus stays with the user).
    var activatesApp = true

    init(session: FirstRunSession, ports: FirstRunPorts, host: FirstRunHost) {
        self.session = session; self.ports = ports; self.host = host
        super.init()
        session.perform = { [weak self] effect in self?.run(effect) }
        ports.observeLateGrant { [weak session] features in session?.send(.lateGrant(features)) }
    }

    // MARK: Lifecycle

    /// The window appears centered and in front: the single exception to the quiet launch (the user just opened the
    /// app for the first time). It is recorded at once, so a crash or quit never shows it again.
    func start() {
        token += 1
        overviewDefaultsApplied = false
        ports.markIntroduced()
        showWindow()
    }

    /// Debug: tear everything down and play again.
    func restart() {
        teardown()
        session.flow = FirstRunFlow()
        session.jump(to: .choosing)
        start()
    }

    func teardown() {
        token += 1
        scheduled.forEach { $0.cancel() }; scheduled.removeAll()
        permissionTask?.cancel(); permissionTask = nil
        lidTask?.cancel(); lidTask = nil
        iconTask?.cancel(); iconTask = nil
        host?.firstRunDrawIcon(fill: nil)
        finishPending = false
        dropWindow()
    }

    /// Debug: jump straight to a step (waiting steps start their request again).
    func jump(to step: FirstRunStep) {
        teardown()
        session.jump(to: step)
        if step != .finished { showWindow() }
        switch step {
        case .waitingSystem, .waitingTerminal: run(.requestPermission(session.flow.requested, session.flow.route))
        case .done: run(.reveal(afterSuccess: true))
        default: break
        }
    }

    // MARK: Effects

    private func run(_ effect: FirstRunEffect) {
        switch effect {
        case .applyEveryday(let login, let history):
            ports.setHistory(history)
            let result = ports.setLogin(login)
            // Delivered after the current event finished (the flow is not re-entered while it handles one).
            let my = token
            after(0) { [weak self] in if let self, my == self.token { self.session.send(.everydayApplied(result)) } }
        case .requestPermission(let features, let route):
            session.commandText = route == .terminal ? ports.commandText(features) : nil
            permissionTask?.cancel()
            permissionTask = Task { [weak self] in
                guard let self else { return }
                let outcome = await self.ports.requestPermission(features, route)
                guard !Task.isCancelled else { return }
                if self.presentsWindow, self.activatesApp {
                    self.window?.makeKeyAndOrderFront(nil)
                    NSApplication.shared.activate()
                }
                self.session.send(.permissionFinished(outcome))
            }
        case .cancelPermissionRequest:
            permissionTask?.cancel(); permissionTask = nil
        case .turnOnLid:
            lidTask?.cancel()
            lidTask = Task { [weak self] in
                guard let self else { return }
                let enabled = await self.ports.turnOnLid()
                guard !Task.isCancelled else { return }
                self.session.send(.lidTurnedOn(enabled))
            }
        case .openLoginItemsSettings: ports.openLoginItemsSettings()
        case .reveal(let afterSuccess): reveal(afterSuccess: afterSuccess)
        case .closeWindow: closeWindow(intoIcon: nil)
        case .openDetails: host?.firstRunOpenDetails()
        case .finish:
            finishPending = true
            completeFinish()
        }
    }

    /// Ends the flow once the icon fill has reached the real level: the host may free the coordinator right after,
    /// so the icon must never be left drawn at a fraction of the measured charge.
    private func completeFinish() {
        guard finishPending else { return }
        finishPending = false
        let fill = iconTask
        Task { @MainActor [self] in   // keeps the coordinator alive until the icon is real again
            await fill?.value
            iconTask = nil
            host?.firstRunDrawIcon(fill: nil)
            host?.firstRunFinished()
        }
    }

    private func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        scheduled.removeAll { $0.isCancelled }
        scheduled.append(Task { @MainActor in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) } else { await Task.yield() }
            guard !Task.isCancelled else { return }
            body()
        })
    }

    // MARK: Landing in the menu bar icon

    /// Short success beat (if a permission was just granted), then the window flies into the real icon, the icon fills
    /// up and the real quick menu opens. With no room for the icon the window stays and explains how to make room.
    private func reveal(afterSuccess: Bool) {
        // Every way out of the setup (start, skip, declined, attention, no room for the icon) passes through here
        // before the real quick menu opens; the starter page is written once, whichever route was taken.
        if !overviewDefaultsApplied { overviewDefaultsApplied = true; ports.applyOverviewDefaults() }
        let my = token
        let reduce = session.reduceMotion
        let speed = max(session.speed, 0.1)
        let beat = afterSuccess ? FirstRunMotion.successBeat(reduceMotion: reduce) / speed : 0
        after(beat) { [weak self] in
            guard let self, my == self.token else { return }
            guard let host = self.host, host.firstRunStatusItemVisible, let button = host.firstRunStatusButtonFrame else {
                self.session.send(.iconHidden); return
            }
            self.closeWindow(intoIcon: button)
            self.fillIcon(delay: reduce ? 0 : FirstRunMotion.handOffDuration(reduceMotion: false) * 0.6)
            self.after(FirstRunMotion.handOffDuration(reduceMotion: reduce) / speed) { [weak self] in
                guard let self, my == self.token else { return }
                self.host?.firstRunOpenPopover()
                self.host?.firstRunPointAtIcon()
                self.session.send(.revealed)
            }
        }
    }

    private func fillIcon(delay: Double) {
        iconTask?.cancel()
        guard !session.reduceMotion else { host?.firstRunDrawIcon(fill: nil); return }
        let speed = max(session.speed, 0.1)
        host?.firstRunDrawIcon(fill: 0)
        iconTask = Task { @MainActor [weak host] in
            defer { host?.firstRunDrawIcon(fill: nil) }   // cancelled or finished: always back to the real level
            try? await Task.sleep(for: .seconds(delay / speed))
            let started = Date()
            while !Task.isCancelled {
                let fill = FirstRunMotion.iconFill(Date().timeIntervalSince(started) * speed, reduceMotion: false)
                if fill >= 1 { return }
                host?.firstRunDrawIcon(fill: fill)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    // MARK: Window

    private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private var screenFrame: NSRect {
        let button = host?.firstRunStatusButtonFrame
        // The screen of the menu bar icon (the menu bar can be on any display), else the main one.
        let holder = button.flatMap { b in NSScreen.screens.first { $0.frame.contains(NSPoint(x: b.midX, y: b.midY)) } }
        return (holder ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func showWindow() {
        guard presentsWindow, window == nil else { return }
        session.restartEntrance()
        let hosting = FirstMouseHostingView(rootView: FirstRunWindowView(session: session))
        hosting.sizingOptions = []   // the coordinator sizes the window (and keeps it centered)
        hostingView = hosting
        // `fittingSize` is zero once the hosting view no longer reports an intrinsic size: measure the SwiftUI
        // content itself (a 0 × 0 key window was invisible yet took Return/Escape).
        let size = measuredSize()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = AppIdentity.displayName
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.delegate = self
        window.setFrame(FirstRunWindowGeometry.centered(size: size, in: screenFrame), display: false)
        self.window = window
        window.alphaValue = 0
        if activatesApp {
            NSApplication.shared.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = FirstRunMotion.crossfadeDuration(reduceMotion: session.reduceMotion)
            window.animator().alphaValue = 1
        }
        // Anything that changes the window's content height (step, buttons, attention lines, the command box).
        stepSubscription = session.$flow.combineLatest(session.$showsCommand).map { FirstRunWindowView.layoutKey($0, showsCommand: $1) }.removeDuplicates()
            .dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.resizeWindowToFit() }
        // Back from Terminal: look again at once instead of waiting for the next change.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.session.step == .waitingTerminal { self?.ports.nudge() } }
        })
    }

    private var hostingView: FirstMouseHostingView<FirstRunWindowView>?

    /// A fresh, never-displayed controller of the same view measures the current content (NSHostingView has no
    /// `sizeThatFits`, its `fittingSize` is zero with `sizingOptions = []`, and a kept controller would update its
    /// graph only later, one state behind).
    private func measuredSize() -> NSSize {
        let measurer = NSHostingController(rootView: FirstRunWindowView(session: session))
        return FirstRunWindowGeometry.usableSize(measurer.sizeThatFits(in: NSSize(width: FirstRunWindowView.width, height: 4000)))
    }

    private func resizeWindowToFit() {
        guard let window else { return }
        let size = measuredSize()
        guard size != window.frame.size else { return }
        let frame = FirstRunWindowGeometry.resized(window.frame, to: size, within: window.screen?.visibleFrame ?? screenFrame)
        window.setFrame(frame, display: true, animate: !session.reduceMotion)
    }

    private func dropWindow() {
        hostingView = nil
        stepSubscription = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        guard let window else { return }
        self.window = nil
        window.delegate = nil
        window.orderOut(nil)
    }

    /// Into the icon (a frame on screen) or a plain fade (nil).
    private func closeWindow(intoIcon button: NSRect?) {
        guard let window else { return }
        hostingView = nil
        stepSubscription = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        self.window = nil
        window.delegate = nil
        let reduce = session.reduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = FirstRunMotion.handOffDuration(reduceMotion: reduce) / max(session.speed, 0.1)
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if let button, !reduce { window.animator().setFrame(FirstRunWindowGeometry.landing(on: button), display: true) }
            window.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { window.orderOut(nil) } })
    }

    /// The close button means Skip (or Close on the "no room" step); the flow decides how the window goes.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch session.step {
        case .applying, .enablingLid, .done, .finished: break
        default: session.send(.skip)
        }
        return false
    }
}
