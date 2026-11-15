// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import ServiceManagement
import XCTest
@testable import TilveroApp

final class FirstRunDecisionTests: XCTestCase {
    private let fresh = FirstRunSignals()
    private let ordinary = FirstRunLaunchContext()

    func testAFreshInstallShowsTheFirstRunOnce() {
        XCTAssertEqual(FirstRunDecision.decide(signals: fresh, context: ordinary), .show)
        var second = fresh; second.introduced = true
        XCTAssertEqual(FirstRunDecision.decide(signals: second, context: ordinary), .nothing, "Second launch never shows it")
    }

    func testEveryPriorUseSignalMarksSilently() {
        let paths: [WritableKeyPath<FirstRunSignals, Bool>] = [\.setupReviewed, \.historyPreferenceStored, \.historyStoreExists,
                                                               \.chargeValidationExists, \.ruleFilesExist, \.loginItemEnabled]
        for path in paths {
            var signals = fresh; signals[keyPath: path] = true
            XCTAssertTrue(signals.hasPriorUse)
            XCTAssertEqual(FirstRunDecision.decide(signals: signals, context: ordinary), .markSilently, "\(path)")
            var login = ordinary; login.launchedAsLoginItem = true
            XCTAssertEqual(FirstRunDecision.decide(signals: signals, context: login), .markSilently, "existing users are recorded at any launch")
        }
    }

    func testDemoSiblingMonitorLoginAndShowDetailsLaunchesNeverShowIt() {
        for context in [FirstRunLaunchContext(isDemo: true), FirstRunLaunchContext(monitoringOnly: true),
                        FirstRunLaunchContext(showDetailsRequested: true), FirstRunLaunchContext(launchedAsLoginItem: true)] {
            XCTAssertEqual(FirstRunDecision.decide(signals: fresh, context: context), .nothing, "\(context)")
        }
        var used = fresh; used.historyStoreExists = true
        XCTAssertEqual(FirstRunDecision.decide(signals: used, context: FirstRunLaunchContext(isDemo: true)), .nothing, "demo records nothing")
        let sibling = AppLaunchPolicy.resolve(metadata: [:], runningBundleIdentifiers: ["io.github.random6913.tilvero"])
        XCTAssertTrue(FirstRunLaunchContext.current(arguments: ["Tilvero"], policy: sibling).monitoringOnly)
    }

    func testRelaunchAfterASparkleUpdateNeverShowsIt() {
        // An updated install has used Tilvero before: the key is already set, or the store and choices exist.
        var updated = FirstRunSignals(introduced: true, historyPreferenceStored: true, historyStoreExists: true)
        XCTAssertEqual(FirstRunDecision.decide(signals: updated, context: ordinary), .nothing)
        updated.introduced = false
        XCTAssertEqual(FirstRunDecision.decide(signals: updated, context: ordinary), .markSilently)
    }

    func testSignalsAreReadFromPreferencesFilesAndTheLoginItem() {
        let suite = "FirstRunSignals-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = URL(fileURLWithPath: "/tmp/tilvero-test/History.sqlite")
        XCTAssertEqual(FirstRunSignals.read(defaults: defaults, historyURL: history, fileExists: { _ in false }, loginItemEnabled: { false }), FirstRunSignals())
        defaults.set(true, forKey: SetupRuntime.reviewedKey); defaults.set(false, forKey: "historyEnabled")
        let files: Set<String> = [history.path, "/tmp/tilvero-test/native-charge-validation.json", "/etc/sudoers.d/tilvero-wake"]
        let signals = FirstRunSignals.read(defaults: defaults, historyURL: history, fileExists: files.contains, loginItemEnabled: { true })
        XCTAssertEqual(signals, FirstRunSignals(introduced: false, setupReviewed: true, historyPreferenceStored: true, historyStoreExists: true,
                                                chargeValidationExists: true, ruleFilesExist: true, loginItemEnabled: true))
        for path in ["/etc/sudoers.d/tilvero", "/etc/sudoers.d/tilvero-lid"] {
            XCTAssertTrue(FirstRunSignals.read(defaults: UserDefaults(suiteName: "x-\(UUID())")!, historyURL: history, fileExists: { $0 == path }, loginItemEnabled: { false }).ruleFilesExist)
        }
        FirstRunDecision.markIntroduced(defaults)
        XCTAssertTrue(FirstRunSignals.read(defaults: defaults, historyURL: history, fileExists: { _ in false }, loginItemEnabled: { false }).introduced)
    }

    func testTheLoginLaunchEventIsRecognised() {
        XCTAssertFalse(LoginLaunchDetector.launchedAsLoginItem(event: nil))
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        XCTAssertFalse(LoginLaunchDetector.launchedAsLoginItem(event: event))
        event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
        XCTAssertTrue(LoginLaunchDetector.launchedAsLoginItem(event: event))
    }

    func testPreviewNeedsTheFlag() {
        XCTAssertFalse(FirstRunPreview.requested(arguments: ["Tilvero"], isProductionIdentity: false))
        XCTAssertTrue(FirstRunPreview.requested(arguments: ["Tilvero", "--first-run-preview"], isProductionIdentity: false))
        XCTAssertTrue(FirstRunPreview.isAllowed(isProductionIdentity: false))
        // The dedicated preview app is always a preview, without the flag.
        XCTAssertTrue(FirstRunPreview.requested(arguments: ["Tilvero"], isProductionIdentity: false, isPreviewIdentity: true))
    }

    func testPreviewIsNeverAllowedForAProductionIdentityInAnyConfiguration() {
        XCTAssertFalse(FirstRunPreview.isAllowed(isProductionIdentity: true))
        XCTAssertFalse(FirstRunPreview.requested(arguments: ["Tilvero", "--first-run-preview"], isProductionIdentity: true))
        XCTAssertFalse(FirstRunPreview.requested(arguments: ["Tilvero", "--first-run-preview"], isProductionIdentity: true, isPreviewIdentity: true))
    }

    func testLaboratoryAndLidTrialIdentitiesNeverRunTheRealFirstRun() throws {
        let lab = try ReleaseIdentity(metadata: ["CFBundleIdentifier": "local.tilvero.lab", "TilveroDataScope": "laboratory"])
        let trial = try ReleaseIdentity(metadata: ["CFBundleIdentifier": "local.tilvero.lidtrial", "TilveroDataScope": "lid-trial", "TilveroLidTrialHost": true])
        let prototype = try ReleaseIdentity(metadata: ["CFBundleIdentifier": "local.tilvero.prototype"])
        let production = try ReleaseIdentity(metadata: ["CFBundleIdentifier": "io.github.random6913.tilvero", "TilveroDataScope": "production"])
        for identity in [lab, trial] {
            XCTAssertEqual(FirstRunDecision.decide(signals: fresh, context: .init(laboratoryIdentity: identity.isLaboratory)), .nothing)
            var used = fresh; used.historyStoreExists = true
            XCTAssertEqual(FirstRunDecision.decide(signals: used, context: .init(laboratoryIdentity: identity.isLaboratory)), .nothing)
        }
        for identity in [prototype, production] {
            XCTAssertFalse(identity.isLaboratory)
            XCTAssertEqual(FirstRunDecision.decide(signals: fresh, context: .init(laboratoryIdentity: identity.isLaboratory)), .show, "source builds and production keep the real first run")
        }
    }
}


final class FirstRunFlowTests: XCTestCase {
    private func locked() -> FirstRunFlow {
        var flow = FirstRunFlow(); flow.choices.lidClosed = true; flow.choices.chargeByTime = true; return flow
    }

    func testRecommendedChoicesNeedNoPasswordAndOneClick() {
        var flow = FirstRunFlow()
        XCTAssertEqual(flow.choices, FirstRunChoices(launchAtLogin: true, keepHistory: true, chargeLimit: true, lidClosed: false, chargeByTime: false))
        XCTAssertEqual(flow.buttons, FirstRunButtons(primary: .start, secondary: .skip, terminalLink: false))
        XCTAssertEqual(flow.handle(.start), [.applyEveryday(launchAtLogin: true, keepHistory: true)])
        XCTAssertEqual(flow.step, .applying)
        XCTAssertEqual(flow.handle(.everydayApplied(.enabled)), [.reveal(afterSuccess: false, coachChargeLimit: true)])
        XCTAssertEqual(flow.step, .done)
        XCTAssertEqual(flow.handle(.revealed), [.finish])
        XCTAssertEqual(flow.step, .finished)
    }

    func testLockedFeaturesShareOneDialogThenTheLidTurnsOn() {
        var flow = locked()
        XCTAssertEqual(flow.buttons, FirstRunButtons(primary: .allowAndStart, secondary: .skip, terminalLink: true))
        flow.handle(.start)
        XCTAssertEqual(flow.handle(.everydayApplied(.enabled)), [.requestPermission([.lidClosed, .chargeByTime], .systemPrompt)])
        XCTAssertEqual(flow.step, .waitingSystem)
        XCTAssertFalse(flow.choicesEditable)
        XCTAssertEqual(flow.buttons, FirstRunButtons(secondary: .cancel))
        XCTAssertEqual(flow.handle(.permissionFinished(.succeeded([.lidClosed, .chargeByTime]))), [.turnOnLid])
        XCTAssertEqual(flow.step, .enablingLid)
        XCTAssertEqual(flow.handle(.lidTurnedOn(true)), [.reveal(afterSuccess: true, coachChargeLimit: true)])
        XCTAssertEqual(flow.granted, [.lidClosed, .chargeByTime])
    }

