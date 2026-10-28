import Foundation
import Combine
import ChargeBackends
import PowerCore

struct NativeChargeJournal: Codable, Sendable {
    enum Phase: String, Codable { case pendingTarget, preparing, owned, restoring, restorationPending, indeterminate }
    var version = 1
    let sessionID: UUID
    let environment: String
    let baseline: NativeChargeConfiguration
    var lastVerified: NativeChargeConfiguration
    var plannedTarget: Int?
    var phase: Phase
    var hasWritten = false
    var expectedMutation: NativeChargeConfiguration?
    var oneShotPreviousManagedTarget: Int?
    var oneShot = false
}

enum NativeChargeServiceError: Error, LocalizedError {
    case unavailable, busy, unsupportedTarget, staleBattery, recoveryRequired, readbackMismatch, unsafeEnable
    var errorDescription: String? {
        switch self {
        case .unavailable: "Native charging control has not completed its local validation."
        case .busy: "A native charging operation is still in progress."
        case .unsupportedTarget: "Choose a charge target offered by this Mac."
        case .staleBattery: "A fresh battery reading is required before changing charging."
        case .recoveryRequired: "Reconcile the previous native charging session before applying another target."
        case .readbackMismatch: "macOS has not independently confirmed the requested charge setting."
        case .unsafeEnable: "Enabling the previous system target could discharge the battery. Waiting for natural discharge."
        }
    }
}

/// A managed session over the normal-user Apple client. It never registers a
/// helper, changes OBC, guesses a root qualification, or fights external edits.
@MainActor final class NativeChargeService: ObservableObject {
    @Published private(set) var observed: NativeChargeSnapshot? {
        didSet { if let observed, observed.isFresh && observed.policyMatches { knownTargets = observed.supportedTargets } }
    }
    private var knownTargets: [Int] = []
    @Published private(set) var pendingTarget: Int?
    @Published private(set) var restorationPending = false
    @Published private(set) var recoveryRequired = false
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    private let client: any NativeChargeTransport
    private let operationGate: NativeChargeOperationGate
    private let fullOnceQualified: Bool
    private let journalURL: URL
    @Published private(set) var admitted: Bool
    @Published private(set) var isQualifying = false
    private let batteryProvider: (@Sendable () async -> ChargeObservation)?
    private let admissionURL: URL?
    private let monitoringOnly: Bool
    private let verificationAttempts: Int
    private let verificationDelay: Duration
    private let environment: String
    private var journal: NativeChargeJournal?
    private var journalInvalid = false
    private var batteryPercent: Int?
    private var batteryFresh = false

    var isMonitoringOnly: Bool { monitoringOnly }
    var hasOwnedSettings: Bool { journal?.hasWritten == true }
    var isAvailable: Bool { !operationGate.pending && admitted && !monitoringOnly && !journalInvalid && observed?.isFresh == true && observed?.policyMatches == true }
    var canApply: Bool { isAvailable && !isBusy && !isQualifying && !recoveryRequired && !restorationPending }
    var canChargeToFullOnce: Bool { canApply && fullOnceQualified }
    var isOneShot: Bool { journal?.oneShot == true }
    var requestedIntent: ChargeIntent? {
        if isOneShot { return .fullOnce }
        if let pendingTarget { return .ceiling(pendingTarget) }
        if journal?.hasWritten == true, let target = journal?.lastVerified.target { return .ceiling(target) }
        return nil
    }
    var acceptedTargets: [Int] { knownTargets }
    var interfaceWasDiscovered: Bool { !knownTargets.isEmpty || admitted || journal != nil || journalInvalid }
    var baselineTarget: Int? { journal?.baseline.target }

