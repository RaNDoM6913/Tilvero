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
    private func flow(at step: FirstRunStep, locked: Bool = true) -> FirstRunFlow {
        var flow = FirstRunFlow()
        func go(_ e: [FirstRunEvent]) { e.forEach { flow.handle($0) } }
        switch step {
        case .iconFill: break
        case .whereIcon: go([.iconFilled])
        case .hiddenIcon: go([.iconFilled, .showHidden])
        case .card: go([.iconFilled, .statusItemClicked])
        case .confirmPreview, .systemPrompt, .declined:
            go([.iconFilled, .statusItemClicked]); flow.choices.lidClosed = locked; flow.choices.chargeByTime = locked
            go([.done]); if step != .confirmPreview { go([.previewFinished]) }
            if step == .declined { go([.promptFinished(.cancelled)]) }
        case .done: go([.iconFilled, .statusItemClicked, .done])
        case .bubble: go([.iconFilled, .skip])
        case .finished: go([.iconFilled, .skip, .bubbleFinished])
        }
        XCTAssertEqual(flow.step, step)
        return flow
    }

    private let allEvents: [FirstRunEvent] = [.iconFilled, .skip, .showHidden, .backFromHidden, .statusItemClicked, .openHere, .done,
        .previewFinished, .cancelConfirmation, .promptFinished(.success([.lidClosed, .chargeByTime])), .promptFinished(.cancelled),
        .promptFinished(.failed), .loginFinished(.enabled), .loginFinished(.requiresApproval), .loginFinished(.failed),
        .enable(.lidClosed), .enable(.chargeByTime), .dismissCard, .popoverClosed, .bubbleFinished]

    /// The whole table: every event from every state lands in a defined step; the listed transitions are exact.
    func testEveryEventFromEveryState() {
        let table: [(FirstRunStep, FirstRunEvent, FirstRunStep)] = [
            (.iconFill, .iconFilled, .whereIcon), (.iconFill, .skip, .finished),
            (.whereIcon, .skip, .bubble), (.whereIcon, .showHidden, .hiddenIcon), (.whereIcon, .statusItemClicked, .card), (.whereIcon, .openHere, .card),
            (.hiddenIcon, .skip, .bubble), (.hiddenIcon, .backFromHidden, .whereIcon), (.hiddenIcon, .statusItemClicked, .card), (.hiddenIcon, .openHere, .card),
            (.card, .done, .done), (.card, .popoverClosed, .bubble),
            (.confirmPreview, .previewFinished, .systemPrompt), (.confirmPreview, .cancelConfirmation, .declined),
            (.confirmPreview, .popoverClosed, .bubble), (.systemPrompt, .popoverClosed, .bubble),
            (.systemPrompt, .cancelConfirmation, .declined), (.systemPrompt, .promptFinished(.success([.lidClosed, .chargeByTime])), .done),
            (.systemPrompt, .promptFinished(.cancelled), .declined), (.systemPrompt, .promptFinished(.failed), .declined),
            (.done, .popoverClosed, .bubble),
            (.declined, .enable(.lidClosed), .confirmPreview), (.declined, .enable(.chargeByTime), .confirmPreview), (.declined, .popoverClosed, .bubble),
            (.bubble, .bubbleFinished, .finished),
        ]
        var expected: [FirstRunStep: [FirstRunEvent: FirstRunStep]] = [:]
        for (from, event, to) in table { expected[from, default: [:]][event] = to }
        for step in FirstRunStep.allCases {
            for event in allEvents {
                var f = flow(at: step)
                f.handle(event)
                XCTAssertEqual(f.step, expected[step]?[event] ?? step, "\(step) + \(event)")
            }
        }
    }

    func testDoneWithoutLockedFeaturesFinishesWithoutAPrompt() {
        var f = flow(at: .card)
        XCTAssertFalse(f.choices.doneNeedsPermission)
        let effects = f.handle(.done)
        XCTAssertEqual(f.step, .done)
        XCTAssertEqual(effects, [.applyEverydayChoices(launchAtLogin: true, keepHistory: true)])
        XCTAssertFalse(effects.contains { if case .requestPermission = $0 { true } else { false } })
    }

    func testLockedFeaturesShareOnePromptAfterThePreview() {
        var f = flow(at: .card)
        f.choices.moreExpanded = true; f.choices.lidClosed = true; f.choices.chargeByTime = true; f.choices.launchAtLogin = false
        XCTAssertTrue(f.choices.doneNeedsPermission)
        XCTAssertEqual(f.handle(.done), [.applyEverydayChoices(launchAtLogin: false, keepHistory: true), .playConfirmPreview])
        XCTAssertEqual(f.handle(.previewFinished), [.requestPermission([.lidClosed, .chargeByTime])])
        XCTAssertEqual(f.handle(.promptFinished(.success([.lidClosed, .chargeByTime]))), [.turnOnGranted([.lidClosed, .chargeByTime]), .ensurePopoverShown])
        XCTAssertEqual(f.step, .done)
        XCTAssertTrue(f.missingLocked.isEmpty)
    }

    func testCancelDeniedAndErrorAreCalmAndKeepLockedFeaturesOff() {
        for result in [FirstRunPromptResult.cancelled, .failed] {
            var f = flow(at: .systemPrompt)
            f.handle(.promptFinished(result))
            XCTAssertEqual(f.step, .declined)
            XCTAssertTrue(f.granted.isEmpty)
            XCTAssertEqual(f.missingLocked, [.lidClosed, .chargeByTime])
            XCTAssertEqual(f.promptFailed, result == .failed)
            // "Turn On" asks again for that one feature only.
            XCTAssertEqual(f.handle(.enable(.chargeByTime)), [.playConfirmPreview])
            XCTAssertEqual(f.handle(.previewFinished), [.requestPermission([.chargeByTime])])
        }
        var cancel = flow(at: .systemPrompt)
        XCTAssertEqual(cancel.handle(.cancelConfirmation), [.cancelPermissionRequest])
        // A late result after the user's own cancel is ignored.
        cancel.handle(.promptFinished(.success([.lidClosed])))
        XCTAssertEqual(cancel.step, .declined)
        XCTAssertTrue(cancel.granted.isEmpty)
    }

    func testPartialGrantLeavesTheRestBehindTurnOnPills() {
        var f = flow(at: .systemPrompt)
        f.handle(.promptFinished(.success([.lidClosed])))
        XCTAssertEqual(f.step, .declined)
        XCTAssertEqual(f.missingLocked, [.chargeByTime])
        XCTAssertEqual(f.handle(.enable(.lidClosed)), [], "an already granted feature has no pill")
    }

    func testRequiresApprovalIsRecordedForTheAllowPill() {
        var f = flow(at: .done)
        f.handle(.loginFinished(.requiresApproval))
        XCTAssertEqual(f.loginResult, .requiresApproval)
        XCTAssertEqual(f.step, .done)
    }

    func testSkipAndAnyWindowExitEndWithTheBubble() {
        var f = flow(at: .whereIcon)
        XCTAssertEqual(f.handle(.skip), [.hideBeacon, .closeWindow(intoIcon: false), .showBubble])
        XCTAssertEqual(f.handle(.bubbleFinished), [.finish])
        var first = FirstRunFlow()
        XCTAssertEqual(first.handle(.iconFilled), [.markIntroduced, .showWindow, .showBeacon], "the key is set when the window appears")
    }

    func testOpenHereHostsTheCardInTheWindow() {
        var f = flow(at: .hiddenIcon)
        XCTAssertEqual(f.handle(.openHere), [.hideBeacon, .hostCardInWindow])
        XCTAssertTrue(f.hostedInWindow)
        XCTAssertTrue(f.windowVisible)
        XCTAssertEqual(f.popoverBehavior, .transient)
        XCTAssertEqual(f.handle(.popoverClosed), [], "the popover is not part of this path")
        f.handle(.done)
        XCTAssertEqual(f.handle(.dismissCard), [.closeWindow(intoIcon: true), .showBubble])
    }

    func testThePopoverIsApplicationDefinedOnlyWhileTheCardIsUp() {
        for step in FirstRunStep.allCases {
            let f = flow(at: step)
            XCTAssertEqual(f.popoverBehavior, [.card, .confirmPreview, .systemPrompt, .done, .declined].contains(step) ? .applicationDefined : .transient, "\(step)")
        }
        var f = flow(at: .whereIcon)
        XCTAssertTrue(f.handle(.statusItemClicked).contains(.setPopoverBehavior(.applicationDefined)))
        f.handle(.done)
        XCTAssertEqual(f.handle(.popoverClosed), [.setPopoverBehavior(.transient), .showBubble], "restored to transient afterwards")
        XCTAssertEqual(FirstRunPopoverPolicy.ignoredWhileHeld, ["outside click", "application deactivated"])
    }

    func testClosingThePopoverDuringTheConfirmationIsACancel() {
        var preview = flow(at: .confirmPreview)
        XCTAssertEqual(preview.handle(.popoverClosed), [.setPopoverBehavior(.transient), .showBubble])
        XCTAssertEqual(preview.handle(.previewFinished), [], "no prompt appears after the popover was closed")
        var prompt = flow(at: .systemPrompt)
        XCTAssertEqual(prompt.handle(.popoverClosed), [.cancelPermissionRequest, .setPopoverBehavior(.transient), .showBubble])
        XCTAssertEqual(prompt.handle(.promptFinished(.success([.lidClosed]))), [], "no reopening, nothing granted")
        XCTAssertTrue(prompt.granted.isEmpty)
    }

    func testSummaryRowsFollowTheRealLoginAndLidResults() {
        var f = flow(at: .systemPrompt)
        XCTAssertEqual(f.everydayRows.map(\.kind), [.enabled, .enabled])
        f.handle(.loginFinished(.failed))
        f.handle(.promptFinished(.cancelled))
        XCTAssertEqual(f.step, .declined)
        XCTAssertEqual(f.everydayRows, [.init(id: "login", key: "firstRun.row.login", kind: .notEnabled),
                                        .init(id: "history", key: "firstRun.row.history", kind: .enabled)], "declined no longer claims login")
        f.handle(.loginFinished(.requiresApproval))
        XCTAssertEqual(f.everydayRows.first?.kind, .needsApproval)
        var granted = flow(at: .systemPrompt)
        granted.handle(.promptFinished(.success([.lidClosed, .chargeByTime])))
        XCTAssertEqual(granted.grantedRows.map(\.kind), [.notEnabled, .enabled], "lid unchecked until really on")
        granted.handle(.lidTurnedOn(false))
        XCTAssertEqual(granted.grantedRows.first?.kind, .notEnabled, "a refused lid option is shown as not enabled")
        granted.handle(.lidTurnedOn(true))
        XCTAssertEqual(granted.grantedRows.first?.kind, .enabled)
    }

    func testLoginRegistrationResultMapping() {
        XCTAssertEqual(FirstRunLogin.result(statusAfter: .enabled, threw: false), .enabled)
        XCTAssertEqual(FirstRunLogin.result(statusAfter: .requiresApproval, threw: true), .requiresApproval)
        XCTAssertEqual(FirstRunLogin.result(statusAfter: .notRegistered, threw: true), .failed)
        XCTAssertEqual(FirstRunLogin.result(statusAfter: .notFound, threw: false), .failed)
        XCTAssertEqual(FirstRunLogin.outcome(.granted([.lidClosed])), .success([.lidClosed]))
        XCTAssertEqual(FirstRunLogin.outcome(.cancelled), .cancelled)
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
}