    func testChargeByTimeAloneNeedsNoLidStep() {
        var flow = FirstRunFlow(); flow.choices.chargeByTime = true; flow.choices.chargeLimit = false
        flow.handle(.start)
        XCTAssertEqual(flow.handle(.everydayApplied(nil)), [.requestPermission([.chargeByTime], .systemPrompt)])
        XCTAssertEqual(flow.handle(.permissionFinished(.succeeded([.chargeByTime]))), [.reveal(afterSuccess: true, coachChargeLimit: false)])
    }

    func testTheTerminalFallbackIsOneClick() {
        var plain = FirstRunFlow()
        XCTAssertEqual(plain.handle(.useTerminal), [], "nothing to allow: no Terminal")
        var flow = locked()
        XCTAssertEqual(flow.handle(.useTerminal), [.applyEveryday(launchAtLogin: true, keepHistory: true)])
        XCTAssertEqual(flow.handle(.everydayApplied(.enabled)), [.requestPermission([.lidClosed, .chargeByTime], .terminal)])
        XCTAssertEqual(flow.step, .waitingTerminal)
        XCTAssertEqual(flow.handle(.permissionFinished(.succeeded([.lidClosed, .chargeByTime]))), [.turnOnLid])
    }

    func testDismissedWrongPasswordErrorAndTimeoutAreCalmWithOneTryAgain() {
        let cases: [(PrivilegedOutcome, FirstRunStep)] = [(.cancelled, .declined), (.failed(7), .failed), (.failed(1), .failed), (.timedOut, .timedOut)]
        for (outcome, step) in cases {
            var flow = locked()
            flow.handle(.start); flow.handle(.everydayApplied(.enabled))
            XCTAssertEqual(flow.handle(.permissionFinished(outcome)), [])
            XCTAssertEqual(flow.step, step, "\(outcome)")
            XCTAssertTrue(flow.choicesEditable)
            XCTAssertEqual(flow.buttons, FirstRunButtons(primary: .tryAgain, secondary: .withoutPassword, terminalLink: true))
            XCTAssertTrue(flow.granted.isEmpty)
            // Try again asks once more for what is still missing.
            flow.handle(.start)
            XCTAssertEqual(flow.handle(.everydayApplied(.enabled)), [.requestPermission([.lidClosed, .chargeByTime], .systemPrompt)])
        }
        var failed = locked(); failed.handle(.start); failed.handle(.everydayApplied(nil)); failed.handle(.permissionFinished(.failed(7)))
        XCTAssertEqual(failed.failureCode, 7)
    }

    func testUntickingTheLockedFeaturesAfterACancelLeavesAPlainStart() {
        var flow = locked(); flow.handle(.start); flow.handle(.everydayApplied(nil)); flow.handle(.permissionFinished(.cancelled))
        flow.choices.lidClosed = false; flow.choices.chargeByTime = false
        XCTAssertEqual(flow.buttons, FirstRunButtons(primary: .start, secondary: .skip))
        flow.handle(.start)
        XCTAssertEqual(flow.handle(.everydayApplied(nil)), [.reveal(afterSuccess: false, coachChargeLimit: true)])
    }

    func testCancelWhileWaitingStopsTheRequest() {
        for route in [FirstRunEvent.start, .useTerminal] {
            var flow = locked(); flow.handle(route); flow.handle(.everydayApplied(nil))
            XCTAssertEqual(flow.handle(.cancel), [.cancelPermissionRequest])
            XCTAssertEqual(flow.step, .declined)
            XCTAssertEqual(flow.handle(.permissionFinished(.succeeded([.lidClosed]))), [], "a late answer after a cancel is ignored")
        }
    }

    func testWithoutPasswordOpensTheAppWithTheLockedFeaturesOff() {
        var flow = locked(); flow.handle(.start); flow.handle(.everydayApplied(nil)); flow.handle(.permissionFinished(.cancelled))
        XCTAssertEqual(flow.handle(.continueWithout), [.reveal(afterSuccess: false, coachChargeLimit: true)])
        XCTAssertFalse(flow.choices.lidClosed); XCTAssertFalse(flow.choices.chargeByTime)
    }

    func testAPartialGrantIsAFailureWithTryAgain() {
        var flow = locked(); flow.handle(.start); flow.handle(.everydayApplied(nil))
        XCTAssertEqual(flow.handle(.permissionFinished(.succeeded([.chargeByTime]))), [])
        XCTAssertEqual(flow.step, .failed)
        XCTAssertEqual(flow.missingLocked, [.lidClosed])
    }

    /// The window stopped waiting, then the password was typed in Terminal after all: the window follows reality.
    func testALateTerminalGrantIsFollowed() {
        var declined = locked(); declined.handle(.useTerminal); declined.handle(.everydayApplied(nil)); declined.handle(.cancel)
        XCTAssertEqual(declined.step, .declined)
        XCTAssertEqual(declined.handle(.lateGrant([.lidClosed, .chargeByTime])), [.turnOnLid])
        XCTAssertEqual(declined.step, .enablingLid)
        var timedOut = FirstRunFlow(); timedOut.choices.chargeByTime = true
        timedOut.handle(.useTerminal); timedOut.handle(.everydayApplied(nil)); timedOut.handle(.permissionFinished(.timedOut))
        XCTAssertEqual(timedOut.handle(.lateGrant([.chargeByTime])), [.reveal(afterSuccess: true, coachChargeLimit: true)])
        var partial = locked(); partial.handle(.useTerminal); partial.handle(.everydayApplied(nil)); partial.handle(.cancel)
        XCTAssertEqual(partial.handle(.lateGrant([.chargeByTime])), [], "still missing the lid: stays with Try again")
        XCTAssertEqual(partial.granted, [.chargeByTime])
        var idle = FirstRunFlow()
        XCTAssertEqual(idle.handle(.lateGrant([.lidClosed])), [], "not chosen: nothing changes")
        XCTAssertEqual(idle.step, .choosing)
    }

    /// Ticking a password feature adds the Terminal link: the window resizes (the link line is also reserved).
    func testTheLayoutKeyFollowsEverythingThatChangesTheHeight() {
        var flow = FirstRunFlow()
        let plain = FirstRunWindowView.layoutKey(flow, showsCommand: false)
        flow.choices.keepHistory = false
        XCTAssertEqual(FirstRunWindowView.layoutKey(flow, showsCommand: false), plain, "a plain toggle changes nothing")
        flow.choices.lidClosed = true
        XCTAssertNotEqual(FirstRunWindowView.layoutKey(flow, showsCommand: false), plain, "the Terminal link appears")
        var waiting = locked(); waiting.handle(.useTerminal); waiting.handle(.everydayApplied(nil))
        XCTAssertNotEqual(FirstRunWindowView.layoutKey(waiting, showsCommand: true), FirstRunWindowView.layoutKey(waiting, showsCommand: false))
        XCTAssertEqual(FirstRunWindowView.layoutKey(flow, showsCommand: true), FirstRunWindowView.layoutKey(flow, showsCommand: false), "no command box outside the wait")
    }

    func testSkipChangesNothingAndOpensTheApp() {
        var flow = FirstRunFlow()
        XCTAssertEqual(flow.handle(.skip), [.reveal(afterSuccess: false, coachChargeLimit: false)])
        var waiting = locked(); waiting.handle(.useTerminal); waiting.handle(.everydayApplied(nil))
        XCTAssertEqual(waiting.handle(.skip), [.cancelPermissionRequest, .reveal(afterSuccess: false, coachChargeLimit: false)])
    }

    func testLoginApprovalAndARefusedLidNeedOneMoreLook() {
        var flow = FirstRunFlow(); flow.handle(.start)
        XCTAssertEqual(flow.handle(.everydayApplied(.requiresApproval)), [])
        XCTAssertEqual(flow.step, .attention)
        XCTAssertEqual(flow.attention, [.loginNeedsApproval])
        XCTAssertEqual(flow.buttons, FirstRunButtons(primary: .start))
        XCTAssertEqual(flow.handle(.openLoginSettings), [.openLoginItemsSettings])
        XCTAssertEqual(flow.handle(.start), [.reveal(afterSuccess: false, coachChargeLimit: true)])

        var failed = FirstRunFlow(); failed.handle(.start); failed.handle(.everydayApplied(.failed))
        XCTAssertEqual(failed.attention, [.loginFailed])
        var off = FirstRunFlow(); off.choices.launchAtLogin = false; off.handle(.start)
        XCTAssertEqual(off.handle(.everydayApplied(nil)).count, 1, "login off: nothing to look at")

        var lid = locked(); lid.handle(.start); lid.handle(.everydayApplied(.enabled)); lid.handle(.permissionFinished(.succeeded([.lidClosed, .chargeByTime])))
        XCTAssertEqual(lid.handle(.lidTurnedOn(false)), [])
        XCTAssertEqual(lid.attention, [.lidRefused])
    }

    func testNoRoomForTheIconKeepsTheWindowWithAWayOut() {
        var flow = FirstRunFlow(); flow.handle(.skip)
        XCTAssertEqual(flow.handle(.iconHidden), [])
        XCTAssertEqual(flow.step, .iconHidden)
        XCTAssertEqual(flow.buttons, FirstRunButtons(primary: .openApp, secondary: .close))
        var details = flow
        XCTAssertEqual(details.handle(.openDetails), [.closeWindow, .openDetails, .finish])
        XCTAssertEqual(flow.handle(.skip), [.closeWindow, .finish])
    }