    init(client: any NativeChargeTransport, journalURL: URL, admitted: Bool = false, monitoringOnly: Bool = false,
         verificationAttempts: Int = 30, verificationDelay: Duration = .zero,
         environment: String = ProcessInfo.processInfo.operatingSystemVersionString,
         batteryProvider: (@Sendable () async -> ChargeObservation)? = nil, admissionURL: URL? = nil,
         operationTimeout: Duration = .seconds(15), fullOnceQualified: Bool = false) {
        operationGate = NativeChargeOperationGate(timeout: operationTimeout); self.fullOnceQualified = fullOnceQualified
        self.client = client; self.journalURL = journalURL; self.admitted = admitted && !monitoringOnly; self.monitoringOnly = monitoringOnly
        self.batteryProvider = batteryProvider; self.admissionURL = admissionURL
        self.verificationAttempts = max(1, verificationAttempts); self.verificationDelay = verificationDelay; self.environment = environment
        if !monitoringOnly && FileManager.default.fileExists(atPath: journalURL.path) {
            do {
                let saved = try JSONDecoder().decode(NativeChargeJournal.self, from: Data(contentsOf: journalURL))
                guard saved.version == 1, saved.environment == environment,
                      (80...100).contains(saved.baseline.target), (80...100).contains(saved.lastVerified.target),
                      saved.plannedTarget.map({ (80...100).contains($0) }) ?? true else { throw NativeChargeServiceError.recoveryRequired }
                journal = saved; recoveryRequired = true
                restorationPending = saved.phase == .restorationPending
                message = "A previous native charge session needs explicit recovery. Saved intent was not reapplied."
            } catch {
                journalInvalid = true; recoveryRequired = true
                message = "The saved native charge session cannot be read safely. It was preserved."
            }
        }
        operationGate.onTimeout = { [weak self] in
            guard let self else { return }
            if self.journal?.hasWritten == true {
                self.journal?.phase = .indeterminate; self.recoveryRequired = true; try? self.saveJournal()
            }
            self.observed = nil
            self.message = "macOS did not respond before the deadline. The call may still complete; further writes are blocked."
        }
        operationGate.onLateCompletion = { [weak self] in
            self?.objectWillChange.send()
            self?.message = "The delayed macOS call has returned. Read and reconcile its result before changing charging."
        }
    }

    convenience init(historyURL: URL) {
        let root = historyURL.deletingLastPathComponent()
        let environment = NativeChargeAdmission.currentEnvironment
        let admission = root.appendingPathComponent("native-charge-validation.json")
        let monitoring = Bundle.main.object(forInfoDictionaryKey: "TilveroReleaseMode") as? String == "monitoring"
        let reader = NativeChargeBackend()
        self.init(client: PowerUIChargeClient(), journalURL: root.appendingPathComponent("native-charge-session.json"),
                  admitted: NativeChargeAdmission.load(from: admission, environment: environment), monitoringOnly: monitoring,
                  verificationAttempts: 30, verificationDelay: .seconds(2), environment: environment,
                  batteryProvider: { await reader.currentObservation() }, admissionURL: admission)
    }

    func qualify() async throws {
        guard !monitoringOnly, !isBusy, !operationGate.pending, !isQualifying, journal == nil, !journalInvalid,
              let admissionURL, environment != "unavailable", let batteryProvider else { throw NativeChargeServiceError.unavailable }
        isQualifying = true
        let previouslyAdmitted = admitted
        defer { isQualifying = false }
        let baseline = try await readNative()
        let battery = await batteryProvider()
        guard baseline.isFresh && baseline.policyMatches && baseline.supportedTargets.contains(100),
              battery.fresh, let percent = battery.percent, percent <= min(baseline.configuration.target, 100) - 2,
              baseline.configuration.target != 100 else {
            message = "For the bounded native test, unplug and let the battery fall at least two percentage points below the existing limit. No setting was written."
            throw NativeChargeServiceError.staleBattery
        }
        // Explicit opt-in qualification is a finite journaled transaction, not a
        // preference that switches on untested writes. Ordinary UI Apply stays disabled.
        admitted = true
        do {
            try await applyInternal(100, batteryPercent: percent, batteryFresh: true)
            guard let changed = observed, changed.policyMatches, changed.configuration.target == 100,
                  changed.configuration.optimizedCharging == baseline.configuration.optimizedCharging else { throw NativeChargeServiceError.readbackMismatch }
            let after = await batteryProvider()
            guard try await restoreInternal(batteryPercent: after.percent, batteryFresh: after.fresh), let restored = observed,
                  restored.configuration == baseline.configuration, restored.policyMatches else { throw NativeChargeServiceError.recoveryRequired }
            let proof = NativeChargeAdmission(version: NativeChargeAdmission.version, environment: environment,
                offeredTargets: baseline.supportedTargets, baseline: baseline.configuration,
                changed: changed, restored: restored, completedAt: Date())
            try JSONEncoder().encode(proof).write(to: admissionURL, options: .atomic)
            admitted = NativeChargeAdmission.load(from: admissionURL, environment: environment)
            guard admitted else { throw NativeChargeServiceError.readbackMismatch }
            message = "Native limit setting and restoration passed on this Mac. Physical cutoff remains separately observed."
        } catch {
            admitted = previouslyAdmitted
            if journal != nil { recoveryRequired = true }
            throw error
        }
    }