@MainActor final class SudoersRulesTests: XCTestCase {
    private let lid = "#501 ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0"
    private let wake = "#501 ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake *, /usr/bin/pmset schedule cancel wake *"

    func testOneUidBoundLinePerChosenFeature() {
        XCTAssertEqual(SudoersRules.rules(uid: 501, features: []), [])
        XCTAssertEqual(SudoersRules.rules(uid: 501, features: [.chargeByTime, .lidClosed]), [lid, wake])
        XCTAssertEqual(SudoersRules.rule(uid: 502, feature: .chargeByTime), wake.replacingOccurrences(of: "#501", with: "#502"))
    }

    func testTheCommandsAreExactlyThoseOfTheExistingServices() {
        XCTAssertEqual(SudoersRules.rule(uid: 501, feature: .lidClosed), NativeLidSleepSystem.rule(uid: 501))
        XCTAssertEqual(SudoersRules.rule(uid: 501, feature: .chargeByTime), NativeWakeScheduler.rule(uid: 501))
        XCTAssertEqual(PrivilegedFeature.lidClosed.legacyPath, NativeLidSleepSystem.rulePath)
        XCTAssertEqual(PrivilegedFeature.chargeByTime.legacyPath, NativeWakeScheduler.rulePath)
    }

    func testInstallScriptGolden() throws {
        let script = try XCTUnwrap(SudoersRules.installScript(uid: 501, features: [.lidClosed, .chargeByTime]))
        XCTAssertEqual(script, "mkdir -p /etc/sudoers.d && T=$(mktemp /etc/sudoers.d/tilvero.XXXXXX) && { [ ! -f /etc/sudoers.d/tilvero ] || grep -v -x -F -e '\(lid)' -e '\(wake)' /etc/sudoers.d/tilvero || true; } > \"$T\" && printf '%s\\n' '\(lid)' '\(wake)' >> \"$T\" && chmod 0440 \"$T\" && /usr/sbin/visudo -c -f \"$T\" && mv -f \"$T\" /etc/sudoers.d/tilvero && rm -f /etc/sudoers.d/tilvero-lid && rm -f /etc/sudoers.d/tilvero-wake || { rm -f \"$T\"; exit 1; }")
        XCTAssertNil(SudoersRules.installScript(uid: 501, features: []))
    }