    /// The whole table: every event from every state; only the listed pairs change the step.
    func testEveryEventFromEveryState() {
        let events: [FirstRunEvent] = [.start, .useTerminal, .everydayApplied(.enabled), .everydayApplied(nil), .permissionFinished(.succeeded([.lidClosed, .chargeByTime])),
            .permissionFinished(.cancelled), .permissionFinished(.failed(1)), .permissionFinished(.timedOut), .lidTurnedOn(true), .lidTurnedOn(false),
            .cancel, .continueWithout, .skip, .openLoginSettings, .revealed, .iconHidden, .openDetails]
        let moves: [FirstRunStep: [FirstRunEvent: FirstRunStep]] = [
            .choosing: [.start: .applying, .skip: .done],   // the defaults need no password: no Terminal
            .applying: [.everydayApplied(.enabled): .waitingSystem, .everydayApplied(nil): .waitingSystem],
            .waitingSystem: [.permissionFinished(.succeeded([.lidClosed, .chargeByTime])): .enablingLid, .permissionFinished(.cancelled): .declined,
                             .permissionFinished(.failed(1)): .failed, .permissionFinished(.timedOut): .timedOut, .cancel: .declined, .skip: .done],
            .waitingTerminal: [.permissionFinished(.succeeded([.lidClosed, .chargeByTime])): .enablingLid, .permissionFinished(.cancelled): .declined,
                               .permissionFinished(.failed(1)): .failed, .permissionFinished(.timedOut): .timedOut, .cancel: .declined, .skip: .done],
            .enablingLid: [.lidTurnedOn(true): .done, .lidTurnedOn(false): .attention],
            .declined: [.start: .applying, .useTerminal: .applying, .continueWithout: .done, .skip: .done],
            .failed: [.start: .applying, .useTerminal: .applying, .continueWithout: .done, .skip: .done],
            .timedOut: [.start: .applying, .useTerminal: .applying, .continueWithout: .done, .skip: .done],
            .attention: [.start: .done, .skip: .done],
            .done: [.revealed: .finished, .iconHidden: .iconHidden],
            .iconHidden: [.openDetails: .finished, .skip: .finished],
            .finished: [:],
        ]
        for step in FirstRunStep.allCases {
            for event in events {
                var flow = FirstRunSession.flow(at: step)
                XCTAssertEqual(flow.step, step)
                flow.handle(event)
                XCTAssertEqual(flow.step, moves[step]?[event] ?? step, "\(step) + \(event)")
            }
        }
    }
}

final class FirstRunGeometryTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 944)

    func testTheWindowOpensCentered() {
        let frame = FirstRunWindowGeometry.centered(size: NSSize(width: 480, height: 520), in: screen)
        XCTAssertEqual(frame.midX, screen.midX, accuracy: 1)
        XCTAssertEqual(frame.midY, screen.midY, accuracy: 1)
        let second = NSRect(x: 1512, y: -200, width: 1920, height: 1050)
        XCTAssertEqual(FirstRunWindowGeometry.centered(size: NSSize(width: 480, height: 520), in: second).midX, second.midX, accuracy: 1, "on the icon's screen")
    }

    func testAResizeKeepsTheCenterAndStaysOnScreen() {
        let moved = NSRect(x: 300, y: 200, width: 480, height: 500)
        let grown = FirstRunWindowGeometry.resized(moved, to: NSSize(width: 480, height: 700), within: screen)
        XCTAssertEqual(grown.midY, moved.midY, accuracy: 1)
        XCTAssertEqual(grown.midX, moved.midX, accuracy: 1)
        let low = FirstRunWindowGeometry.resized(NSRect(x: 0, y: 0, width: 480, height: 300), to: NSSize(width: 480, height: 700), within: screen)
        XCTAssertGreaterThanOrEqual(low.minY, screen.minY)
        XCTAssertLessThanOrEqual(low.maxY, screen.maxY)
        let tiny = NSRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertEqual(FirstRunWindowGeometry.centered(size: NSSize(width: 480, height: 520), in: tiny).origin, tiny.origin, "larger than the screen: pinned to it")
    }

    func testTheIconVisibilityIncludesTheNotch() {
        let plain = StatusItemVisibility.Screen(frame: screen)
        let button = NSRect(x: 1300, y: 920, width: 40, height: 24)
        XCTAssertTrue(StatusItemVisibility.isVisible(button: button, screens: [plain]))
        XCTAssertFalse(StatusItemVisibility.isVisible(button: nil, screens: [plain]))
        XCTAssertFalse(StatusItemVisibility.isVisible(button: button, screens: [plain], windowVisible: false))
        XCTAssertFalse(StatusItemVisibility.isVisible(button: NSRect(x: 5000, y: 920, width: 40, height: 24), screens: [plain]))
        let notched = StatusItemVisibility.Screen(frame: screen, auxiliaryLeft: NSRect(x: 0, y: 912, width: 660, height: 32),
                                                  auxiliaryRight: NSRect(x: 852, y: 912, width: 660, height: 32))
        XCTAssertTrue(StatusItemVisibility.isVisible(button: NSRect(x: 900, y: 916, width: 40, height: 24), screens: [notched]))
        XCTAssertFalse(StatusItemVisibility.isVisible(button: NSRect(x: 740, y: 916, width: 40, height: 24), screens: [notched]), "behind the notch")
    }
}

final class FirstRunLaunchPresentationTests: XCTestCase {
    func testExactlyOneLaunchTimeExceptionExists() {
        XCTAssertEqual(LaunchPresentation.window(arguments: ["Tilvero"], firstRun: .show), .firstRun)
        for decision in [FirstRunDecision.nothing, .markSilently] {
            XCTAssertEqual(LaunchPresentation.window(arguments: ["Tilvero"], firstRun: decision), .none)
        }
        XCTAssertEqual(LaunchPresentation.window(arguments: ["Tilvero", "--show-details"], firstRun: .nothing), .details)
        XCTAssertEqual(LaunchPresentation.window(arguments: ["Tilvero", "--show-details"], firstRun: .show), .details)
    }

    func testLoginRegistrationResultMapping() {
        XCTAssertEqual(FirstRunLogin.result(statusAfter: .enabled), .enabled)
        XCTAssertEqual(FirstRunLogin.result(statusAfter: .requiresApproval), .requiresApproval)
        XCTAssertEqual(FirstRunLogin.result(statusAfter: .notRegistered), .failed)
        XCTAssertEqual(FirstRunLogin.result(statusAfter: .notFound), .failed)
    }
}

@MainActor final class SudoersRulesTests: XCTestCase {
    private let lid = "#501 ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0"
    private let wake = "#501 ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake *, /usr/bin/pmset schedule cancel wake *"

    func testOneUidBoundLinePerChosenFeature() {
        XCTAssertEqual(SudoersRules.rules(uid: 501, features: []), [])
        XCTAssertEqual(SudoersRules.rules(uid: 501, features: [.chargeByTime, .lidClosed]), [lid, wake])
        XCTAssertEqual(SudoersRules.rule(uid: 502, feature: .chargeByTime), wake.replacingOccurrences(of: "#501", with: "#502"))
        for feature in PrivilegedFeature.allCases { XCTAssertFalse(SudoersRules.rule(uid: 501, feature: feature).contains("'")) }
    }

    func testTheCommandsAreExactlyThoseOfTheExistingServices() {
        XCTAssertEqual(SudoersRules.rule(uid: 501, feature: .lidClosed), NativeLidSleepSystem.rule(uid: 501))
        XCTAssertEqual(SudoersRules.rule(uid: 501, feature: .chargeByTime), NativeWakeScheduler.rule(uid: 501))
        XCTAssertEqual(PrivilegedFeature.lidClosed.legacyPath, NativeLidSleepSystem.rulePath)
        XCTAssertEqual(PrivilegedFeature.chargeByTime.legacyPath, NativeWakeScheduler.rulePath)
    }

    static let preamble = """
    cd / || exit 1
    umask 077
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    export PATH
    LC_ALL=C
    export LC_ALL
    D=/etc/sudoers.d
    F=/etc/sudoers.d/tilvero
    T=
    trap '[ -z "$T" ] || /bin/rm -f "$T"' EXIT
    # keep_others FILE -e LINE...: rewrite FILE without exactly these lines (validated), delete it when nothing is left
    keep_others() {
      f=$1
      shift
      [ ! -L "$f" ] || return 3
      [ -e "$f" ] || return 0
      [ -f "$f" ] || return 3
      T=$(/usr/bin/mktemp "$D/tilvero.XXXXXX") || return 4
      /usr/bin/grep -v -x -F "$@" "$f" > "$T"
      [ $? -le 1 ] || return 5
      if [ -s "$T" ]; then
        /usr/sbin/chown root:wheel "$T" && /bin/chmod 0440 "$T" || return 6
        /usr/sbin/visudo -c -q -f "$T" || return 7
        /bin/mv -f "$T" "$f" || return 8
      else
        /bin/rm -f "$T" "$f" || return 8
      fi
      T=
    }
    """