    func refresh() async {
        guard !isBusy, !isQualifying, !operationGate.pending else { return }
        isBusy = true; defer { isBusy = false }
        do {
            let value = try await readNative()
            guard value.isFresh && value.policyMatches else {
                observed = nil
                message = "The native policy readback is unavailable or inconsistent. The ownership journal was preserved."
                return
            }
            observed = value
            if !monitoringOnly, let journal, journal.phase != .preparing && journal.phase != .restoring && journal.phase != .indeterminate,
               !value.configuration.matchesManual(journal.lastVerified) {
                try relinquish()
                message = "The macOS charge setting changed outside Tilvero. Control was released without overwriting it."
            }
        } catch { observed = nil; message = error.localizedDescription }
    }

    func apply(_ target: Int, batteryPercent: Int?, batteryFresh: Bool) async throws {
        guard !isQualifying else { throw NativeChargeServiceError.busy }
        try await applyInternal(target, batteryPercent: batteryPercent, batteryFresh: batteryFresh)
    }
    private func applyInternal(_ target: Int, batteryPercent: Int?, batteryFresh: Bool) async throws {
        guard !monitoringOnly, admitted, !journalInvalid else { throw NativeChargeServiceError.unavailable }
        guard !isBusy, !operationGate.pending else { throw NativeChargeServiceError.busy }
        guard !recoveryRequired && !restorationPending else { throw NativeChargeServiceError.recoveryRequired }
        guard batteryFresh, let percent = batteryPercent, (0...100).contains(percent) else { throw NativeChargeServiceError.staleBattery }
        self.batteryPercent = percent; self.batteryFresh = true
        isBusy = true; defer { isBusy = false }
        let current = try await readNative()
        observed = current
        guard current.isFresh && current.policyMatches else { throw NativeChargeServiceError.readbackMismatch }
        guard current.supportedTargets.contains(target) else { throw NativeChargeServiceError.unsupportedTarget }
        if let journal, !current.configuration.matchesManual(journal.lastVerified) {
            try relinquish(); throw NativeChargeServiceError.recoveryRequired
        }
        if current.configuration.enabled && current.configuration.target == target {
            pendingTarget = nil
            if journal?.hasWritten == false { try relinquish() }
            else if journal != nil { journal?.phase = .owned; journal?.plannedTarget = nil; try saveJournal() }
            message = "The selected native limit is already active."; return
        }
        if journal == nil {
            journal = .init(sessionID: UUID(), environment: environment, baseline: current.configuration,
                            lastVerified: current.configuration, plannedTarget: target, phase: .preparing)
        }
        journal?.plannedTarget = target
        // One percentage point guards the rounded UI reading. An already-active
        // limit is handled above, without reasserting any hardware setting.
        let safeFloor = current.configuration.enabled ? target : min(target, current.configuration.target)
        if percent >= safeFloor {
            journal?.phase = .pendingTarget; try saveJournal()
            pendingTarget = target
            message = "Waiting for natural discharge before applying the lower native limit. The current system setting remains active."
            return
        }
        journal?.phase = .preparing; try saveJournal()
        do {
            if !current.configuration.enabled {
                try await mutate(expected: .init(enabled: true, target: current.configuration.target, optimizedCharging: current.configuration.optimizedCharging)) {
                    try await self.setNativeEnabled(true)
                }
            }
            try await mutate(expected: .init(enabled: true, target: target, optimizedCharging: current.configuration.optimizedCharging), permitDisabled100: target == 100) {
                try await self.setNativeLimit(target)
            }
            let verified = try await verify(target: target, enabled: nil)
            journal?.lastVerified = verified.configuration; journal?.phase = .owned; journal?.plannedTarget = nil
            try saveJournal(); observed = verified; pendingTarget = nil
            message = "The native macOS charge limit was independently confirmed."
        } catch {
            guard journal != nil else { throw error }
            if case NativeChargeServiceError.unsafeEnable = error {
                journal?.phase = .pendingTarget; pendingTarget = target; try saveJournal()
                message = NativeChargeServiceError.unsafeEnable.localizedDescription
                return
            }
            journal?.phase = .indeterminate; recoveryRequired = true
            try? saveJournal()
            message = "The outcome needs recovery. No additional setting was written after the unconfirmed operation."
            throw error
        }
    }

    func observeBattery(percent: Int?, fresh: Bool) async {
        batteryPercent = percent; batteryFresh = fresh
        guard !isBusy, !isQualifying, !operationGate.pending, !recoveryRequired, fresh, let percent else { return }
        if isOneShot && percent >= 100 {
            try? await cancelOneShot(batteryPercent: percent, batteryFresh: true)
        } else if restorationPending {
            _ = try? await restore(batteryPercent: percent, batteryFresh: true)
        } else if let target = pendingTarget, percent < target {
            do { try await apply(target, batteryPercent: percent, batteryFresh: true) }
            catch { message = error.localizedDescription }
        }
    }

