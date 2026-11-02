import Foundation
import Darwin

/// Separate signed executable role owns the two-second timer; it never renews the app lease.
public actor ClosedLidGuardian {
    private let backend: any ClamshellBackend
    private let journal: ClosedLidJournal
    private let clock: @Sendable () -> Double
    private let bootID: @Sendable () -> String
    private let instanceID = UUID()
    public init(backend: any ClamshellBackend, journal: ClosedLidJournal,
                clock: @escaping @Sendable () -> Double, bootID: @escaping @Sendable () -> String) {
        self.backend = backend; self.journal = journal; self.clock = clock; self.bootID = bootID
    }
    @discardableResult public func tick(startup: Bool = false, activeUserID: UInt32? = nil) async throws -> ClosedLidState {
        let now = clock(); guard now.isFinite else { throw ClosedLidFailure.unavailable }
        try journal.writePulse(.init(bootID: bootID(), receivedAt: now, processID: getpid(), instanceID: instanceID))
        return try await ClosedLidRecovery.run(backend: backend, journal: journal, clock: clock, bootID: bootID,
            activeUserID: activeUserID, reason: startup ? "Guardian/controller restart; previous authority revoked" : nil)
    }
}

/// The writer flock is held over observation and the asynchronous transport call. Metadata
/// revocation remains possible, but another process cannot clear and then race a late apply.
enum ClosedLidRecovery {
    static func freshWitness(_ observation: ClamshellObservation, now: Double, boot: String) -> ClamshellBaselineWitness? {
        guard now.isFinite, observation.bootID == boot, observation.sampledAt.isFinite,
              observation.sampledAt <= now, now - observation.sampledAt <= ClosedLidLimits.witnessMaximumAge,
              let witness = observation.witness, witness.bootID == boot, witness.contextID == observation.contextID,
              witness.sleepAllowed, witness.notificationBits & 2 != 0, witness.notificationBits <= 3,
              witness.sequence > 0, witness.receivedAt.isFinite, witness.receivedAt >= 0,
              witness.source == "IOPM native clamshell-state notification", witness.receivedAt <= now, now - witness.receivedAt <= ClosedLidLimits.witnessMaximumAge,
              !witness.source.isEmpty, witness.source.utf8.count <= 256 else { return nil }
        return witness
    }
    static func revoke(_ record: inout ClosedLidRecord, epoch: inout UUID, reason: String) {
        if !record.revoked { epoch = UUID() }
        record.revoked = true; record.state.recoveryRequired = record.needsRecovery
        record.state.reason = reason
    }
    static func retireIfOldBoot(_ journal: ClosedLidJournal, boot: String) throws -> ClosedLidState? {
        try journal.transaction { record, epoch in
            guard var current = record, current.bootID != boot else { return nil }
            revoke(&current, epoch: &epoch, reason: "Previous boot retired; volatile old-kernel state is not replayed")
            current.state.phase = .retiredAfterBoot; current.state.recoveryRequired = false
            record = current; return current.state
        }
    }
    static func run(backend: any ClamshellBackend, journal: ClosedLidJournal,
                    clock: @Sendable () -> Double, bootID: @Sendable () -> String,
                    activeUserID: UInt32?, reason: String? = nil,
                    heldOperation: ClosedLidOperationLock? = nil) async throws -> ClosedLidState {
        let boot = bootID(); let now = clock()
        guard now.isFinite else { throw ClosedLidFailure.unavailable }
        if let retired = try retireIfOldBoot(journal, boot: boot) { return retired }
        let snapshot = try journal.transaction { record, epoch -> ClosedLidRecord? in
            guard var current = record else { return nil }
            guard current.needsRecovery else {
                if let reason { revoke(&current, epoch: &epoch, reason: reason); record = current }
                return record
            }
            let expired = now >= (current.state.leaseDeadline ?? 0) || now >= (current.state.sessionDeadline ?? 0)
            let dead = current.controllerPID <= 0 || kill(current.controllerPID, 0) != 0
            if reason != nil || expired || dead || current.authorityEpoch != epoch || current.revoked {
                revoke(&current, epoch: &epoch, reason: reason ?? (dead ? "Controller process exited" : "Lease/deadline expired or authority revoked"))
                if current.state.phase != .restoreAcceptedAwaitingWitness && current.state.phase != .conflict {
                    current.state.phase = .restorationRequired
                }
                current.state.recoveryRequired = true; record = current
            }
            return record
        }
        guard let snapshot, snapshot.needsRecovery || snapshot.needsNormalSleepDecision else { return snapshot?.state ?? .init() }
        let shouldRestore = snapshot.revoked || snapshot.state.phase == .restorationRequired || snapshot.state.phase == .restoreAcceptedAwaitingWitness
        // Observe even a live session to detect session/power/display conflicts.
        let operation: ClosedLidOperationLock
        do { operation = try heldOperation ?? journal.acquireOperation() }
        catch ClosedLidFailure.locked { return try journal.load()?.state ?? .init() }
        return try await withExtendedLifetimeAsync(operation) {
            let observation: ClamshellObservation
            do { observation = try await backend.observe() }
            catch {
                return try journal.transaction { record, epoch in
                    guard var current = record else { return ClosedLidState() }
                    revoke(&current, epoch: &epoch, reason: "Observation unavailable; recovery retained")
                    if current.state.phase != .restoreAcceptedAwaitingWitness { current.state.phase = .restorationRequired }
                    current.state.recoveryRequired = true
                    if current.needsNormalSleepDecision { current.state.normalSleepRequestAttempted = false }
                    record = current; return current.state
                }
            }
            if bootID() != boot { return try retireIfOldBoot(journal, boot: bootID()) ?? ClosedLidState() }
            let current = try journal.transaction { record, epoch -> ClosedLidRecord? in
                guard var current = record, current.needsRecovery || current.needsNormalSleepDecision else { return record }
                current.state.observation = observation
                guard observation.sampledAt.isFinite, observation.sampledAt <= clock(),
                      clock() - observation.sampledAt <= ClosedLidLimits.witnessMaximumAge else {
                    revoke(&current, epoch: &epoch, reason: "Stale observer context; recovery retained without a write")
                    if current.state.phase != .restoreAcceptedAwaitingWitness { current.state.phase = .restorationRequired }
                    current.state.recoveryRequired = true
                    if current.needsNormalSleepDecision { current.state.normalSleepRequestAttempted = false }
                    record = current; return current
                }
                let conflict = observation.bootID != boot || observation.contextID != current.baseline?.contextID
                    || observation.activeUserID != current.peer.userID
                    || (activeUserID != nil && activeUserID != current.peer.userID)
                    || observation.externalDisplayPresent != false
                if conflict {
                    revoke(&current, epoch: &epoch, reason: "User, boot, display or observer context changed; shared-bit ownership revoked")
                    if current.state.phase != .restoreAcceptedAwaitingWitness { current.state.phase = .conflict }
                    current.state.recoveryRequired = true
                    if current.needsNormalSleepDecision { current.state.normalSleepRequestAttempted = false }
                    record = current; return current
                }
                if let issued = current.restoreIssuedAt,
                   let witness = freshWitness(observation, now: clock(), boot: boot),
                   witness.receivedAt > max(issued, current.restoreReceipt?.acceptedAt ?? issued),
                   // Per-process counters cannot be ordered across observer instances.
                   (witness.observerID != current.restoreBoundaryObserverID
                    || witness.sequence > (current.restoreBoundarySequence ?? 0)),
                   current.state.phase == .restoreAcceptedAwaitingWitness {
                    current.state.phase = .restored; current.state.recoveryRequired = false
                    current.state.reason = "Fresh native sleep-allowed witness confirms Powerd bit clear; exact mask readback remains unavailable"
                    record = current; return current
                }
                record = current; return current
            }
            guard var current else { return ClosedLidState() }
            if current.state.restoreCommandAccepted {
                return try await normalSleepIfNeeded(backend: backend, journal: journal, clock: clock,
                    bootID: bootID, activeUserID: activeUserID, sessionID: current.state.sessionID)
            }
            guard current.needsRecovery else { return current.state }
            guard observation.sampledAt.isFinite, observation.sampledAt <= clock(),
                  clock() - observation.sampledAt <= ClosedLidLimits.witnessMaximumAge,
                  current.state.phase != .conflict, current.state.phase != .restoreAcceptedAwaitingWitness,
                  shouldRestore || current.revoked else { return current.state }
            guard current.restoreAttempts < 3 else { return current.state }
            // Intent is an at-most-once barrier. A crash after this save has an unknown
            // outcome and waits for a NEW true witness, rather than blindly clearing again.
            current = try journal.transaction { record, epoch in
                guard var latest = record, latest.state.sessionID == current.state.sessionID,
                      latest.bootID == boot, latest.state.phase != .restoreAcceptedAwaitingWitness,
                      latest.state.phase != .conflict, latest.restoreAttempts < 3 else { throw ClosedLidFailure.recoveryRequired }
                revoke(&latest, epoch: &epoch, reason: "Restore issued; result pending, do not repeat an ambiguous/accepted clear")
                latest.restoreAttempts += 1; latest.restoreIssuedAt = clock()
                let boundary = observation.witness ?? latest.baseline
                latest.restoreBoundarySequence = boundary?.sequence
                latest.restoreBoundaryObserverID = boundary?.observerID
                latest.state.phase = .restoreAcceptedAwaitingWitness; latest.state.restoreCommandAccepted = false
                latest.state.recoveryRequired = true; record = latest; return latest
            }
            do {
                let receipt = try await backend.setLidSleepDisabled(false)
                guard !receipt.disabled, receipt.acceptedAt.isFinite else { throw ClosedLidFailure.malformed }
                _ = try journal.transaction { record, _ in
                    guard var latest = record, latest.state.sessionID == current.state.sessionID,
                          latest.state.phase == .restoreAcceptedAwaitingWitness else { throw ClosedLidFailure.recoveryRequired }
                    latest.restoreReceipt = receipt; latest.state.restoreCommandAccepted = true
                    latest.state.reason = "Restore command accepted; awaiting a new fresh native sleep-allowed witness"
                    record = latest; return latest.state
                }
                return try await normalSleepIfNeeded(backend: backend, journal: journal, clock: clock,
                    bootID: bootID, activeUserID: activeUserID, sessionID: current.state.sessionID)
            } catch {
                // A journal failure AFTER an accepted clear must retain the intent barrier.
                // Only an explicit commandRejected denotes a known rejected transport call.
                guard (error as? ClosedLidFailure) == .commandRejected else { throw error }
                return try journal.transaction { record, _ in
                    guard var latest = record, latest.state.sessionID == current.state.sessionID else { throw ClosedLidFailure.recoveryRequired }
                    latest.state.phase = .restorationRequired; latest.state.reason = "Restore command rejected; bounded retry remains pending"
                    record = latest; return latest.state
                }
            }
        }
    }
    /// Caller holds the writer flock. False means a durable decision to omit the
    /// terminal request; true is the at-most-once intent, including unknown outcomes.
    private static func normalSleepIfNeeded(backend: any ClamshellBackend, journal: ClosedLidJournal,
        clock: @Sendable () -> Double, bootID: @Sendable () -> String,
        activeUserID: UInt32?, sessionID: UUID?) async throws -> ClosedLidState {
        guard let before = try journal.load(), before.state.sessionID == sessionID,
              before.needsNormalSleepDecision else { return try journal.load()?.state ?? .init() }
        let observation = try? await backend.observe()
        let boot = bootID(); let now = clock()
        if before.bootID != boot { return try retireIfOldBoot(journal, boot: boot) ?? ClosedLidState() }
        let shouldRequest = try journal.transaction { record, _ -> Bool in
            guard var latest = record, latest.state.sessionID == sessionID,
                  latest.needsNormalSleepDecision else { return false }
            let safe = observation.map {
                now.isFinite && $0.sampledAt.isFinite && $0.sampledAt <= now
                    && now - $0.sampledAt <= ClosedLidLimits.witnessMaximumAge
                    && $0.bootID == boot && latest.bootID == boot
                    && $0.contextID == latest.baseline?.contextID
                    && $0.activeUserID == latest.peer.userID
                    && (activeUserID == nil || activeUserID == latest.peer.userID)
                    && $0.externalDisplayPresent == false && $0.lidClosed == true
            } ?? false
            latest.state.normalSleepRequestAttempted = safe
            latest.state.normalSleepRequestAccepted = nil
            if let observation { latest.state.observation = observation }
            if safe {
                latest.normalSleepIssuedAt = now
                latest.state.reason = "Clear accepted; normal Sleep intent durable, result pending; physical sleep unverified"
            } else {
                latest.state.reason = "Clear accepted; normal Sleep omitted because a fresh closed-lid context was not established"
            }
            record = latest; return safe
        }
        guard shouldRequest else { return try journal.load()?.state ?? .init() }
        let accepted: Bool?
        let failure: ClosedLidFailure?
        do { accepted = try await backend.requestNormalSleep(); failure = nil }
        catch { accepted = nil; failure = error as? ClosedLidFailure ?? .unavailable }
        return try journal.transaction { record, _ in
            guard var latest = record, latest.state.sessionID == sessionID,
                  latest.state.normalSleepRequestAttempted == true else { throw ClosedLidFailure.recoveryRequired }
            latest.state.normalSleepRequestAccepted = accepted; latest.normalSleepFailure = failure
            latest.state.reason = accepted == true
                ? "Clear and normal Sleep commands accepted; awaiting restore witness, physical sleep unverified"
                : "Clear accepted; normal Sleep result rejected/unavailable and will not be retried; physical sleep unverified"
            record = latest; return latest.state
        }
    }
}

/// Swift's synchronous withExtendedLifetime cannot enclose an async transport suspension.
private func withExtendedLifetimeAsync<T>(_ lock: ClosedLidOperationLock, operation: () async throws -> T) async rethrows -> T {
    defer { withExtendedLifetime(lock) {} }
    return try await operation()
}