    func testInstallScriptGolden() throws {
        let script = try XCTUnwrap(SudoersRules.installScript(uid: 501, features: [.lidClosed, .chargeByTime]))
        XCTAssertEqual(script, "# Tilvero: add the passwordless pmset rule of user #501\n" + Self.preamble + "\n" + """
        /bin/mkdir -p -m 0755 "$D" || exit 2
        [ ! -L "$F" ] || exit 3
        [ ! -e "$F" ] || [ -f "$F" ] || exit 3
        T=$(/usr/bin/mktemp "$D/tilvero.XXXXXX") || exit 4
        if [ -f "$F" ]; then
          /usr/bin/grep -v -x -F -e '\(lid)' -e '\(wake)' "$F" > "$T"
          [ $? -le 1 ] || exit 5
        fi
        /usr/bin/printf '%s\\n' '\(lid)' '\(wake)' >> "$T" || exit 5
        /usr/sbin/chown root:wheel "$T" && /bin/chmod 0440 "$T" || exit 6
        /usr/sbin/visudo -c -q -f "$T" || exit 7
        /bin/mv -f "$T" "$F" || exit 8
        T=
        keep_others /etc/sudoers.d/tilvero-lid -e '\(lid)' || exit $?
        keep_others /etc/sudoers.d/tilvero-wake -e '\(wake)' || exit $?
        """)
        XCTAssertNil(SudoersRules.installScript(uid: 501, features: []))
    }

    func testRemovalScriptGoldenIsTheExactInverse() throws {
        let script = try XCTUnwrap(SudoersRules.removalScript(uid: 501, removing: [.lidClosed, .chargeByTime]))
        XCTAssertEqual(script, "# Tilvero: remove the passwordless pmset rule of user #501\n" + Self.preamble + "\n" + """
        keep_others /etc/sudoers.d/tilvero -e '\(lid)' -e '\(wake)' || exit $?
        keep_others /etc/sudoers.d/tilvero-lid -e '\(lid)' || exit $?
        keep_others /etc/sudoers.d/tilvero-wake -e '\(wake)' || exit $?
        """)
        let one = try XCTUnwrap(SudoersRules.removalScript(uid: 501, removing: [.lidClosed]))
        XCTAssertFalse(one.contains("schedule"), "no knowledge of the other line is needed to keep it")
    }

    func testValidateThenMoveThenTidyTheOldFile() throws {
        let script = try XCTUnwrap(SudoersRules.installScript(uid: 501, features: [.lidClosed]))
        let validate = try XCTUnwrap(script.range(of: "/usr/sbin/visudo -c -q -f \"$T\" || exit 7")).lowerBound
        let move = try XCTUnwrap(script.range(of: "/bin/mv -f \"$T\" \"$F\"")).lowerBound
        let tidy = try XCTUnwrap(script.range(of: "keep_others /etc/sudoers.d/tilvero-lid")).lowerBound
        XCTAssertLessThan(validate, move); XCTAssertLessThan(move, tidy)
        XCTAssertFalse(script.contains("tilvero-wake"), "the other feature's file is not touched")
        XCTAssertFalse(script.contains("schedule"), "only the chosen feature's commands")
    }

    /// Every command line starts with an absolute path, a shell builtin or a function of the script itself.
    func testEveryCommandIsAnAbsolutePath() throws {
        let allowedStarts = ["#", "/", "cd ", "umask ", "PATH=", "export ", "LC_ALL=", "D=", "F=", "T=", "trap ", "keep_others", "f=$1", "shift",
                             "[ ", "if ", "fi", "else", "}", "exit", "return"]
        for operation in [PrivilegedOperation.install([.lidClosed, .chargeByTime]), .remove([.lidClosed, .chargeByTime])] {
            let script = try XCTUnwrap(SudoersRules.script(for: operation, uid: 501))
            XCTAssertTrue(script.hasPrefix("#"), "osascript argv never starts with '-'")
            for line in script.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
                XCTAssertTrue(allowedStarts.contains { line.hasPrefix($0) }, line)
                for tool in ["mkdir", "mktemp", "grep", "printf", "chown", "chmod", "visudo", "mv", "rm"] {
                    XCTAssertFalse(line.range(of: "(^|[ ;&|(])\(tool) ", options: .regularExpression) != nil, "bare \(tool): \(line)")
                }
            }
            XCTAssertFalse(script.split(separator: "\n").contains { $0 == TerminalCommandText.marker })
        }
    }
}

/// Runs the real scripts with `/bin/sh` against a temporary folder (paths rewritten; `visudo` replaced by `true` or
/// `false`, `chown` by `true` since the test is not root). Nothing privileged runs.
final class SudoersScriptBehaviourTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SudoersScript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var dir: String { root.appendingPathComponent("sudoers.d").path }
    private func path(_ name: String) -> String { dir + "/" + name }
    private func sandboxed(_ script: String, validates: Bool = true) -> String {
        script.replacingOccurrences(of: "/etc/sudoers.d", with: dir)
            .replacingOccurrences(of: "/usr/sbin/visudo -c -q -f", with: validates ? "true" : "false")
            .replacingOccurrences(of: "/usr/sbin/chown root:wheel", with: "true")
            .replacingOccurrences(of: "/usr/bin/sudo ", with: "")
    }
    @discardableResult private func run(_ script: String, validates: Bool = true, file: Bool = false) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        if file {
            let url = root.appendingPathComponent("t/Tilvero.command")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sandboxed(script, validates: validates).write(to: url, atomically: true, encoding: .utf8)
            process.arguments = [url.path]
        } else {
            process.arguments = ["-c", sandboxed(script, validates: validates)]
        }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        return process.terminationStatus
    }
    private func write(_ name: String, _ lines: [String]) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try (lines.map { $0 + "\n" }.joined()).write(toFile: path(name), atomically: true, encoding: .utf8)
    }
    private func lines(_ name: String) -> [String]? {
        (try? String(contentsOfFile: path(name), encoding: .utf8)).map { $0.split(separator: "\n").map(String.init) }
    }
    private func temporaries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("tilvero.") }
    }
    private let lid = SudoersRules.rule(uid: 501, feature: .lidClosed)
    private let wake = SudoersRules.rule(uid: 501, feature: .chargeByTime)
    private let foreign = "#502 ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0"
    private func install(_ f: Set<PrivilegedFeature>) -> String { SudoersRules.installScript(uid: 501, features: f)! }
    private func remove(_ f: Set<PrivilegedFeature>) -> String { SudoersRules.removalScript(uid: 501, removing: f)! }

    func testInstallWritesTheChosenLinesReadOnlyAndTidiesOnlyOurOldLines() throws {
        try write("tilvero-lid", [lid]); try write("tilvero-wake", [foreign.replacingOccurrences(of: "disablesleep 1, /usr/bin/pmset disablesleep 0", with: "schedule wake *, /usr/bin/pmset schedule cancel wake *")])
        XCTAssertEqual(try run(install([.lidClosed])), 0)
        XCTAssertEqual(lines("tilvero"), [lid])
        XCTAssertNil(lines("tilvero-lid"), "our old file had only our line")
        XCTAssertEqual(lines("tilvero-wake")?.count, 1, "another feature's (and another user's) old file stays")
        XCTAssertEqual(temporaries(), [])
        let mode = try FileManager.default.attributesOfItem(atPath: path("tilvero"))[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o440)
    }

    func testAnotherUsersLineInAnOldFileSurvives() throws {
        try write("tilvero-lid", [foreign, lid])
        XCTAssertEqual(try run(install([.lidClosed])), 0)
        XCTAssertEqual(lines("tilvero-lid"), [foreign])
    }

    func testInstallKeepsLinesItCannotAccountForAndIsIdempotent() throws {
        try write("tilvero", [wake, foreign])
        XCTAssertEqual(try run(install([.lidClosed])), 0)
        XCTAssertEqual(lines("tilvero"), [wake, foreign, lid])
        XCTAssertEqual(try run(install([.lidClosed])), 0)
        XCTAssertEqual(lines("tilvero"), [wake, foreign, lid], "no duplicate line")
    }

    func testAFailedValidationChangesNothing() throws {
        try write("tilvero", [wake]); try write("tilvero-lid", [lid])
        XCTAssertEqual(try run(install([.lidClosed]), validates: false), 7)
        XCTAssertEqual(lines("tilvero"), [wake])
        XCTAssertEqual(lines("tilvero-lid"), [lid], "old file tidied only after a validated move")
        XCTAssertEqual(temporaries(), [], "the temporary file is cleaned up")
    }

    func testALinkOrAFolderAtTheRulePathIsRefused() throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("elsewhere").path
        try "keep\n".write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: path("tilvero"), withDestinationPath: target)
        XCTAssertEqual(try run(install([.lidClosed])), 3)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "keep\n", "never written through a link")
        try FileManager.default.removeItem(atPath: path("tilvero"))
        try FileManager.default.createDirectory(atPath: path("tilvero"), withIntermediateDirectories: true)
        XCTAssertEqual(try run(install([.lidClosed])), 3)
        XCTAssertEqual(try run(remove([.lidClosed])), 3)
        XCTAssertEqual(temporaries(), [])
    }

    func testRemoveAllTakesOnlyOurLinesOutAndIsIdempotent() throws {
        try write("tilvero", [lid, wake, foreign]); try write("tilvero-lid", [lid]); try write("tilvero-wake", [wake])
        XCTAssertEqual(try run(remove([.lidClosed, .chargeByTime])), 0)
        XCTAssertEqual(lines("tilvero"), [foreign])
        XCTAssertNil(lines("tilvero-lid")); XCTAssertNil(lines("tilvero-wake"))
        XCTAssertEqual(try run(remove([.lidClosed, .chargeByTime])), 0)
        XCTAssertEqual(lines("tilvero"), [foreign])
        XCTAssertEqual(temporaries(), [])
    }

    func testRemovingTheLastLineDeletesTheFileAndNothingThereIsFine() throws {
        try write("tilvero", [lid])
        XCTAssertEqual(try run(remove([.lidClosed])), 0)
        XCTAssertNil(lines("tilvero"))
        XCTAssertEqual(try run(remove([.lidClosed, .chargeByTime])), 0, "nothing installed: nothing to do")
    }

    func testInstallThenRemoveRestoresTheOriginalFiles() throws {
        try write("tilvero", [foreign])
        XCTAssertEqual(try run(install([.lidClosed, .chargeByTime])), 0)
        XCTAssertEqual(try run(remove([.lidClosed, .chargeByTime])), 0)
        XCTAssertEqual(lines("tilvero"), [foreign])
    }

    func testTheTerminalCommandRunsTheSameRootScriptAndReportsItsResult() throws {
        let messages = TerminalCommandText.Messages(header: "H", password: "P", done: "D", failed: "F")
        let text = TerminalCommandText.text(rootScript: install([.lidClosed]), messages: messages)
        XCTAssertEqual(try run(text, file: true), 0)
        XCTAssertEqual(lines("tilvero"), [lid])
        XCTAssertEqual(TerminalCommandFile.readResult(in: root.appendingPathComponent("t")), 0)
        try write("tilvero", [wake])
        XCTAssertEqual(try run(text, validates: false, file: true), 0, "the wrapper itself ends normally")
        XCTAssertEqual(TerminalCommandFile.readResult(in: root.appendingPathComponent("t")), 7, "the root script's status reaches the window")
        XCTAssertEqual(lines("tilvero"), [wake])
    }

    func testTheScriptStaysQuietWhenTheAppAlreadyRemovedItsFolder() throws {
        let messages = TerminalCommandText.Messages(header: "H", password: "P", done: "D", failed: "F")
        let text = TerminalCommandText.text(rootScript: install([.lidClosed]), messages: messages)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", sandboxed(text), root.appendingPathComponent("gone/Tilvero.command").path]   // as if the app had removed its folder
        let errors = Pipe(); process.standardError = errors; process.standardOutput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "", "no write error printed")
        XCTAssertEqual(lines("tilvero"), [lid], "the rule itself is still installed")
    }

    func testThePreviewDemoOnlyPrintsAndWritesItsOwnResult() throws {
        let demo = FirstRunPreview.demoCommandText(rootScript: install([.lidClosed]), code: 0)
        XCTAssertFalse(demo.split(separator: "\n").contains { $0.hasPrefix("/usr/bin/sudo") || $0.hasPrefix("/usr/bin/pmset") })
        let url = root.appendingPathComponent("demo/Tilvero.command")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try demo.write(to: url, atomically: true, encoding: .utf8)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [url.path]
        let input = Pipe(); process.standardInput = input; process.standardOutput = FileHandle.nullDevice
        try process.run(); input.fileHandleForWriting.write(Data("\n".utf8)); try input.fileHandleForWriting.close(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(TerminalCommandFile.readResult(in: url.deletingLastPathComponent()), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir), "nothing outside its own folder")
        XCTAssertFalse(FirstRunPreview.demoCommandText(rootScript: "x", code: nil).contains("/result"), "cancel/timeout demos never answer")
    }
}