    func testValidateThenMoveThenRemoveOldOnlyForChosenFeatures() throws {
        let script = try XCTUnwrap(SudoersRules.installScript(uid: 501, features: [.lidClosed]))
        let validate = try XCTUnwrap(script.range(of: "visudo -c -f \"$T\"")).lowerBound
        let move = try XCTUnwrap(script.range(of: "mv -f \"$T\" /etc/sudoers.d/tilvero")).lowerBound
        let removeOld = try XCTUnwrap(script.range(of: "rm -f /etc/sudoers.d/tilvero-lid")).lowerBound
        XCTAssertLessThan(validate, move); XCTAssertLessThan(move, removeOld)
        XCTAssertFalse(script.contains("tilvero-wake"), "the other feature's file stays")
        XCTAssertFalse(script.contains("schedule"), "only the chosen feature's commands")
        XCTAssertTrue(script.hasSuffix("|| { rm -f \"$T\"; exit 1; }"))
        XCTAssertTrue(script.contains("mktemp /etc/sudoers.d/tilvero.XXXXXX"), "a unique, dotted (ignored by sudo) temporary name per run")
    }

    func testRemovalAlwaysTakesTheLineOutWhateverTheRecordSays() {
        let script = SudoersRules.removalScript(uid: 501, removing: .lidClosed)
        XCTAssertEqual(script, "rm -f /etc/sudoers.d/tilvero-lid && T=$(mktemp /etc/sudoers.d/tilvero.XXXXXX) && { [ ! -f /etc/sudoers.d/tilvero ] || grep -v -x -F -e '\(lid)' /etc/sudoers.d/tilvero || true; } > \"$T\" && if [ -s \"$T\" ]; then chmod 0440 \"$T\" && /usr/sbin/visudo -c -f \"$T\" && mv -f \"$T\" /etc/sudoers.d/tilvero; else rm -f \"$T\" /etc/sudoers.d/tilvero; fi || { rm -f \"$T\"; exit 1; }")
        XCTAssertFalse(script.contains("schedule"), "no knowledge of the other line is needed to keep it")
    }

