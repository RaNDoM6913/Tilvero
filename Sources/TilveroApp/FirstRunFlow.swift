// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit

/// The first-run scenes. The window explains *where* the app lives, the popover card explains *what* to choose.
enum FirstRunStep: String, Equatable, CaseIterable {
    /// The menu bar icon fills from 0 to the real level.
    case iconFill
    /// Window: drawn menu bar, a cursor clicks the icon (loops at most three times, then freezes).
    case whereIcon
    /// Window: the icon may be hidden behind the notch; ⌘-drag animation and "Open here".
    case hiddenIcon
    /// The card on top of the real Overview.
    case card
    /// The drawn Touch ID / password preview inside the card (1.2 s, skippable).
    case confirmPreview
    /// The macOS administrator prompt is up.
    case systemPrompt
    case done
    /// Cancelled, denied or failed: calm state, locked features off, "Turn on" pills.
    case declined
    /// "Tilvero is here" bubble and two rings under the icon.
    case bubble
    case finished
}

/// One line of the done / declined summary.
struct FirstRunSummaryRow: Equatable, Identifiable {
    enum Kind: Equatable { case enabled, needsApproval, notEnabled }
    var id: String
    var key: String
    var kind: Kind
}

enum FirstRunPromptResult: Hashable{ case success(Set<PrivilegedFeature>), cancelled, failed }
enum FirstRunLoginResult: Hashable { case enabled, requiresApproval, failed }

/// What the user picked in the card. Defaults: login and history on, everything under "More" off.
struct FirstRunChoices: Equatable {
    var launchAtLogin = true
    var keepHistory = true
    var chargeLimit = false
    var lidClosed = false
    var chargeByTime = false
    var moreExpanded = false

    var lockedFeatures: Set<PrivilegedFeature> {
        var set = Set<PrivilegedFeature>()
        if lidClosed { set.insert(.lidClosed) }
        if chargeByTime { set.insert(.chargeByTime) }
        return set
    }
    /// "Done" shows a lock glyph when it will ask macOS for the administrator permission.
    var doneNeedsPermission: Bool { !lockedFeatures.isEmpty }
}

enum FirstRunEvent: Hashable {
    case iconFilled
    case skip
    case showHidden
    case backFromHidden
    case statusItemClicked
    /// "Open here": the card is hosted inside the first-run window.
    case openHere
    case done
    case previewFinished
    case cancelConfirmation
    case promptFinished(FirstRunPromptResult)
    case loginFinished(FirstRunLoginResult)
    /// Result of turning the closed-lid option on after its permission was granted.
    case lidTurnedOn(Bool)
    /// "Turn on" pill in the declined state, for one feature.
    case enable(PrivilegedFeature)
    case dismissCard
    case popoverClosed
    case bubbleFinished
}

enum FirstRunEffect: Equatable {
    case markIntroduced
    case showWindow
    case closeWindow(intoIcon: Bool)
    case showBeacon
    case hideBeacon
    case hostCardInWindow
    case setPopoverBehavior(NSPopover.Behavior)
    case ensurePopoverShown
    case closePopover
    /// History choice applied and login registered (only with the switch on) when "Done" is pressed.
    case applyEverydayChoices(launchAtLogin: Bool, keepHistory: Bool)
    /// Plays the drawn Touch ID preview; `previewFinished` follows after 1.2 s (or on a click).
    case playConfirmPreview
    case requestPermission(Set<PrivilegedFeature>)
    case cancelPermissionRequest
    case turnOnGranted(Set<PrivilegedFeature>)
    /// "Allow" pill when macOS wants the login item approved.
    case openLoginItemsSettings
    case showBubble
    case finish
}

/// Close requests the app delegate ignores while the first-run card holds the popover open. Explicit closes (the
/// icon, Esc, the card's own X / Done, opening the details window) still close it.
enum FirstRunPopoverPolicy {
    static let ignoredWhileHeld: Set<String> = ["outside click", "application deactivated"]
}

/// Pure state machine of the first run. Every event from every state is defined; unknown pairs are ignored.
struct FirstRunFlow: Equatable {
    private(set) var step: FirstRunStep = .iconFill
    var choices = FirstRunChoices()
    private(set) var hostedInWindow = false
    /// Features the current prompt asks for.
    private(set) var requested: Set<PrivilegedFeature> = []
    private(set) var granted: Set<PrivilegedFeature> = []
    private(set) var promptFailed = false
    private(set) var loginResult: FirstRunLoginResult?
    /// The closed-lid option really turned on after its permission (nil while that is still being done).
    private(set) var lidEnabled: Bool?