@MainActor final class TerminalCommandTests: XCTestCase {
    func testTheCommandIsFixedTextAroundTheRootScript() throws {
        let rootScript = try XCTUnwrap(SudoersRules.installScript(uid: 501, features: [.lidClosed]))
        let messages = TerminalCommandText.Messages(header: "Header", password: "Password", done: "Done", failed: "Failed")
        let text = TerminalCommandText.text(rootScript: rootScript, messages: messages)
        XCTAssertTrue(text.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(text.contains("/usr/bin/sudo /bin/sh -s <<'TILVERO'\n" + rootScript + "\nTILVERO\n"), "the root script verbatim in a quoted heredoc")
        XCTAssertEqual(text.components(separatedBy: "/usr/bin/sudo").count - 1, 1, "sudo runs exactly once")
        let other = TerminalCommandText.text(rootScript: try XCTUnwrap(SudoersRules.installScript(uid: 502, features: [.lidClosed])), messages: messages)
        XCTAssertEqual(text.replacingOccurrences(of: "#501", with: "#502"), other, "the uid is the only variable part")
    }

    func testTheRealMessagesAreSafeInBothLanguages() {
        for language in ["en", "ru"] {
            UserDefaults.standard.setVolatileDomain(["AppleLanguages": [language]], forName: UserDefaults.argumentDomain)
            defer { UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain) }
            for removal in [false, true] {
                let messages = TerminalCommandText.Messages.localized(removal: removal)
                XCTAssertTrue(messages.all.allSatisfy(TerminalCommandText.Messages.isSafe), "\(language): \(messages)")
                XCTAssertEqual(messages.sanitized, messages, "nothing needs dropping")
            }
        }
        let unsafe = TerminalCommandText.Messages(header: "a'b", password: "$(x)", done: "`y`", failed: "c\\d")
        XCTAssertTrue(unsafe.sanitized.all.allSatisfy(TerminalCommandText.Messages.isSafe))
    }

    func testTheFileIsPrivateAndHoldsExactlyTheShownText() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalFile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let text = "#!/bin/sh\necho «привет»\n"
        let file = try TerminalCommandFile.prepare(text, base: base)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        let folderMode = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o700); XCTAssertEqual(folderMode, 0o700)
        XCTAssertNotEqual(try TerminalCommandFile.prepare(text, base: base).deletingLastPathComponent(), file.deletingLastPathComponent(), "a fresh folder per run")
        XCTAssertNil(TerminalCommandFile.readResult(in: file.deletingLastPathComponent()))
        try "7\n".write(to: file.deletingLastPathComponent().appendingPathComponent("result"), atomically: true, encoding: .utf8)
        XCTAssertEqual(TerminalCommandFile.readResult(in: file.deletingLastPathComponent()), 7)
    }

    func testOsascriptGetsTheScriptAsAnArgumentNeverAsSource() {
        let script = "# x\necho 'a\"b' \\ $HOME"
        let arguments = OsascriptAdministratorExecutor.arguments(script: script, prompt: "P \"q\"")
        XCTAssertEqual(arguments, ["-e", "on run argv", "-e", "do shell script (item 1 of argv) with administrator privileges with prompt (item 2 of argv)",
                                   "-e", "end run", script, "P \"q\""])
    }

    func testOsascriptOutcomes() {
        XCTAssertEqual(OsascriptAdministratorExecutor.outcome(status: 0, output: "", cancelled: false), .succeeded)
        XCTAssertEqual(OsascriptAdministratorExecutor.outcome(status: 1, output: "execution error: User canceled. (-128)", cancelled: false), .cancelled)
        XCTAssertEqual(OsascriptAdministratorExecutor.outcome(status: 1, output: "0:80: execution error: (7)\n", cancelled: false), .failed(7))
        XCTAssertEqual(OsascriptAdministratorExecutor.outcome(status: 1, output: "other", cancelled: false), .failed(nil))
        XCTAssertEqual(OsascriptAdministratorExecutor.outcome(status: 15, output: "", cancelled: true), .cancelled)
    }
}

final class SudoListingTests: XCTestCase {
    func testOurRulesAreReadFromTheListing() {
        let output = """
        Matching Defaults entries for ivan on mac:
            env_reset, env_keep+=BLOCKSIZE

        User ivan may run the following commands on mac:
            (ALL) ALL
            (root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0
            (root) NOPASSWD: /usr/bin/pmset schedule wake *, /usr/bin/pmset schedule cancel wake *
        """
        XCTAssertEqual(SudoListing.features(in: output), [.lidClosed, .chargeByTime])
        XCTAssertEqual(SudoListing.features(in: "User ivan may run the following commands on mac:\n    (ALL) ALL\n"), [], "a password rule is not ours")
        XCTAssertEqual(SudoListing.features(in: "    (root) NOPASSWD: /usr/bin/pmset disablesleep 1\n"), [], "half a feature is not the feature")
        XCTAssertEqual(SudoListing.features(in: "    (ALL : ALL) NOPASSWD: ALL\n"), [.lidClosed, .chargeByTime])
        XCTAssertEqual(SudoListing.features(in: "    (root) NOPASSWD: /bin/ls, PASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0\n"), [])
        XCTAssertEqual(SudoListing.features(in: "    (nobody) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0\n"), [], "not as root")
        XCTAssertEqual(SudoListing.passwordlessCommands("    (root) SETENV: NOPASSWD: /usr/bin/pmset  disablesleep 1\n"), ["/usr/bin/pmset disablesleep 1"])
    }
}

final class PrivilegedPresenceTests: XCTestCase {
    func testOldFilesOrTheMergedFileCountAsPermissionPresent() {
        let none: (String) -> Bool = { _ in false }
        XCTAssertFalse(PrivilegedRulePresence.isPresent(.lidClosed, fileExists: none, merged: [.lidClosed]))
        XCTAssertTrue(PrivilegedRulePresence.isPresent(.lidClosed, fileExists: { $0 == "/etc/sudoers.d/tilvero-lid" }, merged: []))
        let merged: (String) -> Bool = { $0 == "/etc/sudoers.d/tilvero" }
        XCTAssertTrue(PrivilegedRulePresence.isPresent(.lidClosed, fileExists: merged, merged: [.lidClosed]))
        XCTAssertFalse(PrivilegedRulePresence.isPresent(.chargeByTime, fileExists: merged, merged: [.lidClosed]))
    }