    @discardableResult func restore(batteryPercent: Int?, batteryFresh: Bool) async throws -> Bool {
        guard !isQualifying else { throw NativeChargeServiceError.busy }
        return try await restoreInternal(batteryPercent: batteryPercent, batteryFresh: batteryFresh)
    }
    private func restoreInternal(batteryPercent: Int?, batteryFresh: Bool) async throws -> Bool {
        guard !isBusy, !operationGate.pending else { throw NativeChargeServiceError.busy }
        guard !monitoringOnly, (admitted || journal?.hasWritten == true), !journalInvalid else {
            if journal != nil || journalInvalid { throw NativeChargeServiceError.unavailable }
            return true
        }
        guard let saved = journal else { pendingTarget = nil; recoveryRequired = false; return true }
        isBusy = true; defer { isBusy = false }
        let current = try await readNative(); observed = current
        guard current.isFresh && current.policyReadbackAvailable else { throw NativeChargeServiceError.readbackMismatch }
        if [NativeChargeJournal.Phase.indeterminate, .preparing, .restoring].contains(saved.phase) && saved.hasWritten && current.configuration.matchesManual(saved.baseline) {
            recoveryRequired = true
            message = "An unconfirmed native operation may still take effect. The recovery journal was preserved; no follow-up write was started."
            return false
        }
        if current.configuration.matchesManual(saved.baseline) && current.policyMatches {
            try relinquish(); message = "The original macOS charge setting is confirmed."; return true
        }
        // An unknown operation can have completed after the last verified state.
        // Accept only the exact journaled planned target for explicit recovery.
        let matchesPlanned = (saved.phase == .indeterminate || saved.phase == .preparing || saved.phase == .restoring) && saved.expectedMutation.map { current.configuration.matchesManual($0) || ($0.target == 100 && current.configuration.target == 100) } == true
        guard current.configuration.matchesManual(saved.lastVerified) || matchesPlanned else {
            try relinquish(); message = "An external macOS charge change was preserved."; return true
        }
        let latest = await self.batteryProvider?()
        let restoreFresh = latest?.fresh ?? batteryFresh
        let restorePercent = latest != nil ? latest!.percent : batteryPercent
        guard restoreFresh, let percent = restorePercent, (0...100).contains(percent) else { throw NativeChargeServiceError.staleBattery }
        self.batteryPercent = percent; self.batteryFresh = true
        let safeRestoreFloor = current.configuration.enabled ? saved.baseline.target : min(saved.baseline.target, current.configuration.target)
        let needsTargetChange = current.configuration.target != saved.baseline.target
        let canDisableWithoutTargetChange = !saved.baseline.enabled && !needsTargetChange
        if !canDisableWithoutTargetChange && safeRestoreFloor <= percent {
            journal?.phase = .restorationPending; restorationPending = true
            recoveryRequired = false; try saveJournal()
            message = "Restoring the original limit is waiting for natural discharge. Keep Tilvero open; the current limit remains active."
            return false
        }
        journal?.phase = .restoring; try saveJournal()
        do {
            journal?.lastVerified = current.configuration; try saveJournal()
            if !current.configuration.enabled {
                try await mutate(expected: .init(enabled: true, target: current.configuration.target, optimizedCharging: current.configuration.optimizedCharging)) {
                    try await self.setNativeEnabled(true)
                }
            }
            if needsTargetChange {
                try await mutate(expected: .init(enabled: true, target: saved.baseline.target, optimizedCharging: current.configuration.optimizedCharging)) {
                    try await self.setNativeLimit(saved.baseline.target)
                }
            }
            if !saved.baseline.enabled {
                try await mutate(expected: .init(enabled: false, target: saved.baseline.target, optimizedCharging: current.configuration.optimizedCharging)) {
                    try await self.setNativeEnabled(false)
                }
            }
            let value = try await verify(target: saved.baseline.target, enabled: saved.baseline.enabled)
            observed = value; try relinquish()
            message = "The original macOS charge setting was verified as restored."
            return true
        } catch {
            guard journal != nil else { recoveryRequired = false; throw error }
            if case NativeChargeServiceError.unsafeEnable = error {
                journal?.phase = .restorationPending; restorationPending = true; recoveryRequired = false; try saveJournal()
                message = NativeChargeServiceError.unsafeEnable.localizedDescription
                return false
            }
            journal?.phase = .indeterminate; journal?.plannedTarget = saved.baseline.target
            recoveryRequired = true; try? saveJournal(); throw error
        }
    }