    func testAppleScriptQuoting() {
        XCTAssertEqual(SudoersRules.appleScriptSource(script: "echo 'a\"b'", prompt: "P"),
                       "do shell script \"echo 'a\\\"b'\" with administrator privileges with prompt \"P\"")
    }
}

/// Runs the real scripts with `/bin/sh` against a temporary folder (paths rewritten, `visudo` replaced by `true` or
/// `false`). Nothing privileged runs; this proves the file-level behaviour the golden strings describe.
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
            .replacingOccurrences(of: "/usr/sbin/visudo -c -f", with: validates ? "true" : "false")
    }
    @discardableResult private func run(_ script: String, validates: Bool = true) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", sandboxed(script, validates: validates)]
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

    func testInstallWritesOnlyTheChosenLinesAndRemovesTheirOldFiles() throws {
        try write("tilvero-lid", [lid]); try write("tilvero-wake", [wake])
        XCTAssertEqual(try run(SudoersRules.installScript(uid: 501, features: [.lidClosed])!), 0)
        XCTAssertEqual(lines("tilvero"), [lid])
        XCTAssertNil(lines("tilvero-lid"))
        XCTAssertEqual(lines("tilvero-wake"), [wake], "the other feature's old file stays")
        XCTAssertEqual(temporaries(), [])
    }

    func testInstallKeepsLinesTheAppCannotAccountFor() throws {
        // Merged file written by another copy (or a lost record): its lines survive a request for one feature.
        try write("tilvero", [wake, foreign])
        XCTAssertEqual(try run(SudoersRules.installScript(uid: 501, features: [.lidClosed])!), 0)
        XCTAssertEqual(lines("tilvero"), [wake, foreign, lid])
        XCTAssertEqual(try run(SudoersRules.installScript(uid: 501, features: [.lidClosed])!), 0)
        XCTAssertEqual(lines("tilvero"), [wake, foreign, lid], "idempotent: no duplicate line")
    }

    func testAFailedValidationChangesNothing() throws {
        try write("tilvero", [wake]); try write("tilvero-lid", [lid])
        XCTAssertNotEqual(try run(SudoersRules.installScript(uid: 501, features: [.lidClosed])!, validates: false), 0)
        XCTAssertEqual(lines("tilvero"), [wake])
        XCTAssertEqual(lines("tilvero-lid"), [lid], "old file removed only after a validated move")
        XCTAssertEqual(temporaries(), [], "the temporary file is cleaned up")
    }

    func testRemovalWithTheFilePresentAndAnEmptyRecordTakesOnlyThatLineOut() throws {
        try write("tilvero", [lid, wake, foreign]); try write("tilvero-lid", [lid])
        XCTAssertEqual(try run(SudoersRules.removalScript(uid: 501, removing: .lidClosed)), 0)
        XCTAssertEqual(lines("tilvero"), [wake, foreign])
        XCTAssertNil(lines("tilvero-lid"))
        XCTAssertEqual(temporaries(), [])
    }

    func testRemovalOfTheLastLineDeletesTheFile() throws {
        try write("tilvero", [lid])
        XCTAssertEqual(try run(SudoersRules.removalScript(uid: 501, removing: .lidClosed)), 0)
        XCTAssertNil(lines("tilvero"))
        XCTAssertEqual(temporaries(), [])
    }

    func testRemovalWithoutAMergedFileOnlyRemovesTheOldFile() throws {
        try write("tilvero-lid", [lid]); try write("tilvero-wake", [wake])
        XCTAssertEqual(try run(SudoersRules.removalScript(uid: 501, removing: .lidClosed)), 0)
        XCTAssertNil(lines("tilvero-lid")); XCTAssertNil(lines("tilvero"))
        XCTAssertEqual(lines("tilvero-wake"), [wake])
    }
}


