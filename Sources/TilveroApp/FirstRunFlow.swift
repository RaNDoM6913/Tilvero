// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation

/// The steps of the one first-run window. Setup comes first; when it is done (or skipped) the window lands in the menu
/// bar icon and the real quick menu opens.
enum FirstRunStep: String, Equatable, CaseIterable {
    /// All five choices on one page; the main button starts.
    case choosing
    /// History and login are being applied (instant).
    case applying
    /// The macOS administrator dialog is up (Touch ID or password).
    case waitingSystem
    /// Terminal is open with everything prepared; the window detects the result by itself.
    case waitingTerminal
    /// The closed-lid option is being turned on after its permission.
    case enablingLid
    /// The dialog was dismissed or Terminal cancelled: calm, one "Try again".
    case declined
    case failed
    /// Terminal did not finish within the waiting time.
    case timedOut
    /// Something needs one more look (login needs approval, the lid option refused) before the app opens.
    case attention
    /// Short success beat, then the window flies into the icon and the quick menu opens.
    case done
    /// The icon has no room in the menu bar (notch, many icons): the window says how to make room.
    case iconHidden
    case finished
}

enum FirstRunLoginResult: Hashable { case enabled, requiresApproval, failed }

/// What the user picks. Defaults: everything is on, so one click on the main button sets the app up (the two features
/// that need the administrator password ask for it once, in one macOS dialog) and the user switches off only what they
/// do not want. (The charge limit is a macOS setting Tilvero only reads: it is not a first-run choice.)
struct FirstRunChoices: Equatable {
    var launchAtLogin = true
    var keepHistory = true
    var lidClosed = true
    var chargeByTime = true

    var lockedFeatures: Set<PrivilegedFeature> {
        var set = Set<PrivilegedFeature>()
        if lidClosed { set.insert(.lidClosed) }
        if chargeByTime { set.insert(.chargeByTime) }
        return set
    }
}

enum FirstRunEvent: Hashable {
    /// Main button: apply login and history, then one macOS dialog for the locked features (if any).
    case start
    /// Fallback link: the same, but the password is typed in a prepared Terminal window.
    case useTerminal
    case everydayApplied(FirstRunLoginResult?)
    case permissionFinished(PrivilegedOutcome)
    /// A Terminal run the window had stopped waiting for (Cancel, timeout) did install these after all.
    case lateGrant(Set<PrivilegedFeature>)
    case lidTurnedOn(Bool)
    /// While waiting: stop asking (locked features stay off).
    case cancel
    /// After a cancel or failure: open the app without the locked features.
    case continueWithout
    /// "Skip" or the window's close button: open the app, change nothing.
    case skip
    case openLoginSettings
    case revealed
    case iconHidden
    case openDetails
}

enum FirstRunEffect: Equatable {
    case applyEveryday(launchAtLogin: Bool, keepHistory: Bool)
    case requestPermission(Set<PrivilegedFeature>, PermissionRoute)
    case cancelPermissionRequest
    case turnOnLid
    case openLoginItemsSettings
    /// Close the window into the menu bar icon and open the real quick menu on Overview (after a short beat when a
    /// permission was just granted). Nothing else: no coach, no tour.
    case reveal(afterSuccess: Bool)
    case closeWindow
    case openDetails
    case finish
}

/// What still needs a look before the app opens.
enum FirstRunAttention: String, Equatable, CaseIterable { case loginNeedsApproval, loginFailed, lidRefused }

/// The buttons of a step, so the view only draws them (and tests read them).
struct FirstRunButtons: Equatable {
    enum Primary: Equatable { case start, allowAndStart, tryAgain, openApp }
    enum Secondary: Equatable { case skip, cancel, withoutPassword, close }
    var primary: Primary?
    var secondary: Secondary?
    var terminalLink = false
}

/// Pure state machine of the first run. Every event from every state is defined; unknown pairs are ignored.
struct FirstRunFlow: Equatable {
    private(set) var step: FirstRunStep = .choosing
    var choices = FirstRunChoices()
    private(set) var route: PermissionRoute = .systemPrompt
    /// Features the current request asks for.
    private(set) var requested: Set<PrivilegedFeature> = []
    private(set) var granted: Set<PrivilegedFeature> = []
    private(set) var failureCode: Int32?
    private(set) var loginResult: FirstRunLoginResult?
    /// The closed-lid option really turned on after its permission (nil until that is known).
    private(set) var lidEnabled: Bool?

    /// The choices can change only while nothing is running.
    var choicesEditable: Bool { [.choosing, .declined, .failed, .timedOut].contains(step) }
    var missingLocked: Set<PrivilegedFeature> { choices.lockedFeatures.subtracting(granted) }
    var isWaiting: Bool { step == .waitingSystem || step == .waitingTerminal }

    var attention: [FirstRunAttention] {
        var items: [FirstRunAttention] = []
        if choices.launchAtLogin, loginResult == .requiresApproval { items.append(.loginNeedsApproval) }
        if choices.launchAtLogin, loginResult == .failed { items.append(.loginFailed) }
        if choices.lidClosed, granted.contains(.lidClosed), lidEnabled == false { items.append(.lidRefused) }
        return items
    }