    func testTheRecordRoundTripsAndTheSignatureFollowsTheFiles() {
        let suite = "Presence-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        PrivilegedRulePresence.record([.chargeByTime, .lidClosed], in: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: SudoersRules.mergedFeaturesKey), ["lidClosed", "chargeByTime"])
        PrivilegedRulePresence.record([], in: defaults)
        XCTAssertNil(defaults.object(forKey: SudoersRules.mergedFeaturesKey))
        let empty = PrivilegedRulePresence.signature(lstat: { _ in nil })
        XCTAssertEqual(empty, "-|-|-")
        XCTAssertNotEqual(PrivilegedRulePresence.signature(lstat: { $0 == SudoersRules.mergedPath ? (1, 2, 3, 4) : nil }), empty)
    }
}

// MARK: Installer with fakes

private final class FakeExecutor: AdministratorScriptExecuting, @unchecked Sendable {
    var outcome: AdministratorScriptOutcome
    var scripts: [String] = [], prompts: [String] = []
    var onRun: () -> Void = {}
    init(_ outcome: AdministratorScriptOutcome) { self.outcome = outcome }
    func run(script: String, prompt: String) async -> AdministratorScriptOutcome {
        scripts.append(script); prompts.append(prompt); onRun()
        return outcome
    }
}

private final class FakeProbe: PrivilegedRuleProbing, @unchecked Sendable {
    var present: Set<PrivilegedFeature>? = []
    var calls = 0
    func passwordless() async -> Set<PrivilegedFeature>? { calls += 1; return present }
}

@MainActor private final class FakeTerminal: TerminalScriptOpening {
    var texts: [String] = []
    var folder: URL?
    var fails = false
    func open(_ text: String) async -> URL? {
        texts.append(text)
        guard !fails else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FakeTerminal-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folder = url
        return url
    }
    func answer(_ code: Int32) { try? "\(code)\n".write(to: folder!.appendingPathComponent("result"), atomically: true, encoding: .utf8) }
}

/// Virtual time: every sleep advances the clock and yields, so a 10-minute wait runs in milliseconds.
private final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 0)
    var sleeps = 0
    var onSleep: @MainActor () -> Void = {}
    var clock: PermissionWaitClock {
        PermissionWaitClock(now: { [self] in lock.withLock { current } }, sleep: { [self] duration in
            try Task.checkCancellation()
            lock.withLock { current += Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18; sleeps += 1 }
            await MainActor.run { self.onSleep() }
            await Task.yield()
            try Task.checkCancellation()
        })
    }
}

@MainActor final class PrivilegedRuleInstallerTests: XCTestCase {
    private var suite = "", defaults: UserDefaults!
    private var files: Set<String> = []
    private var signature = "a"
    override func setUp() async throws { suite = "Installer-\(UUID())"; defaults = UserDefaults(suiteName: suite); files = []; signature = "a" }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    private func installer(_ executor: FakeExecutor = FakeExecutor(.succeeded), terminal: FakeTerminal = FakeTerminal(), probe: FakeProbe = FakeProbe(),
                           clock: VirtualClock = VirtualClock()) -> PrivilegedRuleInstaller {
        PrivilegedRuleInstaller(executor: executor, terminal: terminal, probe: probe, defaults: defaults, uid: 501,
                                fileExists: { [unowned self] in self.files.contains($0) }, signature: { [unowned self] in self.signature },
                                clock: clock.clock, terminalTimeout: 600,
                                commandBuilder: { op, root in TerminalCommandText.text(rootScript: root, messages: .init(header: "H", password: "P", done: "D", failed: "F")) + (op.isRemoval ? "#r" : "") })
    }

    func testOneDialogInstallsEveryChosenFeature() async {
        let executor = FakeExecutor(.succeeded)
        executor.onRun = { [unowned self] in self.files.insert(SudoersRules.mergedPath) }
        let outcome = await installer(executor).install([.lidClosed, .chargeByTime])
        XCTAssertEqual(outcome, .succeeded([.lidClosed, .chargeByTime]))
        XCTAssertEqual(executor.scripts, [SudoersRules.installScript(uid: 501, features: [.lidClosed, .chargeByTime])!], "one administrator dialog")
        XCTAssertEqual(PrivilegedRulePresence.recordedMergedFeatures(defaults), [.lidClosed, .chargeByTime])
    }

    func testNothingChosenRunsNothing() async {
        let executor = FakeExecutor(.succeeded)
        let result = await installer(executor).install([])
        XCTAssertEqual(result, .succeeded([]))
        XCTAssertTrue(executor.scripts.isEmpty)
    }

    func testCancelAndFailureRecordNothingAndKeepTheCode() async {
        for (result, expected) in [(AdministratorScriptOutcome.cancelled, PrivilegedOutcome.cancelled), (.failed(7), .failed(7)), (.failed(nil), .failed(nil))] {
            let outcome = await installer(FakeExecutor(result)).install([.lidClosed])
            XCTAssertEqual(outcome, expected)
            XCTAssertTrue(PrivilegedRulePresence.recordedMergedFeatures(defaults).isEmpty)
        }
    }

    func testASuccessWithoutTheFileIsAFailure() async {
        let result = await installer(FakeExecutor(.succeeded)).install([.lidClosed])
        XCTAssertEqual(result, .failed(nil))
    }

    func testADialogCancelledAfterTheMoveStillCountsWhenTheRulesSaySo() async {
        let executor = FakeExecutor(.cancelled), probe = FakeProbe()
        executor.onRun = { [unowned self] in self.files.insert(SudoersRules.mergedPath); self.signature = "b" }
        probe.present = [.chargeByTime]
        let result = await installer(executor, probe: probe).install([.chargeByTime])
        XCTAssertEqual(result, .succeeded([.chargeByTime]))
        // Without a file change sudo is not even asked.
        let quiet = FakeProbe(); quiet.present = [.chargeByTime]
        let none = await installer(FakeExecutor(.cancelled), probe: quiet).install([.chargeByTime])
        XCTAssertEqual(none, .cancelled); XCTAssertEqual(quiet.calls, 0)
    }

    func testTheTerminalRouteOpensTheShownTextAndReadsTheResult() async throws {
        let terminal = FakeTerminal(), clock = VirtualClock()
        let installer = installer(terminal: terminal, clock: clock)
        let shown = try XCTUnwrap(installer.commandText(.install([.lidClosed, .chargeByTime])))
        clock.onSleep = { if clock.sleeps == 3 { terminal.answer(0) } }
        files.insert(SudoersRules.mergedPath)
        let outcome = await installer.install([.lidClosed, .chargeByTime], route: .terminal)
        XCTAssertEqual(outcome, .succeeded([.lidClosed, .chargeByTime]))
        XCTAssertEqual(terminal.texts, [shown], "what the window shows is what Terminal runs")
        XCTAssertFalse(FileManager.default.fileExists(atPath: terminal.folder!.path), "the private folder is removed afterwards")
    }

    func testAWrongPasswordInTerminalIsReported() async {
        let terminal = FakeTerminal(), clock = VirtualClock()
        clock.onSleep = { terminal.answer(1) }
        let outcome = await installer(terminal: terminal, clock: clock).install([.lidClosed], route: .terminal)
        XCTAssertEqual(outcome, .failed(1))
    }

    func testARuleChangeIsConfirmedBySudoWithoutAResultFile() async {
        let terminal = FakeTerminal(), clock = VirtualClock(), probe = FakeProbe()
        clock.onSleep = { [unowned self] in if clock.sleeps == 5 { self.signature = "changed"; probe.present = [.lidClosed] } }
        let outcome = await installer(terminal: terminal, probe: probe, clock: clock).install([.lidClosed], route: .terminal)
        XCTAssertEqual(outcome, .succeeded([.lidClosed]))
        XCTAssertEqual(probe.calls, 1, "sudo is asked only when a rule file changed")
    }

    func testANudgeChecksAtOnceAndTheWaitIsBounded() async {
        let terminal = FakeTerminal(), clock = VirtualClock(), probe = FakeProbe()
        let installer = installer(terminal: terminal, probe: probe, clock: clock)
        clock.onSleep = { if clock.sleeps == 2 { installer.nudge() } }
        let outcome = await installer.install([.lidClosed], route: .terminal)
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(probe.calls, 0, "a nudge with no rule change does not need sudo")
        XCTAssertEqual(clock.sleeps, 1200, "600 s at 0.5 s")
    }