final class PrivilegedPresenceTests: XCTestCase {
    func testOldFilesOrTheMergedFileCountAsPermissionPresent() {
        let none: (String) -> Bool = { _ in false }
        XCTAssertFalse(PrivilegedRulePresence.isPresent(.lidClosed, fileExists: none, merged: [.lidClosed]))
        XCTAssertTrue(PrivilegedRulePresence.isPresent(.lidClosed, fileExists: { $0 == "/etc/sudoers.d/tilvero-lid" }, merged: []))
        XCTAssertTrue(PrivilegedRulePresence.isPresent(.chargeByTime, fileExists: { $0 == "/etc/sudoers.d/tilvero-wake" }, merged: []))
        let merged: (String) -> Bool = { $0 == "/etc/sudoers.d/tilvero" }
        XCTAssertTrue(PrivilegedRulePresence.isPresent(.lidClosed, fileExists: merged, merged: [.lidClosed]))
        XCTAssertFalse(PrivilegedRulePresence.isPresent(.chargeByTime, fileExists: merged, merged: [.lidClosed]), "a merged file without the wake line")
    }

    func testTheRecordRoundTrips() {
        let suite = "Presence-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        PrivilegedRulePresence.record([.chargeByTime, .lidClosed], in: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: SudoersRules.mergedFeaturesKey), ["lidClosed", "chargeByTime"])
        XCTAssertEqual(PrivilegedRulePresence.recordedMergedFeatures(defaults), [.lidClosed, .chargeByTime])
        PrivilegedRulePresence.record([], in: defaults)
        XCTAssertNil(defaults.object(forKey: SudoersRules.mergedFeaturesKey))
    }
}

private final class FakeExecutor: AdministratorScriptExecuting, @unchecked Sendable {
    var outcome: AdministratorScriptOutcome
    var installsFile: Bool
    var scripts: [String] = []
    var files: Set<String>
    init(_ outcome: AdministratorScriptOutcome, installsFile: Bool = true, files: Set<String> = []) {
        self.outcome = outcome; self.installsFile = installsFile; self.files = files
    }
    func run(script: String, prompt: String) async -> AdministratorScriptOutcome {
        scripts.append(script)
        if installsFile { files.insert(SudoersRules.mergedPath) }
        return outcome
    }
}

@MainActor final class PrivilegedRuleInstallerTests: XCTestCase {
    private var suite = "", defaults: UserDefaults!
    override func setUp() async throws { suite = "Installer-\(UUID())"; defaults = UserDefaults(suiteName: suite) }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    private func installer(_ executor: FakeExecutor) -> PrivilegedRuleInstaller {
        PrivilegedRuleInstaller(executor: executor, defaults: defaults, uid: 501, fileExists: { executor.files.contains($0) })
    }

    func testOnePromptInstallsEveryChosenFeature() async {
        let executor = FakeExecutor(.succeeded)
        let outcome = await installer(executor).install([.lidClosed, .chargeByTime])
        XCTAssertEqual(outcome, .granted([.lidClosed, .chargeByTime]))
        XCTAssertEqual(executor.scripts.count, 1, "one administrator prompt")
        XCTAssertEqual(executor.scripts.first, SudoersRules.installScript(uid: 501, features: [.lidClosed, .chargeByTime]))
        XCTAssertEqual(PrivilegedRulePresence.recordedMergedFeatures(defaults), [.lidClosed, .chargeByTime])
    }

    func testNothingChosenRunsNothing() async {
        let executor = FakeExecutor(.succeeded)
        let result = await installer(executor).install([])
        XCTAssertEqual(result, .granted([]))
        XCTAssertTrue(executor.scripts.isEmpty)
    }

    func testCancelAndFailureRecordNothing() async {
        for result in [AdministratorScriptOutcome.cancelled, .failed] {
            let executor = FakeExecutor(result, installsFile: false)
            let outcome = await installer(executor).install([.lidClosed])
            XCTAssertEqual(outcome, result == .cancelled ? .cancelled : .failed)
            XCTAssertTrue(PrivilegedRulePresence.recordedMergedFeatures(defaults).isEmpty)
        }
    }

    func testASuccessWithoutTheFileIsAFailure() async {
        let result = await installer(FakeExecutor(.succeeded, installsFile: false)).install([.lidClosed])
        XCTAssertEqual(result, .failed)
    }

    func testACancelAfterTheMoveStillCountsAsInstalled() async {
        let result = await installer(FakeExecutor(.cancelled, installsFile: true)).install([.chargeByTime])
        XCTAssertEqual(result, .granted([.chargeByTime]))
    }