    /// What the summary shows for the everyday choices: login per the real registration result, history.
    var everydayRows: [FirstRunSummaryRow] {
        var rows: [FirstRunSummaryRow] = []
        if choices.launchAtLogin {
            switch loginResult {
            case .requiresApproval: rows.append(.init(id: "login", key: "firstRun.row.login", kind: .needsApproval))
            case .failed: rows.append(.init(id: "login", key: "firstRun.row.login", kind: .notEnabled))
            case .enabled, nil: rows.append(.init(id: "login", key: "firstRun.row.login", kind: .enabled))
            }
        }
        if choices.keepHistory { rows.append(.init(id: "history", key: "firstRun.row.history", kind: .enabled)) }
        return rows
    }
    /// Granted locked features; the lid row is checked only once the option really turned on.
    var grantedRows: [FirstRunSummaryRow] {
        var rows: [FirstRunSummaryRow] = []
        if granted.contains(.lidClosed) && choices.lidClosed {
            rows.append(.init(id: "lid", key: "firstRun.lidClosed", kind: lidEnabled == true ? .enabled : .notEnabled))
        }
        if granted.contains(.chargeByTime) && choices.chargeByTime { rows.append(.init(id: "chargeBy", key: "firstRun.chargeByTime", kind: .enabled)) }
        return rows
    }

    var cardVisible: Bool { [.card, .confirmPreview, .systemPrompt, .done, .declined].contains(step) }
    var windowVisible: Bool { step == .whereIcon || step == .hiddenIcon || (hostedInWindow && cardVisible) }
    /// The system prompt steals focus; while the card is up the popover must not close by itself.
    var popoverBehavior: NSPopover.Behavior { cardVisible && !hostedInWindow ? .applicationDefined : .transient }
    /// Locked features that are still off after a cancelled or failed prompt.
    var missingLocked: [PrivilegedFeature] { choices.lockedFeatures.subtracting(granted).sorted() }

    @discardableResult mutating func handle(_ event: FirstRunEvent) -> [FirstRunEffect] {
        switch (step, event) {
        case (.iconFill, .iconFilled):
            step = .whereIcon
            return [.markIntroduced, .showWindow, .showBeacon]
        case (.iconFill, .skip):
            step = .finished
            return [.markIntroduced, .finish]

        case (.whereIcon, .showHidden):
            step = .hiddenIcon; return []
        case (.hiddenIcon, .backFromHidden):
            step = .whereIcon; return []
        case (.whereIcon, .skip), (.hiddenIcon, .skip):
            step = .bubble
            return [.hideBeacon, .closeWindow(intoIcon: false), .showBubble]
        case (.whereIcon, .statusItemClicked), (.hiddenIcon, .statusItemClicked):
            step = .card
            return [.hideBeacon, .closeWindow(intoIcon: true), .setPopoverBehavior(.applicationDefined)]
        case (.hiddenIcon, .openHere), (.whereIcon, .openHere):
            step = .card; hostedInWindow = true
            return [.hideBeacon, .hostCardInWindow]

        case (.card, .done):
            let apply = FirstRunEffect.applyEverydayChoices(launchAtLogin: choices.launchAtLogin, keepHistory: choices.keepHistory)
            guard choices.doneNeedsPermission else { step = .done; return [apply] }
            requested = choices.lockedFeatures; step = .confirmPreview
            return [apply, .playConfirmPreview]
        case (.card, .dismissCard):
            return closeCard()
        case (.confirmPreview, .previewFinished):
            step = .systemPrompt
            return [.requestPermission(requested)]
        case (.confirmPreview, .cancelConfirmation):
            step = .declined; promptFailed = false
            return []
        case (.systemPrompt, .cancelConfirmation):
            step = .declined; promptFailed = false
            return [.cancelPermissionRequest]
        case (.systemPrompt, .promptFinished(let result)):
            switch result {
            case .success(let features):
                granted.formUnion(features)
                step = missingLocked.isEmpty ? .done : .declined
                promptFailed = false
                return [.turnOnGranted(features.intersection(choices.lockedFeatures)), .ensurePopoverShown]
            case .cancelled:
                step = .declined; promptFailed = false
                return [.ensurePopoverShown]
            case .failed:
                step = .declined; promptFailed = true
                return [.ensurePopoverShown]
            }
        case (.declined, .enable(let feature)):
            guard missingLocked.contains(feature) else { return [] }
            requested = [feature]; step = .confirmPreview
            return [.playConfirmPreview]
        case (.done, .done), (.declined, .done), (.done, .dismissCard), (.declined, .dismissCard):
            return closeCard()

        case (.card, .popoverClosed), (.done, .popoverClosed), (.declined, .popoverClosed):
            guard !hostedInWindow else { return [] }
            step = .bubble
            return [.setPopoverBehavior(.transient), .showBubble]
        // The user closed the popover (the icon, Esc) before or during the macOS prompt: that is a cancel. No prompt
        // appears afterwards, a running one is dismissed, locked features stay off and the popover is not reopened.
        case (.confirmPreview, .popoverClosed), (.systemPrompt, .popoverClosed):
            guard !hostedInWindow else { return [] }
            let cancel: [FirstRunEffect] = step == .systemPrompt ? [.cancelPermissionRequest] : []
            step = .bubble; promptFailed = false
            return cancel + [.setPopoverBehavior(.transient), .showBubble]
        case (.bubble, .bubbleFinished):
            step = .finished
            return [.finish]

        case (_, .loginFinished(let result)):
            loginResult = result
            return []
        case (_, .lidTurnedOn(let enabled)):
            lidEnabled = enabled
            return []
        default:
            return []
        }
    }

    private mutating func closeCard() -> [FirstRunEffect] {
        if hostedInWindow {
            step = .bubble
            return [.closeWindow(intoIcon: true), .showBubble]
        }
        return [.closePopover]
    }
}