    func testCancellingTheTerminalWaitEndsItAndCleansUp() async throws {
        let terminal = FakeTerminal(), clock = VirtualClock()
        let installer = installer(terminal: terminal, clock: clock)
        let task = Task { await installer.install([.lidClosed], route: .terminal) }
        clock.onSleep = { if clock.sleeps == 4 { task.cancel() } }
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(terminal.folder).path))
    }

    func testAPasswordTypedAfterCancelIsNoticedAndReported() async throws {
        let terminal = FakeTerminal(), clock = VirtualClock(), probe = FakeProbe()
        files.insert(SudoersRules.mergedPath)
        let installer = installer(terminal: terminal, probe: probe, clock: clock)
        var late: [PrivilegedOperation] = []
        installer.observeLateSuccess { late.append($0) }
        let task = Task { await installer.install([.lidClosed], route: .terminal) }
        clock.onSleep = { if clock.sleeps == 3 { task.cancel() } }
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(installer.isWatchingLate, "Terminal may still be asking: the rule files stay watched")
        clock.onSleep = { [unowned self] in if clock.sleeps == 10 { self.signature = "installed"; probe.present = [.lidClosed] } }
        for _ in 0..<200 where late.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(late, [.install([.lidClosed])])
        XCTAssertEqual(PrivilegedRulePresence.recordedMergedFeatures(defaults), [.lidClosed])
        XCTAssertFalse(installer.isWatchingLate)
    }

    func testTheLateWatchIsBoundedAndANewRunReplacesIt() async throws {
        let terminal = FakeTerminal(), clock = VirtualClock(), probe = FakeProbe()
        let installer = installer(terminal: terminal, probe: probe, clock: clock)
        var late = 0
        installer.observeLateSuccess { _ in late += 1 }
        clock.onSleep = {}
        let outcome = await installer.install([.lidClosed], route: .terminal)   // runs into the 600 s timeout
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertTrue(installer.isWatchingLate)
        for _ in 0..<400 where installer.isWatchingLate { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(installer.isWatchingLate, "gives up after its bounded time")
        XCTAssertEqual(late, 0)
        XCTAssertEqual(probe.calls, 0, "no rule change: sudo is never asked")
    }

    func testANonZeroResultWithTheRuleInPlaceStillCounts() async {
        let terminal = FakeTerminal(), clock = VirtualClock(), probe = FakeProbe()
        clock.onSleep = { [unowned self] in self.signature = "moved"; probe.present = [.lidClosed]; terminal.answer(3) }
        let outcome = await installer(terminal: terminal, probe: probe, clock: clock).install([.lidClosed], route: .terminal)
        XCTAssertEqual(outcome, .succeeded([.lidClosed]))
    }

    func testTerminalThatCannotOpenFailsCalmly() async {
        let terminal = FakeTerminal(); terminal.fails = true
        let outcome = await installer(terminal: terminal).install([.lidClosed], route: .terminal)
        XCTAssertEqual(outcome, .failed(nil))
    }

    func testRemoveAllIsTheInverseAndClearsTheHint() async {
        PrivilegedRulePresence.record([.lidClosed, .chargeByTime], in: defaults)
        let executor = FakeExecutor(.succeeded)
        let outcome = await installer(executor).run(.remove([.lidClosed, .chargeByTime]), route: .systemPrompt)
        XCTAssertEqual(outcome, .succeeded([.lidClosed, .chargeByTime]))
        XCTAssertEqual(executor.scripts, [SudoersRules.removalScript(uid: 501, removing: [.lidClosed, .chargeByTime])!])
        XCTAssertEqual(executor.prompts, [PrivilegedRuleInstaller.prompt(for: .remove([.lidClosed]))])
        XCTAssertTrue(PrivilegedRulePresence.recordedMergedFeatures(defaults).isEmpty)
    }

    func testPresenceIsReadOnlyAndRefreshesTheHint() async {
        let probe = FakeProbe(); probe.present = [.chargeByTime]
        files.insert(SudoersRules.mergedPath)
        let executor = FakeExecutor(.succeeded)
        let present = await installer(executor, probe: probe).presence()
        XCTAssertEqual(present, [.chargeByTime])
        XCTAssertTrue(executor.scripts.isEmpty, "reading never runs a script")
        XCTAssertEqual(PrivilegedRulePresence.recordedMergedFeatures(defaults), [.chargeByTime])
    }

    func testTheSetupMessagesAreCalm() {
        XCTAssertEqual(PrivilegedPermissionsController.message(.succeeded([]), operation: .remove([.lidClosed]), route: .systemPrompt), "setup.permissions.removed")
        XCTAssertEqual(PrivilegedPermissionsController.message(.failed(1), operation: .install([.lidClosed]), route: .terminal), "firstRun.failed.terminal")
        XCTAssertEqual(PrivilegedPermissionsController.message(.cancelled, operation: .install([.lidClosed]), route: .terminal), "firstRun.declined.terminal")
        XCTAssertEqual(PrivilegedPermissionsController.message(.failed(1), operation: .install([.lidClosed]), route: .systemPrompt), "firstRun.failed")
        XCTAssertEqual(PrivilegedPermissionsController.message(.cancelled, operation: .install([.lidClosed]), route: .systemPrompt), "firstRun.declined")
    }
}

final class FirstRunMotionTests: XCTestCase {
    typealias M = FirstRunMotion

    func testReduceMotionIsStaticAndShort() {
        XCTAssertEqual(M.check(0, reduceMotion: true), 1)
        XCTAssertEqual(M.iconFill(0, reduceMotion: true), 1, "icon full at once")
        XCTAssertEqual(M.coach(1.3, reduceMotion: true).pulse, 0, "no pulse")
        XCTAssertLessThanOrEqual(M.handOffDuration(reduceMotion: true), 0.2)
        XCTAssertLessThanOrEqual(M.crossfadeDuration(reduceMotion: true), 0.2)
        XCTAssertLessThan(M.successBeat(reduceMotion: true), M.successBeat(reduceMotion: false))
    }

    func testEveryPieceEnds() {
        XCTAssertEqual(M.check(0.3, reduceMotion: false), 1)
        XCTAssertEqual(M.iconFillLevel(0, level: 80, reduceMotion: false), 0)
        XCTAssertEqual(M.iconFillLevel(M.iconFillDuration, level: 80, reduceMotion: false), 80)
        XCTAssertEqual(M.coach(M.coachDuration, reduceMotion: false), .init(opacity: 0, pulse: 0))
        XCTAssertEqual(M.coach(3, reduceMotion: false).pulse, 0, "two pulses, then rest")
        XCTAssertEqual(M.handOffDuration(reduceMotion: false), 0.35)
        // The whole landing is about one second.
        XCTAssertLessThanOrEqual(M.successBeat(reduceMotion: false) + M.handOffDuration(reduceMotion: false) + M.iconFillDuration, 1.5)
    }
}

final class FirstRunCopyTests: XCTestCase {
    static let labels = [
        "firstRun.title", "firstRun.launchAtLogin", "firstRun.keepHistory", "firstRun.chargeLimit", "firstRun.lidClosed", "firstRun.chargeByTime",
        "firstRun.badge.password", "firstRun.badge.allowed", "firstRun.start", "firstRun.allowAndStart", "firstRun.tryAgain", "firstRun.withoutPassword",
        "firstRun.skip", "firstRun.cancel", "firstRun.close", "firstRun.useTerminal", "firstRun.openApp", "firstRun.openSettings", "firstRun.copy",
        "firstRun.showCommand", "firstRun.hideCommand", "firstRun.done", "firstRun.preview", "firstRun.coach", "firstRun.info.title",
        "firstRun.enabling", "firstRun.waiting.system", "firstRun.waiting.terminal", "firstRun.declined", "firstRun.failed", "firstRun.failed.terminal",
        "firstRun.passwordNote", "firstRun.readyNote", "firstRun.iconHidden.title",
        "firstRun.attention.loginNeedsApproval", "firstRun.attention.loginFailed", "firstRun.attention.lidRefused",
        "setup.permissions.allow", "setup.permissions.allowed", "setup.permissions.notAllowed", "setup.permissions.granted", "setup.permissions.removed",
        "setup.permissions.removeAll", "setup.permissions.removeInTerminal", "setup.permissions.title", "setup.permissions.removalCommand"]
    static let lines = ["firstRun.subtitle", "firstRun.launchAtLogin.detail", "firstRun.keepHistory.detail", "firstRun.chargeLimit.detail",
                        "firstRun.lidClosed.detail", "firstRun.chargeByTime.detail", "firstRun.iconHidden.text",
                        "firstRun.timedOut", "firstRun.declined.terminal",
                        "setup.permissions.blocked.lid", "setup.permissions.blocked.wake"]
    static let script = ["firstRun.script.header", "firstRun.script.removeHeader", "firstRun.script.password", "firstRun.script.done", "firstRun.script.failed"]
    static let prompts = ["Tilvero asks to allow narrow pmset commands without a password for the features you chose.",
                          "Tilvero asks to remove its passwordless pmset rules.", "Tilvero asks to restore normal sleep."]

    private func catalog() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TilveroApp/Resources/Localizable.xcstrings")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: Any])
    }
    private func value(_ strings: [String: Any], _ key: String, _ language: String) -> String? {
        (((strings[key] as? [String: Any])?["localizations"] as? [String: Any])?[language] as? [String: Any]).flatMap { ($0["stringUnit"] as? [String: Any])?["value"] as? String }
    }

    func testEveryStringExistsInRussianAndEnglish() throws {
        let strings = try catalog()
        let keys = Self.labels + Self.lines + Self.script + Self.prompts + FirstRunWindowView.infoKeys
            + FirstRunWindowView.rows.flatMap { [$0.title, $0.detail] }
        for key in keys { for language in ["en", "ru"] { XCTAssertFalse(value(strings, key, language)?.isEmpty ?? true, "\(language): \(key)") } }
    }

    /// Plain words, short: labels fit a button or a row, one-line descriptions, the (i) text within ~50 words.
    func testCopyIsShortPlainAndWithoutCaveats() throws {
        let strings = try catalog()
        for language in ["en", "ru"] {
            let info = FirstRunWindowView.infoKeys.compactMap { value(strings, $0, language) }
            XCTAssertEqual(info.count, 2, "two short paragraphs")
            XCTAssertLessThanOrEqual(info.joined(separator: " ").split(separator: " ").count, 50, "\(language) info within ~50 words")
            for key in Self.labels { XCTAssertLessThanOrEqual((value(strings, key, language) ?? "").count, 34, "\(language) \(key)") }
            for key in Self.lines { XCTAssertLessThanOrEqual((value(strings, key, language) ?? "").count, 56, "\(language) \(key)") }
            // Technical words only behind (i), in Terminal and in the macOS prompt.
            for key in Self.labels + Self.lines {
                let text = value(strings, key, language) ?? ""
                for word in ["pmset", "sudo", "sudoers", "verified", "провер", "root"] { XCTAssertFalse(text.localizedCaseInsensitiveContains(word), "\(language) \(key): \(text)") }
            }
            for key in Self.script { XCTAssertTrue(TerminalCommandText.Messages.isSafe(value(strings, key, language) ?? "'"), "\(language) \(key)") }
        }
    }

    func testButtonKeysCoverEveryButton() {
        for primary in [FirstRunButtons.Primary.start, .allowAndStart, .tryAgain, .openApp] { XCTAssertTrue(Self.labels.contains(FirstRunWindowView.primaryKey(primary))) }
        for secondary in [FirstRunButtons.Secondary.skip, .cancel, .withoutPassword, .close] { XCTAssertTrue(Self.labels.contains(FirstRunWindowView.secondaryKey(secondary))) }
    }
}