    func testInstallWithAMergedFileAndAnEmptyRecordWritesOnlyTheRequestedLine() async {
        // The script itself keeps the lines it finds (see SudoersScriptBehaviourTests); the app never rewrites from memory.
        let executor = FakeExecutor(.succeeded, files: [SudoersRules.mergedPath])
        let result = await installer(executor).install([.chargeByTime])
        XCTAssertEqual(result, .granted([.chargeByTime]))
        XCTAssertEqual(executor.scripts, [SudoersRules.installScript(uid: 501, features: [.chargeByTime])])
        XCTAssertFalse(executor.scripts.first?.contains("disablesleep") == true, "nothing derived from the (empty) record")
        XCTAssertEqual(PrivilegedRulePresence.recordedMergedFeatures(defaults), [.chargeByTime])
    }

    func testALaterRequestKeepsTheRecordedFeaturesInTheHint() async {
        PrivilegedRulePresence.record([.lidClosed], in: defaults)
        let executor = FakeExecutor(.succeeded, files: [SudoersRules.mergedPath])
        let result = await installer(executor).install([.chargeByTime])
        XCTAssertEqual(result, .granted([.chargeByTime]))
        XCTAssertEqual(PrivilegedRulePresence.recordedMergedFeatures(defaults), [.lidClosed, .chargeByTime])
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
        XCTAssertEqual(OsascriptAdministratorExecutor.outcome(status: 1, output: "other", cancelled: false), .failed)
        XCTAssertEqual(OsascriptAdministratorExecutor.outcome(status: 0, output: "", cancelled: false), .succeeded)
    }

    func testALaunchFailureFinishes() async {
        let result = await CancellableProcessRun.run(launch: { _ in throw CocoaError(.fileNoSuchFile) })
        XCTAssertEqual(result.status, CancellableProcessRun.launchFailed)
    }
}

final class FirstRunMotionTests: XCTestCase {
    typealias M = FirstRunMotion

    func testWindowScenesLoopThreeTimesThenFreezeOnTheExplanatoryFrame() {
        let frozen = M.whereScene(M.whereLoop.freezeAt, reduceMotion: false)
        XCTAssertEqual(M.whereScene(9.7, reduceMotion: false), frozen)
        XCTAssertEqual(M.whereScene(100, reduceMotion: false), frozen)
        XCTAssertEqual(M.whereScene(0.5, reduceMotion: false, jumpedToEnd: true), frozen, "any click jumps to the final frame")
        XCTAssertNotEqual(M.whereScene(0.5, reduceMotion: false), frozen)
        XCTAssertEqual(M.whereScene(0.5, reduceMotion: false), M.whereScene(0.5 + 3.2, reduceMotion: false), "loops")
        XCTAssertTrue(M.whereLoop.isFrozen(9.61, reduceMotion: false, jumpedToEnd: false))
        XCTAssertFalse(M.whereLoop.isFrozen(9.5, reduceMotion: false, jumpedToEnd: false))
        XCTAssertEqual(M.hiddenScene(8.5, reduceMotion: false), M.hiddenScene(M.hiddenLoop.freezeAt, reduceMotion: false))
        XCTAssertGreaterThan(frozen.popover, 0.9, "the frozen frame shows the opened panel")
    }

    func testReduceMotionIsStatic() {
        XCTAssertEqual(M.whereScene(0, reduceMotion: true), M.whereScene(5, reduceMotion: true))
        XCTAssertEqual(M.whereScene(0, reduceMotion: true).cursor, CGPoint(x: M.whereIconCenter.x + 3, y: M.whereIconCenter.y + 5))
        XCTAssertEqual(M.hiddenScene(0, reduceMotion: true), M.hiddenScene(2, reduceMotion: true))
        XCTAssertEqual(M.iconFill(0, reduceMotion: true), 1, "icon filled at once")
        XCTAssertEqual(M.beacon(0.3, reduceMotion: true), .init(bob: 0, ring: 0), "no beacon bobbing")
        XCTAssertEqual(M.touchPreview(0, reduceMotion: true), M.touchPreview(1, reduceMotion: true))
        XCTAssertLessThanOrEqual(M.crossfadeDuration(reduceMotion: true), 0.2)
        XCTAssertLessThanOrEqual(M.handOffDuration(reduceMotion: true), 0.2)
        XCTAssertEqual(M.handOffDuration(reduceMotion: false), 0.35)
        let guide = M.guide(1, from: .zero, to: CGPoint(x: 100, y: 50), reduceMotion: true)
        XCTAssertEqual(guide.point, CGPoint(x: 100, y: 50), "static cursor")
        XCTAssertEqual(guide.press, 0)
        XCTAssertEqual(M.bubble(0.5, reduceMotion: true).rings, [0, 0])
    }