    func chargeToFullOnce(batteryPercent: Int?, batteryFresh: Bool) async throws {
        guard fullOnceQualified else { throw NativeChargeServiceError.unavailable }
        let previous = hasOwnedSettings ? observed?.configuration.target : nil
        try await apply(100, batteryPercent: batteryPercent, batteryFresh: batteryFresh)
        guard journal != nil else { return }
        journal?.oneShot = true; journal?.oneShotPreviousManagedTarget = previous; try saveJournal()
    }
    func cancelOneShot(batteryPercent: Int?, batteryFresh: Bool) async throws {
        guard let saved = journal, saved.oneShot else { return }
        journal?.oneShot = false; journal?.oneShotPreviousManagedTarget = nil; try saveJournal()
        if let target = saved.oneShotPreviousManagedTarget {
            try await apply(target, batteryPercent: batteryPercent, batteryFresh: batteryFresh)
        } else { _ = try await restore(batteryPercent: batteryPercent, batteryFresh: batteryFresh) }
    }

    func cancelPending() throws {
        guard !isBusy, !isQualifying, !operationGate.pending else { throw NativeChargeServiceError.busy }
        guard !recoveryRequired, journal?.phase == .pendingTarget else { throw NativeChargeServiceError.recoveryRequired }
        pendingTarget = nil
        if journal?.hasWritten == false { try relinquish() }
        else { journal?.phase = .owned; journal?.plannedTarget = nil; try saveJournal() }
    }

    private func mutate(expected: NativeChargeConfiguration, permitDisabled100: Bool = false,
                        operation: @MainActor () async throws -> Void) async throws {
        guard let saved = journal else { throw NativeChargeServiceError.recoveryRequired }
        let before = try await readNative(); observed = before
        guard before.isFresh, before.policyReadbackAvailable, before.policyMatches else {
            throw NativeChargeServiceError.readbackMismatch
        }
        guard before.configuration.matchesManual(saved.lastVerified) else {
            try relinquish()
            message = "An external charge change was preserved before the next operation."
            throw NativeChargeServiceError.recoveryRequired
        }
        let battery = await batteryProvider?()
        let fresh = battery?.fresh ?? batteryFresh
        let percent = battery != nil ? battery!.percent : batteryPercent
        guard fresh, let percent else { throw NativeChargeServiceError.staleBattery }
        if expected.enabled && expected.target != before.configuration.target && percent >= expected.target {
            throw NativeChargeServiceError.unsafeEnable
        }
        if expected.enabled && !before.configuration.enabled && percent >= before.configuration.target {
            throw NativeChargeServiceError.unsafeEnable
        }
        // Write-ahead state includes even intermediate enable/disable operations.
        // A crash or error cannot make an unacknowledged mutation look untouched.
        journal?.expectedMutation = expected; journal?.hasWritten = true; try saveJournal()
        try await operation()
        let after = try await readNative(); observed = after
        guard after.isFresh && (after.configuration.matchesManual(expected) || (permitDisabled100 && after.configuration.target == 100)) else {
            throw NativeChargeServiceError.readbackMismatch
        }
        journal?.lastVerified = after.configuration; journal?.expectedMutation = nil; try saveJournal()
    }

    private func readNative() async throws -> NativeChargeSnapshot {
        try await operationGate.call { [client] in try await client.read() }
    }
    private func setNativeLimit(_ target: Int) async throws {
        try await operationGate.call { [client] in try await client.setLimit(target) }
    }
    private func setNativeEnabled(_ enabled: Bool) async throws {
        try await operationGate.call { [client] in try await client.setEnabled(enabled) }
    }

    private func verify(target: Int, enabled: Bool?) async throws -> NativeChargeSnapshot {
        for attempt in 0..<verificationAttempts {
            let value = try await readNative(); observed = value
            if value.isFresh && value.configuration.target == target && (enabled.map { $0 == value.configuration.enabled } ?? true) && value.policyMatches {
                return value
            }
            if attempt + 1 < verificationAttempts { try await Task.sleep(for: verificationDelay) }
        }
        throw NativeChargeServiceError.readbackMismatch
    }
    private func saveJournal() throws {
        guard let journal else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }
    private func relinquish() throws {
        if FileManager.default.fileExists(atPath: journalURL.path) { try FileManager.default.removeItem(at: journalURL) }
        journal = nil; pendingTarget = nil; restorationPending = false; recoveryRequired = false
    }
}