@MainActor private final class FakeHost: FirstRunHost {
    var visible = true
    var popovers = 0, details = 0, finished = 0
    var fills: [Double?] = []
    var firstRunStatusButtonFrame: NSRect? { visible ? NSRect(x: 1200, y: 900, width: 40, height: 24) : nil }
    var firstRunStatusItemVisible: Bool { visible }
    func firstRunDrawIcon(fill: Double?) { fills.append(fill) }
    func firstRunOpenPopover() { popovers += 1 }
    func firstRunOpenDetails() { details += 1 }
    var fillsAtFinish: [Double?] = []
    func firstRunFinished() { finished += 1; fillsAtFinish = fills }
}

@MainActor final class FirstRunCoordinatorTests: XCTestCase {
    private var logins: [Bool] = [], history: [Bool] = [], requests: [(Set<PrivilegedFeature>, PermissionRoute)] = [], lid = 0, marks = 0
    private var loginResult: FirstRunLoginResult = .enabled
    private var permission: PrivilegedOutcome = .succeeded([.lidClosed, .chargeByTime])
    private var lidResult = true

    private func make() -> (FirstRunCoordinator, FakeHost) {
        let host = FakeHost()
        let ports = FirstRunPorts(
            markIntroduced: { self.marks += 1 }, setHistory: { self.history.append($0) },
            setLogin: { self.logins.append($0); return $0 ? self.loginResult : nil }, openLoginItemsSettings: {},
            requestPermission: { features, route in self.requests.append((features, route)); return self.permission },
            commandText: { "text for \($0.count)" }, nudge: {}, turnOnLid: { self.lid += 1; return self.lidResult })
        let session = FirstRunSession(isPreview: true)
        session.speed = 20
        session.forceReduceMotion = true
        let coordinator = FirstRunCoordinator(session: session, ports: ports, host: host)
        coordinator.presentsWindow = false   // never a real window or activation in tests
        return (coordinator, host)
    }

    private func wait(until condition: @escaping () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    func testOneClickAppliesTheChoicesAndOpensTheRealMenu() async throws {
        let (coordinator, host) = make()
        coordinator.start()
        XCTAssertEqual(marks, 1, "recorded at once: never shown twice")
        coordinator.session.send(.start)
        XCTAssertEqual(history, [true]); XCTAssertEqual(logins, [true])
        try await wait { host.popovers == 1 }
        XCTAssertTrue(requests.isEmpty, "no password without locked features")
        XCTAssertEqual(coordinator.session.step, .finished)
        XCTAssertTrue(coordinator.session.coachVisible, "the charge limit coach runs on the real menu")
        try await wait { host.finished == 1 }
        XCTAssertFalse(coordinator.session.coachVisible)
    }

    func testLockedFeaturesAskOnceThenTurnTheLidOn() async throws {
        let (coordinator, host) = make()
        coordinator.start()
        coordinator.session.flow.choices.lidClosed = true
        coordinator.session.flow.choices.chargeByTime = true
        coordinator.session.flow.choices.chargeLimit = false
        coordinator.session.send(.start)
        try await wait { host.finished == 1 }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.0, [.lidClosed, .chargeByTime]); XCTAssertEqual(requests.first?.1, .systemPrompt)
        XCTAssertEqual(lid, 1)
        XCTAssertEqual(host.popovers, 1)
    }

    func testTheTerminalRouteShowsItsText() async throws {
        let (coordinator, _) = make()
        permission = .cancelled
        coordinator.session.flow.choices.chargeByTime = true
        coordinator.session.send(.useTerminal)
        try await wait { coordinator.session.step == .declined }
        XCTAssertEqual(requests.first?.1, .terminal)
        XCTAssertEqual(coordinator.session.commandText, "text for 1")
    }

    func testARefusedLidOrALoginApprovalStopsForOneLook() async throws {
        lidResult = false; loginResult = .requiresApproval
        let (coordinator, host) = make()
        coordinator.session.flow.choices.lidClosed = true
        coordinator.session.send(.start)
        try await wait { coordinator.session.step == .attention }
        XCTAssertEqual(coordinator.session.flow.attention, [.loginNeedsApproval, .lidRefused])
        XCTAssertEqual(host.popovers, 0)
        coordinator.session.send(.start)
        try await wait { host.popovers == 1 }
    }

    func testNoRoomForTheIconKeepsTheWindow() async throws {
        let (coordinator, host) = make()
        host.visible = false
        coordinator.session.send(.skip)
        try await wait { coordinator.session.step == .iconHidden }
        XCTAssertEqual(host.popovers, 0)
        coordinator.session.send(.openDetails)
        XCTAssertEqual(host.details, 1)
        try await wait { host.finished == 1 }
    }

    func testLoginOffNeverRegisters() async throws {
        let (coordinator, host) = make()
        coordinator.session.flow.choices.launchAtLogin = false
        coordinator.session.flow.choices.keepHistory = false
        coordinator.session.send(.start)
        try await wait { host.popovers == 1 }
        XCTAssertEqual(logins, [false]); XCTAssertEqual(history, [false])
    }

    /// Without Reduce Motion the window lands while the icon is still filling: the icon must end at the real level.
    func testTheIconNeverStaysAtAFractionOfTheRealLevel() async throws {
        let (coordinator, host) = make()
        coordinator.session.forceReduceMotion = false
        coordinator.session.speed = 4
        coordinator.session.send(.skip)   // no coach: the flow finishes right after the landing
        try await wait { host.finished == 1 }
        XCTAssertTrue(host.fills.contains { $0 != nil }, "the fill really ran")
        XCTAssertEqual(host.fills.last, .some(nil), "back to the real level before the host frees the coordinator")
        XCTAssertEqual(host.fillsAtFinish.last, .some(nil))
    }

    func testClosingTheMenuEndsTheCoach() async throws {
        let (coordinator, host) = make()
        coordinator.session.send(.start)
        try await wait { host.popovers == 1 }
        coordinator.popoverDidClose()
        try await wait { host.finished == 1 }
        XCTAssertFalse(coordinator.session.coachVisible)
        coordinator.teardown()
    }
}
/// A fake process for `CancellableProcessRun`: never launches anything real.
private final class FakeProcess: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var launches = 0, terminations = 0
    private var finished: (@Sendable (Int32, String) -> Void)?
    var launch: CancellableProcessRun.Launch {
        { [self] done in
            lock.withLock { launches += 1; finished = done }
            return { [self] in
                let done = lock.withLock { () -> (@Sendable (Int32, String) -> Void)? in terminations += 1; return finished }
                done?(15, "")   // a terminated process exits with SIGTERM
            }
        }
    }
    func exit(_ status: Int32, _ output: String) { lock.withLock { finished }?(status, output) }
}

final class CancellableProcessRunTests: XCTestCase {
    func testCancellingMidRunTerminatesAndFinishesAsCancelled() async throws {
        let fake = FakeProcess()
        let task = Task { await CancellableProcessRun.run(launch: fake.launch) }
        for _ in 0..<100 where fake.launches == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(fake.launches, 1)
        task.cancel()
        let result = await task.value   // must not hang
        XCTAssertEqual(fake.terminations, 1)
        XCTAssertEqual(result.status, 15)
        XCTAssertEqual(OsascriptAdministratorExecutor.outcome(status: result.status, output: result.output, cancelled: true), .cancelled)
        fake.exit(0, "late")   // a second exit never resumes twice
    }

    func testCancellingBeforeTheStartNeverLaunches() async {
        let fake = FakeProcess()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await CancellableProcessRun.run(launch: fake.launch)
        }
        let result = await task.value
        XCTAssertEqual(fake.launches, 0)
        XCTAssertEqual(result.status, CancellableProcessRun.cancelledBeforeStart)
        XCTAssertEqual(OsascriptAdministratorExecutor.outcome(status: result.status, output: "", cancelled: false), .cancelled)
    }

    func testANormalExitResumesOnceWithItsResult() async throws {
        let fake = FakeProcess()
        let task = Task { await CancellableProcessRun.run(launch: fake.launch) }
        for _ in 0..<100 where fake.launches == 0 { try await Task.sleep(for: .milliseconds(5)) }
        fake.exit(1, "execution error: User canceled. (-128)")
        let result = await task.value
        XCTAssertEqual(OsascriptAdministratorExecutor.outcome(status: result.status, output: result.output, cancelled: false), .cancelled)
        XCTAssertEqual(OsascriptAdministratorExecutor.outcome(status: 1, output: "other", cancelled: false), .failed(nil))
        XCTAssertEqual(OsascriptAdministratorExecutor.outcome(status: 0, output: "", cancelled: false), .succeeded)
    }

    func testALaunchFailureFinishes() async {
        let result = await CancellableProcessRun.run(launch: { _ in throw CocoaError(.fileNoSuchFile) })
        XCTAssertEqual(result.status, CancellableProcessRun.launchFailed)
    }
}
