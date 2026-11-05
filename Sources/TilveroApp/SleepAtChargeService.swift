import Foundation
import Combine

/// One-shot "sleep when the charge falls to N %". The intent lives only in memory: it is consumed when it fires,
/// and cancelled by sleep, wake, a lost console session, a stop or an explicit cancel, so a wake at a low charge
/// can never put the Mac straight back to sleep. It fires only from a fresh charge reading taken on battery
/// power; it never keeps the Mac awake and changes no power setting (the request is the same explicit system
/// sleep the sleep timer uses).
@MainActor final class SleepAtChargeService: ObservableObject {
    static let targets = [50, 30, 20, 10, 5]

    @Published private(set) var target: Int?
    @Published private(set) var message: String?
    @Published private(set) var isRequesting = false
    /// Latest fresh reading, for the status line and for refusing targets that are already reached.
    @Published private(set) var currentPercent: Int?
    @Published private(set) var onExternalPower: Bool?

    /// Safe preparation before the sleep request (same contract as the sleep timer's).
    var prepare: @MainActor () async -> Bool
    private let driver: any SleepTimerTransport
    private let allowed: Bool
    private var generation: UInt64 = 0

    init(driver: any SleepTimerTransport, allowed: Bool = true, prepare: @escaping @MainActor () async -> Bool = { true }) {
        self.driver = driver; self.allowed = allowed; self.prepare = prepare
    }

    var isAvailable: Bool { allowed }
    var isArmed: Bool { target != nil }
    /// A target is offered only when it lies below the present charge; arming at or above it would sleep at once.
    func canArm(target candidate: Int) -> Bool {
        allowed && !isRequesting && driver.isCurrentConsoleSession() && (currentPercent.map { candidate < $0 } ?? false)
    }
    var canChooseTarget: Bool { Self.targets.contains { canArm(target: $0) } }

    func arm(target candidate: Int) throws {
        guard allowed else { throw SleepAtChargeError.unavailable }
        guard Self.targets.contains(candidate) || (1...99).contains(candidate) else { throw SleepAtChargeError.invalidTarget }
        guard !isRequesting, driver.isCurrentConsoleSession() else { throw SleepAtChargeError.unavailable }
        guard let percent = currentPercent else { throw SleepAtChargeError.chargeUnknown }
        guard candidate < percent else { throw SleepAtChargeError.alreadyReached }
        generation &+= 1
        target = candidate
        message = nil
    }

    func disarm(message note: String? = "Sleep at charge cancelled.") {
        guard target != nil else { return }
        generation &+= 1
        target = nil
        message = note
    }

    func systemWillSleep() { disarm(message: "Sleep at charge cancelled because the Mac went to sleep.") }
    func systemDidWake() { disarm(message: "Sleep at charge cancelled because the Mac woke from sleep.") }
    func sessionResigned() { disarm(message: "Sleep at charge cancelled because this user session is no longer active.") }
    func stop() { disarm(message: nil) }

    /// Called with every battery observation. Only a fresh percentage on battery power can trigger the request.
    func observe(percent: Int?, fresh: Bool, externalPower: Bool?) async {
        currentPercent = fresh ? percent.flatMap { (0...100).contains($0) ? $0 : nil } : currentPercent
        onExternalPower = externalPower
        guard let goal = target, !isRequesting, fresh, let percent, (0...100).contains(percent),
              externalPower == false, percent <= goal else { return }
        guard driver.isCurrentConsoleSession() else { sessionResigned(); return }
        let id = generation
        isRequesting = true
        message = "Preparing for sleep…"
        let ready = await prepare()
        guard generation == id, target == goal else { isRequesting = false; return }
        // The intent is consumed before the single native call; nothing can re-fire it.
        generation &+= 1
        target = nil
        guard ready, driver.isCurrentConsoleSession() else {
            isRequesting = false
            message = "Sleep at charge cancelled because safe preparation could not be confirmed."
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
    case unavailable, invalidTarget, chargeUnknown, alreadyReached
    var errorDescription: String? {
        switch self {
        case .unavailable: L10n.text("Sleep at charge is unavailable in this build or simulation.")
        case .invalidTarget: L10n.text("Choose a charge between 1 and 99 %.")
        case .chargeUnknown: L10n.text("The charge level is not known yet.")
        case .alreadyReached: L10n.text("The battery is already at or below that level.")
        }
    }
}