    var buttons: FirstRunButtons {
        let locked = !missingLocked.isEmpty
        switch step {
        case .choosing:
            return FirstRunButtons(primary: locked ? .allowAndStart : .start, secondary: .skip, terminalLink: locked)
        case .declined, .failed, .timedOut:
            return locked ? FirstRunButtons(primary: .tryAgain, secondary: .withoutPassword, terminalLink: true)
                : FirstRunButtons(primary: .start, secondary: .skip)
        case .waitingSystem, .waitingTerminal: return FirstRunButtons(secondary: .cancel)
        case .attention: return FirstRunButtons(primary: .start)
        case .iconHidden: return FirstRunButtons(primary: .openApp, secondary: .close)
        case .applying, .enablingLid, .done, .finished: return FirstRunButtons()
        }
    }

    @discardableResult mutating func handle(_ event: FirstRunEvent) -> [FirstRunEffect] {
        switch (step, event) {
        case (.choosing, .start), (.declined, .start), (.failed, .start), (.timedOut, .start):
            return apply(route: .systemPrompt)
        case (.choosing, .useTerminal), (.declined, .useTerminal), (.failed, .useTerminal), (.timedOut, .useTerminal):
            guard !missingLocked.isEmpty else { return [] }
            return apply(route: .terminal)

        case (.applying, .everydayApplied(let result)):
            loginResult = result
            let missing = missingLocked
            guard !missing.isEmpty else { return finish(afterSuccess: false) }
            requested = missing; failureCode = nil
            step = route == .terminal ? .waitingTerminal : .waitingSystem
            return [.requestPermission(missing, route)]

        case (.waitingSystem, .permissionFinished(let outcome)), (.waitingTerminal, .permissionFinished(let outcome)):
            switch outcome {
            case .succeeded(let features):
                granted.formUnion(features.intersection(requested))
                guard missingLocked.isEmpty else { step = .failed; failureCode = nil; return [] }
                if requested.contains(.lidClosed), choices.lidClosed { step = .enablingLid; return [.turnOnLid] }
                return finish(afterSuccess: true)
            case .cancelled: step = .declined; return []
            case .failed(let code): step = .failed; failureCode = code; return []
            case .timedOut: step = .timedOut; return []
            }
        case (.waitingSystem, .cancel), (.waitingTerminal, .cancel):
            step = .declined
            return [.cancelPermissionRequest]

        // The password was typed in Terminal after the window gave up: follow reality instead of saying "not entered".
        case (.declined, .lateGrant(let features)), (.failed, .lateGrant(let features)), (.timedOut, .lateGrant(let features)):
            let fresh = features.intersection(choices.lockedFeatures).subtracting(granted)
            guard !fresh.isEmpty else { return [] }
            granted.formUnion(fresh)
            guard missingLocked.isEmpty else { return [] }
            if fresh.contains(.lidClosed) { step = .enablingLid; return [.turnOnLid] }
            return finish(afterSuccess: true)
        case (_, .lateGrant(let features)):
            granted.formUnion(features.intersection(choices.lockedFeatures))
            return []

        case (.enablingLid, .lidTurnedOn(let enabled)):
            lidEnabled = enabled
            return finish(afterSuccess: true)
        case (_, .lidTurnedOn(let enabled)):
            lidEnabled = enabled
            return []

        case (.declined, .continueWithout), (.failed, .continueWithout), (.timedOut, .continueWithout):
            // The locked features stay off; what was granted earlier stays on.
            choices.lidClosed = choices.lidClosed && granted.contains(.lidClosed)
            choices.chargeByTime = choices.chargeByTime && granted.contains(.chargeByTime)
            return finish(afterSuccess: false)

        case (.attention, .start):
            step = .done
            return [.reveal(afterSuccess: false)]
        case (.attention, .openLoginSettings):
            return [.openLoginItemsSettings]

        case (.choosing, .skip), (.declined, .skip), (.failed, .skip), (.timedOut, .skip), (.attention, .skip):
            step = .done
            return [.reveal(afterSuccess: false)]
        case (.waitingSystem, .skip), (.waitingTerminal, .skip):
            step = .done
            return [.cancelPermissionRequest, .reveal(afterSuccess: false)]

        case (.done, .revealed):
            step = .finished
            return [.finish]
        case (.done, .iconHidden):
            step = .iconHidden
            return []
        case (.iconHidden, .openDetails):
            step = .finished
            return [.closeWindow, .openDetails, .finish]
        case (.iconHidden, .skip):
            step = .finished
            return [.closeWindow, .finish]

        default:
            return []
        }
    }

    private mutating func apply(route: PermissionRoute) -> [FirstRunEffect] {
        self.route = route
        step = .applying
        return [.applyEveryday(launchAtLogin: choices.launchAtLogin, keepHistory: choices.keepHistory)]
    }

    private mutating func finish(afterSuccess: Bool) -> [FirstRunEffect] {
        if !attention.isEmpty { step = .attention; return [] }
        step = .done
        return [.reveal(afterSuccess: afterSuccess)]
    }
}
