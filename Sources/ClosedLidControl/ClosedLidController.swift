// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation

/// Narrow lid-only request service. Authenticated peers are supplied by the XPC trust boundary;
/// tokens, exact peer binding, generations and authority are independently checked here.
public actor ClosedLidController: ClosedLidRequestServing {
    private let backend: any ClamshellBackend
    private let journal: ClosedLidJournal
    private let clock: @Sendable () -> Double
    private let bootID: @Sendable () -> String
    private let maximumSessionSeconds: Int
    private let controllerID = UUID()
    private var credentials: (peer: ClosedLidPeer, token: UUID, epoch: UUID)?
    private var pendingOperation: UUID?
    public init(backend: any ClamshellBackend, journal: ClosedLidJournal,
                clock: @escaping @Sendable () -> Double, bootID: @escaping @Sendable () -> String,
                maximumSessionSeconds: Int = ClosedLidLimits.maximumSessionSeconds) {
        self.backend = backend; self.journal = journal; self.clock = clock; self.bootID = bootID
        self.maximumSessionSeconds = maximumSessionSeconds
    }
    public func recoverAtStartup(activeUserID: UInt32? = nil) async throws -> ClosedLidState {
        credentials = nil; pendingOperation = nil
        return try await ClosedLidRecovery.run(backend: backend, journal: journal, clock: clock, bootID: bootID,
            activeUserID: activeUserID, reason: "Controller restart; previous app authority revoked")
    }
    public func currentState() async throws -> ClosedLidState { try journal.load()?.state ?? .init() }
    private func reply(_ failure: ClosedLidFailure? = nil) throws -> ClosedLidReply {
        let record = try journal.load()
        return .init(accepted: failure == nil, sessionToken: [.wrongUser, .wrongSession, .malformed].contains(failure) ? nil : credentials?.token,
                     generation: record?.state.generation ?? 0, state: record?.state ?? .init(), failure: failure)
    }
    public func openSession(peer: ClosedLidPeer, activeUserID: UInt32?) async throws -> ClosedLidReply {
        guard activeUserID == peer.userID, peer.userID != 0 else { return try reply(.wrongUser) }
        guard pendingOperation == nil else {
            var denied = try reply(.busy); denied.sessionToken = nil; return denied
        }
        _ = try ClosedLidRecovery.retireIfOldBoot(journal, boot: bootID())
        let token = UUID(); let epoch = UUID()
        do {
            try journal.transaction { record, authority in
                if let record, record.needsRecovery { throw ClosedLidFailure.recoveryRequired }
                var next = ClosedLidRecord(bootID: bootID(), authorityEpoch: epoch, controllerID: controllerID,
                                           peer: peer, sessionToken: token)
                next.state.generation = (record?.state.generation ?? 0) + 1
                next.state.ownerUserID = peer.userID
                authority = epoch; record = next
            }
        } catch let failure as ClosedLidFailure where failure == .recoveryRequired {
            var denied = try reply(failure); denied.sessionToken = nil; return denied
        }
        credentials = (peer, token, epoch)
        return try reply()
    }
    public func perform(_ envelope: ClosedLidEnvelope, peer: ClosedLidPeer, activeUserID: UInt32?) async throws -> ClosedLidReply {
        guard envelope.version == ClosedLidLimits.protocolVersion,
              let encoded = try? JSONEncoder().encode(envelope), encoded.count <= ClosedLidLimits.maximumPayloadBytes else { return try reply(.malformed) }
        guard activeUserID == peer.userID, peer.userID != 0 else { return try reply(.wrongUser) }
        guard let credential = credentials, credential.peer == peer, credential.token == envelope.sessionToken else { return try reply(.wrongSession) }
        let record: ClosedLidRecord
        do {
            record = try journal.transaction { stored, epoch in
                guard let current = stored, current.authorityEpoch == credential.epoch,
                      current.controllerID == controllerID else { throw ClosedLidFailure.staleGeneration }
                let recoveryOnly: Bool
                switch envelope.command { case .readState: recoveryOnly = true; case .stop, .recover: recoveryOnly = current.needsRecovery; default: recoveryOnly = false }
                guard recoveryOnly || (current.authorityEpoch == epoch && !current.revoked) else { throw ClosedLidFailure.staleGeneration }
                guard current.peer == peer, current.sessionToken == envelope.sessionToken else { throw ClosedLidFailure.wrongSession }
                guard !current.requestIDs.contains(envelope.requestID) else { throw ClosedLidFailure.replay }
                guard current.state.generation < UInt64.max - 1, current.state.generation + 1 == envelope.generation else { throw ClosedLidFailure.staleGeneration }
                return current
            }
        } catch let failure as ClosedLidFailure { return try reply(failure) }
        guard record.bootID == bootID() else {
            credentials = nil; _ = try ClosedLidRecovery.retireIfOldBoot(journal, boot: bootID()); return try reply(.expired)
        }
        if case .start(let seconds) = envelope.command {
            guard (1...ClosedLidLimits.maximumSessionSeconds).contains(maximumSessionSeconds),
                  seconds > 0, seconds <= maximumSessionSeconds else { return try reply(.malformed) }
        }
        if case .readState = envelope.command {
            try remember(envelope, credential: credential)
            return try reply()
        }
        if case .start = envelope.command {
            guard pendingOperation == nil else { return try reply(.busy) }
            guard !record.needsRecovery else { return try reply(.recoveryRequired) }
            return try await start(envelope, credential: credential)
        }
        let sessionID: UUID
        switch envelope.command {
        case .heartbeat(let id), .stop(let id), .recover(let id): sessionID = id
        default: return try reply(.malformed)
        }
        guard sessionID == record.state.sessionID else { return try reply(.wrongSession) }
        switch envelope.command {
        case .stop, .recover:
            // Revoke even during an in-flight apply. Its completion is responsible for
            // clearing while still holding the writer lock, so a late apply cannot escape.
            try remember(envelope, credential: credential)
            pendingOperation = nil
            try journal.transaction { stored, epoch in
                guard var current = stored else { throw ClosedLidFailure.recoveryRequired }
                ClosedLidRecovery.revoke(&current, epoch: &epoch, reason: "Owner requested stop/recovery")
                if current.state.phase != .restoreAcceptedAwaitingWitness && current.state.phase != .conflict { current.state.phase = .restorationRequired }
                current.state.recoveryRequired = true; stored = current
            }
            let state = try await ClosedLidRecovery.run(backend: backend, journal: journal, clock: clock, bootID: bootID,
                activeUserID: activeUserID, reason: "Owner requested stop/recovery")
            return .init(accepted: state.restoreCommandAccepted || state.phase == .restored,
                         sessionToken: credential.token, generation: state.generation, state: state,
                         failure: state.phase == .restorationRequired ? .commandRejected : nil)
        case .heartbeat:
            guard pendingOperation == nil else { return try reply(.busy) }
            guard clock().isFinite, clock() < (record.state.leaseDeadline ?? 0), clock() < (record.state.sessionDeadline ?? 0) else {
                _ = try await ClosedLidRecovery.run(backend: backend, journal: journal, clock: clock, bootID: bootID,
                    activeUserID: activeUserID, reason: "Expired heartbeat cannot renew ownership")
                return try reply(.expired)
            }
            let operation = UUID(); pendingOperation = operation
            defer { if pendingOperation == operation { pendingOperation = nil } }
            let observation = try await backend.observe()
            guard pendingOperation == operation else { return try reply(.staleGeneration) }
            guard observation.bootID == record.bootID, observation.contextID == record.baseline?.contextID,
                  observation.activeUserID == peer.userID, observation.externalDisplayPresent == false else {
                _ = try await ClosedLidRecovery.run(backend: backend, journal: journal, clock: clock, bootID: bootID,
                    activeUserID: activeUserID, reason: "Heartbeat observer context conflict")
                return try reply(.contextConflict)
            }
            do {
                try remember(envelope, credential: credential)
                try journal.transaction { stored, epoch in
                    guard var current = stored, current.authorityEpoch == epoch, !current.revoked,
                          clock() < (current.state.leaseDeadline ?? 0), clock() < (current.state.sessionDeadline ?? 0) else { throw ClosedLidFailure.expired }
                    current.state.leaseDeadline = min(clock() + ClosedLidLimits.leaseSeconds, current.state.sessionDeadline!)
                    current.state.observation = observation; stored = current
                }
            } catch let failure as ClosedLidFailure { return try reply(failure) }
            return try reply()
        default: return try reply(.malformed)
        }
    }
    private func remember(_ envelope: ClosedLidEnvelope,
                          credential: (peer: ClosedLidPeer, token: UUID, epoch: UUID)) throws {
        try journal.transaction { record, epoch in
            guard var current = record, current.authorityEpoch == credential.epoch,
                  current.peer == credential.peer, current.sessionToken == credential.token,
                  current.state.generation < UInt64.max - 1, current.state.generation + 1 == envelope.generation else { throw ClosedLidFailure.staleGeneration }
            let recoveryOnly: Bool
            switch envelope.command { case .readState: recoveryOnly = true; case .stop, .recover: recoveryOnly = current.needsRecovery; default: recoveryOnly = false }
            guard recoveryOnly || (current.authorityEpoch == epoch && !current.revoked) else { throw ClosedLidFailure.staleGeneration }
            guard !current.requestIDs.contains(envelope.requestID) else { throw ClosedLidFailure.replay }
            // Every admitted envelope consumes its strictly increasing generation. Old
            // envelopes remain stale even after their UUID leaves this bounded cache.
            current.requestIDs.append(envelope.requestID)
            if current.requestIDs.count > 128 { current.requestIDs.removeFirst() }
            current.state.generation = envelope.generation
            record = current
        }
    }
    private func start(_ envelope: ClosedLidEnvelope,
                       credential: (peer: ClosedLidPeer, token: UUID, epoch: UUID)) async throws -> ClosedLidReply {
        let operationID = UUID(); pendingOperation = operationID
        defer { if pendingOperation == operationID { pendingOperation = nil } }
        let observation: ClamshellObservation
        do { observation = try await backend.observe() }
        catch { return try reply(.unavailable) }
        guard pendingOperation == operationID, credentials?.epoch == credential.epoch else { return try reply(.staleGeneration) }
        let now = clock(); let boot = bootID()
        guard let witness = ClosedLidRecovery.freshWitness(observation, now: now, boot: boot) else { return try reply(.baselineWitnessRequired) }
        guard observation.activeUserID == credential.peer.userID, observation.externalDisplayPresent == false,
              observation.lidClosed == false else { return try reply(.contextConflict) }
        guard try journal.guardianReady(bootID: boot, now: now) else { return try reply(.guardianUnavailable) }
        let writer: ClosedLidOperationLock
        do { writer = try journal.acquireOperation() } catch let failure as ClosedLidFailure { return try reply(failure) }
        defer { withExtendedLifetime(writer) {} }
        do {
            try remember(envelope, credential: credential)
            try journal.transaction { stored, epoch in
                guard var record = stored, record.authorityEpoch == epoch, epoch == credential.epoch,
                      !record.revoked, !record.needsRecovery, pendingOperation == operationID else { throw ClosedLidFailure.staleGeneration }
                guard case .start(let seconds) = envelope.command else { throw ClosedLidFailure.malformed }
                record.baseline = witness; record.state.sessionID = UUID()
                record.state.phase = .prepared; record.state.ownerUserID = credential.peer.userID
                record.state.sessionDeadline = now + Double(seconds)
                record.state.leaseDeadline = min(now + ClosedLidLimits.leaseSeconds, now + Double(seconds))
                record.state.observation = observation; record.state.recoveryRequired = true
                record.state.reason = "Prepared original Powerd bit zero from fresh native witness; command pending"
                record.applyReceipt = nil; record.restoreReceipt = nil; record.restoreAttempts = 0
                record.restoreIssuedAt = nil; record.restoreBoundarySequence = nil; record.restoreBoundaryObserverID = nil
                record.state.applicationAccepted = false; record.state.restoreCommandAccepted = false
                record.state.normalSleepRequestAttempted = nil; record.state.normalSleepRequestAccepted = nil
                record.normalSleepIssuedAt = nil; record.normalSleepFailure = nil
                stored = record
            }
        } catch let failure as ClosedLidFailure { return try reply(failure) }
        // No await occurs between durable preparation and invoking the fixed setter.
        let receipt: ClamshellCommandReceipt
        do { receipt = try await backend.setLidSleepDisabled(true) }
        catch {
            _ = try await ClosedLidRecovery.run(backend: backend, journal: journal, clock: clock, bootID: bootID,
                activeUserID: credential.peer.userID, reason: "Apply failed or outcome unknown; restore original bit zero", heldOperation: writer)
            return try reply(.commandRejected)
        }
        guard receipt.disabled, receipt.acceptedAt.isFinite else {
            _ = try await ClosedLidRecovery.run(backend: backend, journal: journal, clock: clock, bootID: bootID,
                activeUserID: credential.peer.userID, reason: "Malformed apply receipt; recover conservatively", heldOperation: writer)
            return try reply(.commandRejected)
        }
        let stillAuthorized = try journal.transaction { stored, epoch in
            guard var current = stored else { throw ClosedLidFailure.recoveryRequired }
            guard current.authorityEpoch == epoch, epoch == credential.epoch, !current.revoked,
                  pendingOperation == operationID, clock() < (current.state.leaseDeadline ?? 0),
                  clock() < (current.state.sessionDeadline ?? 0), bootID() == current.bootID else { return false }
            current.applyReceipt = receipt; current.state.phase = .commandAccepted
            current.state.applicationAccepted = true; current.state.reason = "Lid command accepted; configuration and physical behavior unverified"
            stored = current; return true
        }
        guard stillAuthorized else {
            _ = try await ClosedLidRecovery.run(backend: backend, journal: journal, clock: clock, bootID: bootID,
                activeUserID: credential.peer.userID, reason: "Late apply completion after revocation/expiry; restoring", heldOperation: writer)
            return try reply(.staleGeneration)
        }
        return try reply()
    }
    public func disconnect(peer: ClosedLidPeer) async {
        guard credentials?.peer == peer else { return }
        credentials = nil; pendingOperation = nil
        do {
            try journal.transaction { record, epoch in
                guard var current = record, current.peer == peer, current.controllerID == controllerID else { return }
                ClosedLidRecovery.revoke(&current, epoch: &epoch, reason: "Authenticated app connection disconnected")
                if current.needsRecovery && current.state.phase != .restoreAcceptedAwaitingWitness && current.state.phase != .conflict { current.state.phase = .restorationRequired }
                record = current
            }
            _ = try await ClosedLidRecovery.run(backend: backend, journal: journal, clock: clock, bootID: bootID,
                activeUserID: peer.userID, reason: "App disconnected")
        } catch {
            // Durable preparation and the independent guardian remain the recovery authority.
            // No fallback clear is issued when secure storage is unavailable.
        }
    }
}
