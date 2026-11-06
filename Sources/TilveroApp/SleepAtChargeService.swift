// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import Combine

/// One-shot "stay awake until the charge falls to N %, then sleep" (the sleep timer with a charge condition instead
/// of a time). While armed it holds a finite idle-sleep assertion (at most `maximumHold`), released before the
/// sleep request. The intent lives only in memory: it is consumed when it fires, and cancelled by sleep, wake, a
/// lost console session, a stop, the hold limit or an explicit cancel, so a wake at a low charge can never put the
/// Mac straight back to sleep. It fires only from a fresh charge reading taken on battery power and changes no
/// power setting (the request is the same explicit system sleep the sleep timer uses).
@MainActor final class SleepAtChargeService: ObservableObject {
    /// What happens at the level: force a system sleep (after safe preparation), or only stop holding the Mac awake.
    enum EndAction { case sleep, release }
    static let targets = [50, 30, 20, 10, 5]
    static let maximumHold: TimeInterval = 24 * 3600

    @Published private(set) var target: Int?
    @Published private(set) var message: String?
    @Published private(set) var isRequesting = false
    /// Latest fresh reading, for the status line and for refusing targets that are already reached.
    @Published private(set) var currentPercent: Int?
    @Published private(set) var onExternalPower: Bool?

    /// Name of another running sleep or keep-awake mode that forbids starting this one (set by the model).
    var blockedBy: @MainActor () -> String? = { nil }

    /// Safe preparation before the sleep request (same contract as the sleep timer's).
    var prepare: @MainActor () async -> Bool
    private let driver: any SleepTimerTransport
    private let allowed: Bool
    private let endAction: EndAction
    private let now: @MainActor () -> Date
    private var generation: UInt64 = 0
    private var armedAt: Date?
    @Published private(set) var isHoldingAwake = false

    init(driver: any SleepTimerTransport, allowed: Bool = true, endAction: EndAction = .sleep, now: @escaping @MainActor () -> Date = { Date() },
         prepare: @escaping @MainActor () async -> Bool = { true }) {
        self.endAction = endAction
        self.driver = driver; self.allowed = allowed; self.prepare = prepare; self.now = now
        isHoldingAwake = driver.hasIdleHold
    }

    var isAvailable: Bool { allowed }
    /// Neutral outcomes (cancelled, requested) are state, not trouble; only the rest is worth a warning line.
    var problemMessage: String? {
        guard let text = message, !Self.neutralMessages.contains(text) else { return nil }
        return text
    }
    private static let neutralMessages: Set<String> = [
        "Sleep at charge cancelled.", "Sleep at charge cancelled because the Mac went to sleep.",
        "Sleep at charge cancelled because the Mac woke from sleep.",
        "Sleep at charge cancelled because this user session is no longer active.",
        "Preparing for sleep…", "Sleep requested at the chosen charge.",
    ]
    var isArmed: Bool { target != nil }
    /// A target is offered only when it lies below the present charge; arming at or above it would sleep at once.
    func canArm(target candidate: Int) -> Bool {
        allowed && !isRequesting && blockedBy() == nil && driver.isCurrentConsoleSession() && (currentPercent.map { candidate < $0 } ?? false)
    }
    var canChooseTarget: Bool { Self.targets.contains { canArm(target: $0) } }

    func arm(target candidate: Int) throws {
        guard allowed else { throw SleepAtChargeError.unavailable }
        guard Self.targets.contains(candidate) || (1...99).contains(candidate) else { throw SleepAtChargeError.invalidTarget }
        guard !isRequesting, driver.isCurrentConsoleSession() else { throw SleepAtChargeError.unavailable }
        // Only one sleep / keep-awake mode at a time (changing the level of this one is not a new mode).
        if target == nil, blockedBy() != nil { throw SleepAtChargeError.otherModeActive }
        guard let percent = currentPercent else { throw SleepAtChargeError.chargeUnknown }
        guard candidate < percent else { throw SleepAtChargeError.alreadyReached }
        if target == nil {
            do {
                try driver.acquireIdleHold(seconds: Int(Self.maximumHold))
                guard driver.hasIdleHold else { throw KeepAwakeError.unconfirmed }
            } catch {
                releaseHold()
                message = "Sleep at charge could not keep the Mac awake. It was not started."
                throw error
            }
            armedAt = now()
        }   // Changing the level of an armed intent keeps its hold and its 24 h limit.
        generation &+= 1
        target = candidate
        isHoldingAwake = true
        message = nil
    }