    func testFinishedMotionStopsItsTimeline() {
        XCTAssertFalse(M.checksSettled(count: 4, 0.5, reduceMotion: false))
        XCTAssertTrue(M.checksSettled(count: 4, M.checksEnd(count: 4), reduceMotion: false))
        XCTAssertEqual(M.check(3, M.checksEnd(count: 4), reduceMotion: false), 1, "settles exactly when the last check is drawn")
        XCTAssertTrue(M.checksSettled(count: 0, 0, reduceMotion: true))
        XCTAssertFalse(M.beaconSettled(M.beaconMotionDuration - 0.01, reduceMotion: false))
        XCTAssertTrue(M.beaconSettled(M.beaconMotionDuration, reduceMotion: false))
        XCTAssertEqual(M.beacon(M.beaconMotionDuration, reduceMotion: false), .init(bob: 0, ring: 0), "the resting frame")
        XCTAssertTrue(M.beaconSettled(0, reduceMotion: true))
        XCTAssertFalse(M.breathingSettled(1, reduceMotion: false))
        XCTAssertTrue(M.breathingSettled(M.breathingDuration, reduceMotion: false))
        XCTAssertEqual(M.breathing(M.breathingDuration - 1e-9, reduceMotion: false), 1, accuracy: 1e-6, "no jump when it comes to rest")
        XCTAssertEqual(M.breathing(M.breathingDuration + 5, reduceMotion: false), 1)
    }

    func testIconFillReachesTheRealLevelIn07Seconds() {
        XCTAssertEqual(M.iconFillLevel(0, level: 80, reduceMotion: false), 0)
        XCTAssertEqual(M.iconFillLevel(0.7, level: 80, reduceMotion: false), 80)
        XCTAssertEqual(M.iconFillLevel(2, level: 80, reduceMotion: false), 80)
        let mid = M.iconFillLevel(0.35, level: 80, reduceMotion: false)
        XCTAssertTrue((40..<80).contains(mid))
    }

    func testOneShotPiecesEnd() {
        XCTAssertEqual(M.guide(M.guideDuration, from: .zero, to: CGPoint(x: 10, y: 10), reduceMotion: false).opacity, 0)
        XCTAssertEqual(M.bubble(M.bubbleDuration, reduceMotion: false).opacity, 0)
        XCTAssertEqual(M.beacon(M.beaconMotionDuration + 1, reduceMotion: false), .init(bob: 0, ring: 0))
        XCTAssertEqual(M.touchPreview(M.confirmPreviewDuration, reduceMotion: false).collapse, 1)
        XCTAssertEqual(M.check(0, 0.5, reduceMotion: false), 1)
        XCTAssertLessThan(M.check(3, 0.5, reduceMotion: false), 1, "checks draw in one by one")
        XCTAssertEqual(M.spring(10), 1, accuracy: 0.001)
    }
}

final class FirstRunCopyTests: XCTestCase {
    private static let keys = [
        "firstRun.window.title", "firstRun.window.subtitle", "firstRun.window.hidden.title", "firstRun.window.hidden.subtitle",
        "firstRun.window.accessibility", "firstRun.window.hidden.accessibility", "firstRun.cantSeeIcon", "firstRun.back", "firstRun.openHere",
        "firstRun.skip", "firstRun.preview", "firstRun.close", "firstRun.card.title", "firstRun.launchAtLogin", "firstRun.keepHistory",
        "firstRun.more", "firstRun.expanded", "firstRun.collapsed", "firstRun.chargeLimit", "firstRun.lidClosed", "firstRun.chargeByTime",
        "firstRun.needsPermission", "firstRun.done", "firstRun.confirm.title", "firstRun.confirm.subtitle", "firstRun.info.title",
        "firstRun.info.what", "firstRun.info.password", "firstRun.cancel", "firstRun.done.title", "firstRun.row.login", "firstRun.row.history",
        "firstRun.allow", "firstRun.check", "firstRun.declined.title", "firstRun.failed.title", "firstRun.turnOn", "firstRun.limitCoach",
        "firstRun.bubble", "Tilvero asks to allow narrow pmset commands without a password for the features you chose."]

    private func catalog() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TilveroApp/Resources/Localizable.xcstrings")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: Any])
    }
    private func value(_ strings: [String: Any], _ key: String, _ language: String) -> String? {
        (((strings[key] as? [String: Any])?["localizations"] as? [String: Any])?[language] as? [String: Any]).flatMap { ($0["stringUnit"] as? [String: Any])?["value"] as? String }
    }

    func testEveryFirstRunStringExistsInRussianAndEnglish() throws {
        let strings = try catalog()
        for key in Self.keys { for language in ["en", "ru"] { XCTAssertFalse(value(strings, key, language)?.isEmpty ?? true, "\(language): \(key)") } }
    }

    func testCopyIsShortWithoutCaveats() throws {
        let strings = try catalog()
        for language in ["en", "ru"] {
            let info = FirstRunCard.infoKeys.compactMap { value(strings, $0, language) }
            XCTAssertEqual(info.count, 2, "two short paragraphs")
            XCTAssertLessThanOrEqual(info.joined(separator: " ").split(separator: " ").count, 50, "\(language) info within ~50 words")
            for key in Self.keys where !key.hasSuffix("accessibility") && !key.hasPrefix("firstRun.info") && !key.hasPrefix("Tilvero asks") {
                let text = value(strings, key, language) ?? ""
                XCTAssertLessThanOrEqual(text.count, 34, "\(language) \(key): short labels, no captions: \(text)")
            }
            for key in Self.keys { XCTAssertFalse((value(strings, key, language) ?? "").localizedCaseInsensitiveContains("verified")) }
        }
    }
}

@MainActor private final class FakeHost: FirstRunHost {
    var behavior: NSPopover.Behavior = .transient
    var shown = false, finished = false
    var fills: [Double?] = []
    var firstRunStatusButtonFrame: NSRect? { nil }
    var firstRunPopoverShown: Bool { shown }
    func firstRunSetPopoverBehavior(_ behavior: NSPopover.Behavior) { self.behavior = behavior }
    func firstRunShowPopover() { shown = true }
    func firstRunClosePopover() { shown = false }
    func firstRunDrawIcon(fill: Double?) { fills.append(fill) }
    func firstRunFinished() { finished = true }
}

@MainActor final class FirstRunCoordinatorTests: XCTestCase {
    private var lidResult = true
    private var logins = 0, history: [Bool] = [], installs: [Set<PrivilegedFeature>] = [], lid = 0, marks = 0

    private func make() -> (FirstRunCoordinator, FakeHost) {
        let host = FakeHost()
        let ports = FirstRunPorts(markIntroduced: { self.marks += 1 }, setHistory: { self.history.append($0) },
                                  registerLogin: { self.logins += 1; return .enabled }, openLoginItemsSettings: {},
                                  install: { self.installs.append($0); return .granted($0) }, turnOnLid: { self.lid += 1; return self.lidResult })
        let session = FirstRunSession(isPreview: true)
        session.speed = 20
        return (FirstRunCoordinator(session: session, ports: ports, host: host), host)
    }

    func testLoginIsRegisteredOnlyByDoneWithTheSwitchOn() {
        let (coordinator, host) = make()
        coordinator.jump(to: .card)
        XCTAssertEqual(host.behavior, .applicationDefined)
        coordinator.session.flow.choices.launchAtLogin = false
        coordinator.session.flow.choices.keepHistory = false
        coordinator.session.send(.done)
        XCTAssertEqual(logins, 0)
        XCTAssertEqual(history, [false])
        XCTAssertTrue(installs.isEmpty)
        coordinator.popoverDidClose()   // ignored right after a jump (debug close)
        XCTAssertEqual(coordinator.session.step, .done)
        coordinator.teardown()
    }

    func testLockedFeaturesUseOneInstallAfterThePreviewAndRestoreTransient() async throws {
        let (coordinator, host) = make()
        coordinator.jump(to: .card)
        coordinator.session.flow.choices.lidClosed = true
        coordinator.session.flow.choices.chargeByTime = true
        coordinator.session.send(.done)
        XCTAssertEqual(logins, 1)
        XCTAssertEqual(coordinator.session.step, .confirmPreview)
        for _ in 0..<100 where coordinator.session.step != .done { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(coordinator.session.step, .done)
        XCTAssertEqual(installs, [[.lidClosed, .chargeByTime]], "one prompt for both")
        for _ in 0..<100 where coordinator.session.flow.lidEnabled == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(lid, 1)
        XCTAssertEqual(coordinator.session.flow.grantedRows.first?.kind, .enabled)
        try await Task.sleep(for: .milliseconds(900))
        coordinator.popoverDidClose()
        XCTAssertEqual(coordinator.session.step, .bubble)
        XCTAssertEqual(host.behavior, .transient)
        host.shown = true   // the user opens the quick panel while the bubble plays
        for _ in 0..<150 where !host.finished { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(host.finished)
        XCTAssertTrue(host.shown, "the end of the flow never closes a popover the user opened")
    }

    func testARefusedLidOptionIsShownAsNotEnabled() async throws {
        lidResult = false
        let (coordinator, _) = make()
        coordinator.jump(to: .card)
        coordinator.session.flow.choices.lidClosed = true
        coordinator.session.send(.done)
        for _ in 0..<150 where coordinator.session.flow.lidEnabled == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(coordinator.session.flow.lidEnabled, false)
        XCTAssertEqual(coordinator.session.flow.grantedRows.map(\.kind), [.notEnabled])
        coordinator.teardown()
    }

    func testDebugRestartAndJumpStillCloseThePopover() {
        let (coordinator, host) = make()
        host.shown = true
        coordinator.teardown()
        XCTAssertFalse(host.shown)
    }
}