    func disarm(message note: String? = "Sleep at charge cancelled.") {
        guard target != nil || driver.hasIdleHold else { return }
        generation &+= 1
        target = nil
        armedAt = nil
        let released = releaseHold()
        message = released ? note : "The awake hold could not be released. Try Cancel again."
    }

    /// Ownership stays with the transport after a failed release; the next cancel retries only this hold.
    @discardableResult private func releaseHold() -> Bool {
        guard driver.hasIdleHold else { isHoldingAwake = false; return true }
        do { try driver.releaseIdleHold() } catch {}
        isHoldingAwake = driver.hasIdleHold
        return !driver.hasIdleHold
    }

    func systemWillSleep() { disarm(message: "Sleep at charge cancelled because the Mac went to sleep.") }
    func systemDidWake() { disarm(message: "Sleep at charge cancelled because the Mac woke from sleep.") }
    func sessionResigned() { disarm(message: "Sleep at charge cancelled because this user session is no longer active.") }
    func stop() { disarm(message: nil) }

    /// Called with every battery observation. Only a fresh percentage on battery power can trigger the request.
    func observe(percent: Int?, fresh: Bool, externalPower: Bool?) async {
        currentPercent = fresh ? percent.flatMap { (0...100).contains($0) ? $0 : nil } : currentPercent
        onExternalPower = externalPower
        if let start = armedAt, target != nil, !isRequesting, now().timeIntervalSince(start) >= Self.maximumHold {
            disarm(message: "Sleep at charge cancelled after 24 hours."); return
        }
        guard let goal = target, !isRequesting, fresh, let percent, (0...100).contains(percent),
              externalPower == false, percent <= goal else { return }
        guard driver.isCurrentConsoleSession() else { sessionResigned(); return }
        if endAction == .release {
            // Reached: stop holding the Mac awake; it then sleeps by itself as usual.
            generation &+= 1
            target = nil
            armedAt = nil
            if !releaseHold() { message = "The awake hold could not be released. Try Cancel again." }
            return
        }
        let id = generation
        isRequesting = true
        message = "Preparing for sleep…"
        let ready = await prepare()
        guard generation == id, target == goal else { isRequesting = false; return }
        // The intent is consumed before the single native call; nothing can re-fire it.
        generation &+= 1
        target = nil
        armedAt = nil
        guard ready, driver.isCurrentConsoleSession() else {
            releaseHold()
            isRequesting = false
            message = "Sleep at charge cancelled because safe preparation could not be confirmed."
            return
        }
        // The hold is released before the single native request, exactly as the sleep timer does.
        guard releaseHold() else {
            isRequesting = false
            message = "The awake hold could not be released. Try Cancel again."
            return
        }
        do {
            try driver.requestSleep()
            message = "Sleep requested at the chosen charge."
        } catch {
            message = "macOS declined the sleep request."
        }
        isRequesting = false
    }
}

enum SleepAtChargeError: LocalizedError {
    case unavailable, invalidTarget, chargeUnknown, alreadyReached, otherModeActive
    var errorDescription: String? {
        switch self {
        case .unavailable: L10n.text("Sleep at charge is unavailable in this build or simulation.")
        case .invalidTarget: L10n.text("Choose a charge between 1 and 99 %.")
        case .chargeUnknown: L10n.text("The charge level is not known yet.")
        case .alreadyReached: L10n.text("The battery is already at or below that level.")
        case .otherModeActive: L10n.text("Another sleep or Keep Awake mode is running. Turn it off first.")
        }
    }
}
// tlv-origin:c0cb3ac78460a24d
