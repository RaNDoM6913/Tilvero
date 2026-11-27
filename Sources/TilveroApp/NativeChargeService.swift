// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import Combine
import ChargeBackends
import PowerCore

/// The write-ahead record of one native write. It only says "a write was dispatched and its outcome is not confirmed
/// yet": nothing is owed to its baseline, nothing is ever written from it, and it closes itself (see `closesSession`).
struct NativeChargeJournal: Codable, Sendable {
    /// Every phase earlier builds wrote still decodes; whatever the phase, a reopened journal is an unresolved session.
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
    /// Always false. Still written so an earlier build can decode the file (its decoder requires the key).
    var oneShot = false
    var semanticContract: String?
    var persistentTargets: [Int]?
    var baselineSnapshot: NativeChargeSnapshot?
    /// Decoded for compatibility (true: an earlier build's validation run, false: a user apply, nil: before 0.8.2).
    /// Nothing branches on it any more.
    var qualification: Bool?

    func hasPersistentScope(environment: String) -> Bool {
        guard version == 2, NativeChargeAdmission.sameMachine(self.environment, environment),
              semanticContract == NativeChargeAdmission.semanticContract,
              persistentTargets == NativeChargeAdmission.persistentTargets,
              let baselineSnapshot, baselineSnapshot.configuration == baseline,
              NativeChargeAdmission.persistentTargets.contains(baseline.target),
              // A journal written from a two-row AC read must still load (nothing is ever written from it).
              NativeChargeAdmission.isValidState(baseline), NativeChargeAdmission.validOfferedTargets(baselineSnapshot.supportedTargets),
              NativeChargeAdmission.isValidState(lastVerified),
              plannedTarget.map(NativeChargeAdmission.persistentTargets.contains) ?? true,
              expectedMutation.map(NativeChargeAdmission.isValidState) ?? true else { return false }
        return true
    }
}

extension NativeChargeSnapshot {
    func isFresh(at date: Date) -> Bool {
        let age = date.timeIntervalSince(collectedAt)
        return age >= -5 && age <= 65
    }
}

struct NativeChargePresentation {
    enum Attention: Equatable {
        /// Nothing to say.
        case none
        /// A write's outcome is not confirmed yet (or an unusable session file is on disk): a status line only; it blocks
        /// nothing and closes itself.
        case mutationUnresolved
        /// A session file could not be saved or removed safely: the only state Diagnostics flags globally.
        case journalIntegrity
        /// A native call is running (the spinner) or has passed its deadline (then a line, in orange).
        case operationPending
        /// The registry has not confirmed the stored setting (a two-row conflict, a missing readback, a stale read).
        case policyUnconfirmed
    }
    let currentPreference: NativeChargeConfiguration?
    let activePolicy: NativeChargeConfiguration?
    let pendingPurpose: NativeChargeOperationGate.Purpose?
    /// The pending operation has passed its deadline (its XPC call has not returned yet): only then does it get a line.
    var pendingTimedOut = false
    let attention: Attention
    let hasRecordedMutation: Bool
    /// Only a session file that could not be handled safely is worth a banner and the Diagnostics dot.
    var requiresGlobalAttention: Bool { attention == .journalIntegrity }
    var showsAttentionBanner: Bool { requiresGlobalAttention }
}

enum NativeChargeServiceError: Error, LocalizedError {
    case unavailable, busy, unsupportedTarget, unqualifiedTarget, readbackMismatch
    /// The limit read just before the write was not the one the caller expected (System Settings changed it): nothing written.
    case changedElsewhere
    var errorDescription: String? {
        switch self {
        case .unavailable: "macOS has not reported the charge limit yet. Nothing was changed."
        case .busy: "A native charging operation is still in progress."
        case .unsupportedTarget: "Choose a charge target offered by this Mac."
        case .unqualifiedTarget: "This charge limit is not offered by macOS on this Mac."
        case .readbackMismatch: "macOS reported an unclear charge limit, so nothing new was confirmed. Try again in a moment."
        case .changedElsewhere: "The charge limit was changed in System Settings. Nothing was written."
        }
    }
}

/// The native macOS charge limit over the normal-user Apple client, exactly as System Settings sets it. It never registers
/// a helper, changes OBC, writes at quit, or fights a change made elsewhere.
/// One write path: a fresh read, a write-ahead journal, one setMCLLimit inside the operation gate, a bounded readback,
/// then the journal goes (a confirmed limit is the user's own setting). An unconfirmed write leaves the journal, which
/// blocks nothing and closes at the first settled clear read; nothing is ever written from it.
@MainActor final class NativeChargeService: ObservableObject {
    /// The last read whose policy matched (or the readback of a write); presentation confirms it only while it matches.
    @Published private(set) var observed: NativeChargeSnapshot?
    /// Every successful fresh read lands here (`readNative`), whether or not the registry agrees: what macOS stores.
    @Published private(set) var nativeSetting: NativeChargeSnapshot?
    @Published private(set) var incompleteObservation: NativeChargeReadFailure?
    var currentReportedTarget: Int? {
        if let setting = nativeSetting, setting.isFresh { return setting.configuration.target }
        guard let incompleteObservation, incompleteObservation.isFresh(at: Date()) else { return nil }
        return incompleteObservation.currentTarget
    }
    /// The limit macOS reports right now from a fresh stored setting (100 when the limit is off), nil when unknown.
    var reportedLimit: Int? {
        guard let setting = nativeSetting, setting.isFresh else { return nil }
        return Self.limit(setting.configuration)
    }
    /// The limit a configuration means: an enabled target, or 100 when the limit is off.
    static func limit(_ configuration: NativeChargeConfiguration) -> Int {
        configuration.enabled ? configuration.target : NativeChargeAdmission.unlimitedTarget
    }
    /// Reader age can be checked; the diagnostic source's own freshness is unknown.
    var diagnosticStoredTarget: Int? {
        guard let incompleteObservation, incompleteObservation.isFresh(at: Date()) else { return nil }
        return incompleteObservation.diagnosticStoredTarget
    }
    /// Nothing has been read from macOS yet: surfaces stay quiet (no explanation flashes at launch).
    var notReadYet: Bool { nativeSetting == nil }
    private var knownTargets: [Int] = []
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    /// The live interface granted the limit (`NativeChargeAdmission.grants`): set once, by the first such read.
    @Published private(set) var admitted = false
    private let client: any NativeChargeTransport
    private let operationGate: NativeChargeOperationGate
    private let journalURL: URL
    private let monitoringOnly: Bool
    private let verificationAttempts: Int
    private let verificationDelay: Duration
    private let operationTimeout: Duration
    private let environment: String
    private var journal: NativeChargeJournal?
    /// A session file that cannot be used (unreadable, v1, another contract or Mac). It is never acted on: kept in place
    /// until a settled clear read or the next apply, then set aside under a new name with its bytes intact.
    @Published private(set) var unreadableJournal = false
    /// A write whose outcome is unknown (or an unusable session file) is on disk. It blocks nothing and closes itself.
    var hasUnresolvedSession: Bool { journal != nil || unreadableJournal }
    /// The session journal on disk, if any: a caller that compares it before and after an apply knows whether that apply
    /// left a write of its own whose outcome is unknown (a new session) or wrote nothing (the same one, or none).
    var unresolvedSessionID: UUID? { journal?.sessionID }
    /// A gated native call has not returned yet (it may be past its deadline): nothing should be decided from the last
    /// reading while it runs.
    var operationPending: Bool { operationGate.pending }
    /// The session journal this service loads and closes itself (the update probe leaves it to `hasUnresolvedSession`).
    /// Nil while monitoring: such a service never loads its journal, so the probe stays its only guard.
    var ownJournalURL: URL? { monitoringOnly ? nil : journalURL }
    /// The background refresh's own read: it never counts as a pending operation in the presentation (no flicker).
    private var isRefreshing = false
    /// Applies waiting for that read to end: a poll that starts just before a write never drops it.
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    /// The text of the last failed background read: a later successful read makes it untrue, so it clears it.
    private var readFailureMessage: String?
    /// The longest a native apply can take (gate deadline plus the readback budget), for the model's waits.
    var maximumOperationDuration: Duration { operationTimeout + verificationDelay * verificationAttempts + .seconds(2) }
    /// `.mutationUnresolved` while a session is on disk, `.journalIntegrity` when one could not be handled safely.
    private var reviewReason: NativeChargePresentation.Attention?

    /// What this one apply dispatched; provenance never comes from a reopened journal.
    private final class Transaction {
        var sessionID: UUID?
        var everDispatched = false
        var dispatchedAt: Date?
        var confirmed = false
    }

    func presentation(at date: Date = Date()) -> NativeChargePresentation {
        let preference = nativeSetting.flatMap { $0.isFresh(at: date) ? $0.configuration : nil }
        // The background refresh's own read keeps the last reading and the state it showed: no status line or height
        // change on every poll. Writes, the reads inside an apply and a read past its deadline still count. The very
        // first read (nothing known yet) still shows its progress.
        let backgroundRead = isRefreshing && operationGate.pendingPurpose == .read && !operationGate.timedOut
            && (nativeSetting != nil || observed != nil || incompleteObservation != nil)
        let policy = observed.flatMap { $0.isFresh(at: date) && $0.policyMatches
            && (!operationGate.pending || backgroundRead) ? $0.configuration : nil }
        let attention: NativeChargePresentation.Attention
        if let reviewReason { attention = reviewReason }
        else if (operationGate.pending && !backgroundRead) || (isBusy && !isRefreshing) { attention = .operationPending }
        else if policy == nil { attention = .policyUnconfirmed }
        else { attention = .none }
        return .init(currentPreference: preference, activePolicy: policy, pendingPurpose: operationGate.pendingPurpose,
                     pendingTimedOut: operationGate.pending && operationGate.timedOut, attention: attention,
                     hasRecordedMutation: journal?.expectedMutation != nil)
    }

    var isMonitoringOnly: Bool { monitoringOnly }
    /// The persistent levels macOS offers (100 is the limit off), once the live interface granted them; none while monitoring.
    var authorizedPersistentTargets: [Int] { admitted && !monitoringOnly ? NativeChargeAdmission.persistentTargets : [] }
    /// The slider works from what macOS stores (as System Settings does); the readback after a write decides.
    var isAvailable: Bool {
        guard !operationGate.pending, admitted, !monitoringOnly, let setting = nativeSetting, setting.isFresh else { return false }
        return NativeChargeAdmission.isValidState(setting.configuration) && NativeChargeAdmission.validOfferedTargets(setting.supportedTargets)
    }
    var canApply: Bool { isAvailable && !isBusy }
    func canApplyTarget(_ target: Int) -> Bool { canApply && acceptedTargets.contains(target) && authorizedPersistentTargets.contains(target) }
    /// Whether the target is on offer at all, ignoring momentary states (a read or an apply in flight, a pending operation, a
    /// lapsed freshness window). Controls take their look from this so they never blink while a limit is being applied; the
    /// tap itself is still gated by `canApplyTarget`.
    func offersTarget(_ target: Int) -> Bool {
        admitted && !monitoringOnly && acceptedTargets.contains(target) && authorizedPersistentTargets.contains(target)
    }
    /// Compares with what macOS reports (100 is "limit off").
    func needsApply(target: Int) -> Bool {
        guard canApplyTarget(target) else { return false }
        return reportedLimit.map { $0 != target } ?? true
    }
    var acceptedTargets: [Int] { knownTargets }
    var interfaceWasDiscovered: Bool { !knownTargets.isEmpty || admitted || journal != nil || unreadableJournal }

    init(client: any NativeChargeTransport, journalURL: URL, monitoringOnly: Bool = false,
         verificationAttempts: Int = 30, verificationDelay: Duration = .zero,
         environment: String = ProcessInfo.processInfo.operatingSystemVersionString,
         operationTimeout: Duration = .seconds(15)) {
        operationGate = NativeChargeOperationGate(timeout: operationTimeout)
        self.client = client; self.journalURL = journalURL; self.monitoringOnly = monitoringOnly
        self.verificationAttempts = max(1, verificationAttempts); self.verificationDelay = verificationDelay
        self.environment = environment; self.operationTimeout = operationTimeout
        if !monitoringOnly && FileManager.default.fileExists(atPath: journalURL.path) {
            do {
                let saved = try JSONDecoder().decode(NativeChargeJournal.self, from: Data(contentsOf: journalURL))
                if saved.version == 2, !saved.hasWritten {
                    // Nothing was dispatched (a waiting target, or a crash before the write-ahead): the user's macOS setting
                    // is untouched, whatever phase or macOS version wrote the journal. Nothing to review.
                    try FileManager.default.removeItem(at: journalURL)
                } else if saved.version == 2, saved.hasPersistentScope(environment: environment) {
                    // A dispatched write whose outcome is unknown, of any phase or origin. Nothing is owed to its baseline
                    // (a confirmed limit is the user's own): it blocks nothing and closes at the first settled clear read.
                    journal = saved; reviewReason = .mutationUnresolved
                } else { throw NativeChargeServiceError.unavailable }
            } catch {
                // Unreadable, v1, another contract or another Mac: never acted on, kept in place for now (set aside later).
                unreadableJournal = true; reviewReason = .mutationUnresolved
            }
        }
        operationGate.onTimeout = { [weak self] purpose in
            guard let self else { return }
            if purpose.isMutation, self.journal != nil {
                // The outcome is unknown: recorded (a status line; the session closes itself later).
                self.journal?.phase = .indeterminate
                self.reviewReason = .mutationUnresolved
                do { try self.saveJournal() } catch { self.reviewReason = .journalIntegrity }
            }
            self.observed = nil
            self.message = purpose.isMutation ? Self.writeTimeoutMessage : Self.readTimeoutMessage
        }
        operationGate.onLateCompletion = { [weak self] _ in
            // The next read (the next poll) shows what macOS stores now; that read clears this line.
            self?.objectWillChange.send()
            self?.message = Self.lateAnswerMessage
        }
    }

    convenience init(historyURL: URL, launchPolicy: AppLaunchPolicy = .current()) {
        let root = historyURL.deletingLastPathComponent()
        // A normal write reads back in one or two reads; six one-second tries bound the wait (an unconfirmed write closes
        // itself later, the slider keeps working). Files of the removed validation run stay on disk untouched.
        self.init(client: Self.liveTransport(), journalURL: root.appendingPathComponent("native-charge-session.json"),
                  monitoringOnly: launchPolicy.monitoringOnly, verificationAttempts: 6, verificationDelay: .seconds(1),
                  environment: NativeChargeAdmission.currentEnvironment)
    }

    /// The live PowerUI client only inside the shipping app bundle (as the OBC transport): a test runner or the Lab Studio
    /// gets a transport that reads and writes nothing. Explicit `client:` injection is unchanged.
    static func liveTransport() -> any NativeChargeTransport {
        #if TILVERO_LAB_STUDIO
        return UnavailableNativeChargeTransport()
        #else
        return Bundle.main.bundleURL.pathExtension == "app" ? PowerUIChargeClient() : UnavailableNativeChargeTransport()
        #endif
    }

    private func makeScopedJournal(baseline: NativeChargeSnapshot, plannedTarget: Int) -> NativeChargeJournal {
        var saved = NativeChargeJournal(sessionID: UUID(), environment: environment, baseline: baseline.configuration,
            lastVerified: baseline.configuration, plannedTarget: plannedTarget, phase: .preparing)
        saved.version = 2; saved.semanticContract = NativeChargeAdmission.semanticContract
        saved.persistentTargets = NativeChargeAdmission.persistentTargets; saved.baselineSnapshot = baseline
        saved.qualification = false
        return saved
    }

    nonisolated static let registryConflictMessage = "macOS lists two different charge limits. Set the limit once in System Settings › Battery to bring them together."
    nonisolated static let policyUnconfirmedMessage = "macOS has not confirmed the active limit yet."
    /// A write past its deadline: further writes wait only for that call to return (the gate), nothing else.
    nonisolated static let writeTimeoutMessage = "macOS did not answer in time. The limit can be changed again once it responds."
    nonisolated static let readTimeoutMessage = "The native policy read timed out. Further actions wait for the read to return."
    nonisolated static let lateAnswerMessage = "macOS answered late; Tilvero is checking the limit."
    /// A session file could not be saved or removed: the next apply (or a settled clear read) tries again.
    nonisolated static let journalIntegrityMessage = "Tilvero could not update its charge-limit record. The next change tries again."
    /// Lines about a call past its deadline: a later successful read makes them untrue, so it clears them.
    private static var deadlineMessages: Set<String> {
        [writeTimeoutMessage, readTimeoutMessage, lateAnswerMessage, NativeChargeOperationGate.Failure.timedOut.localizedDescription]
    }

    func refresh() async {
        guard !isBusy, !operationGate.pending else { return }
        isBusy = true; isRefreshing = true
        defer {
            isBusy = false; isRefreshing = false
            let waiting = readWaiters; readWaiters = []; waiting.forEach { $0.resume() }
        }
        do {
            let value = try await readNative()   // a fresh read lands in nativeSetting whether or not the registry agrees
            guard value.isFresh && value.policyMatches else {
                observed = nil
                message = value.registryConflict ? Self.registryConflictMessage : Self.policyUnconfirmedMessage
                return
            }
            observed = value
            if message == Self.registryConflictMessage || message == Self.policyUnconfirmedMessage { message = nil }
            // A session journal (any phase or origin, or an unusable file) only records that a write's outcome was unknown.
            // The first settled, clear read closes it without any write: that limit is the user's macOS setting.
            if !monitoringOnly, hasUnresolvedSession, Self.closesSession(value: value, age: journalAge()) {
                do { try closeSession(); message = nil } catch { markJournalIntegrity() }
            }
        } catch { observed = nil; message = error.localizedDescription; readFailureMessage = message }
    }

    /// The one write path, exactly what System Settings does: a fresh read, a write-ahead journal, one setMCLLimit inside
    /// the gate, a bounded readback, then the journal goes (a confirmed limit is the user's own setting). No battery
    /// reading, no validation run; a level below the charge is set at once. An unconfirmed write leaves an indeterminate
    /// journal that blocks nothing and closes itself at the first settled clear read.
    /// `expectedCurrent`: the limit the caller saw (charge-by, charge-once). A different fresh value means System Settings
    /// changed it: `changedElsewhere`, nothing written.
    func apply(_ target: Int, expectedCurrent: Int? = nil) async throws {
        guard !monitoringOnly, admitted else { throw NativeChargeServiceError.unavailable }
        // A background read in flight (the poll, the panel opening) is waited for, never a reason to refuse: it takes
        // milliseconds and the gate bounds it.
        while isRefreshing { await withCheckedContinuation { readWaiters.append($0) } }
        guard !isBusy, !operationGate.pending else { throw NativeChargeServiceError.busy }
        isBusy = true; defer { isBusy = false }
        let current = try await readNative()
        observed = current
        // The registry is not required: on AC both rows follow a write within 1 ms, so the write is what clears a conflict.
        guard current.isFresh, NativeChargeAdmission.isValidState(current.configuration),
              NativeChargeAdmission.validOfferedTargets(current.supportedTargets) else { throw NativeChargeServiceError.readbackMismatch }
        guard current.supportedTargets.contains(target) else { throw NativeChargeServiceError.unsupportedTarget }
        guard authorizedPersistentTargets.contains(target) else { throw NativeChargeServiceError.unqualifiedTarget }
        if let expectedCurrent, Self.limit(current.configuration) != expectedCurrent { throw NativeChargeServiceError.changedElsewhere }
        // A leftover (an earlier write of unknown outcome, or an unusable file) guards nothing: the operation gate has
        // returned its call, so it is superseded without a write.
        if hasUnresolvedSession { do { try closeSession() } catch { markJournalIntegrity(); throw error } }
        if Self.limit(current.configuration) == target { message = nil; return }
        let transaction = Transaction()
        journal = makeScopedJournal(baseline: current, plannedTarget: target)
        transaction.sessionID = journal?.sessionID
        do {
            try saveJournal()
            try await mutate(transaction, expected: .init(enabled: target != NativeChargeAdmission.unlimitedTarget, target: target,
                                                          optimizedCharging: current.configuration.optimizedCharging))
            // Confirmed: the user's own macOS setting. No baseline is kept to rewrite later.
            try relinquish(); message = nil
        } catch {
            handleFailure(transaction, failure: error)
            throw error
        }
    }

    /// Re-reads (a change made between the reads is the user's and wins), records the write ahead, dispatches it inside the
    /// gate and reads it back.
    private func mutate(_ transaction: Transaction, expected: NativeChargeConfiguration) async throws {
        guard let saved = journal else { throw NativeChargeServiceError.unavailable }
        let before = try await readNative(); observed = before
        guard before.isFresh, saved.hasPersistentScope(environment: environment),
              NativeChargeAdmission.validOfferedTargets(before.supportedTargets),
              NativeChargeAdmission.isValidState(before.configuration), NativeChargeAdmission.isValidState(expected)
        else { throw NativeChargeServiceError.readbackMismatch }
        guard authorizedPersistentTargets.contains(expected.target) else { throw NativeChargeServiceError.unqualifiedTarget }
        guard before.configuration.matchesManual(saved.lastVerified) else {
            // Changed in System Settings between the reads: that is the user's setting; nothing is written.
            try relinquish()
            throw NativeChargeServiceError.changedElsewhere
        }
        // Write-ahead: a crash or error cannot make a dispatched, unacknowledged write look untouched.
        journal?.expectedMutation = expected; journal?.hasWritten = true; try saveJournal()
        try await operationGate.call(purpose: .setLimit(target: expected.target),
                                     onDispatch: { transaction.everDispatched = true; transaction.dispatchedAt = Date() }) { [client] in
            try await client.setLimit(expected.target)
        }
        // The setter's return and a fresh read of the requested configuration are separate proofs.
        let after = try await confirmWrite(expected: expected)
        transaction.confirmed = true
        journal?.lastVerified = after.configuration; journal?.expectedMutation = nil
    }

    /// A bounded readback: fresh, the requested configuration, a valid state and the policy confirmed (the registry on AC,
    /// the stored setting on battery power). A failed read is retried; a hung read (gate) means the outcome is unknown.
    private func confirmWrite(expected: NativeChargeConfiguration) async throws -> NativeChargeSnapshot {
        for attempt in 0..<verificationAttempts {
            do {
                let value = try await readNative(); observed = value
                if value.isFresh, value.configuration.matchesManual(expected), NativeChargeAdmission.isValidState(value.configuration),
                   value.policyMatches {
                    return value
                }
            } catch let failure as NativeChargeOperationGate.Failure {
                throw failure
            } catch {}
            if attempt + 1 < verificationAttempts { try await Task.sleep(for: verificationDelay) }
        }
        throw NativeChargeServiceError.readbackMismatch
    }

    private func readNative() async throws -> NativeChargeSnapshot {
        do {
            let value = try await operationGate.call(purpose: .read) { [client] in try await client.read() }
            if let previous = incompleteObservation, message == previous.localizedDescription { message = nil }
            if let current = message, Self.deadlineMessages.contains(current) || current == readFailureMessage { message = nil }
            readFailureMessage = nil
            incompleteObservation = nil
            // Every successful fresh read is what macOS stores now (and grants the interface), even when its policy is not
            // confirmed (a registry conflict): the surfaces show it, confirmation is separate.
            if value.isFresh {
                nativeSetting = value
                knownTargets = value.supportedTargets
                if !monitoringOnly, !admitted, NativeChargeAdmission.grants(value) { admitted = true }
            }
            return value
        }
        catch {
            observed = nil
            incompleteObservation = nil
            if let failure = error as? NativeChargeReadFailure {
                // Discovery is independent of a usable current setting. Keep offered targets visible without inferring the
                // enabled state or permission to dispatch a setter.
                knownTargets = failure.supportedTargets
                nativeSetting = nil
                incompleteObservation = failure
                message = failure.localizedDescription
            }
            throw error
        }
    }

    private func markJournalIntegrity() {
        // A status for Diagnostics; it blocks nothing (the next apply or a settled clear read retries).
        reviewReason = .journalIntegrity; observed = nil
        message = Self.journalIntegrityMessage
    }

    /// Three outcomes: nothing dispatched (the new journal goes), dispatched and confirmed (the user's setting: the journal
    /// goes), otherwise the outcome is unknown (an indeterminate journal, a status line, closed later by a clear read).
    private func handleFailure(_ transaction: Transaction, failure: any Error) {
        // A fresh external change may already have relinquished this session. Never recreate it.
        guard journal != nil, journal?.sessionID == transaction.sessionID else { return }
        observed = nil
        if !transaction.everDispatched {
            journal = nil
            do {
                if FileManager.default.fileExists(atPath: journalURL.path) { try FileManager.default.removeItem(at: journalURL) }
                // macOS was not touched and nothing is left on disk: this tap's error only.
                message = failure is JournalPersistenceFailure ? failure.localizedDescription
                    : "The native read or preparation failed before any new setting was dispatched."
            } catch { markJournalIntegrity() }
        } else if transaction.confirmed {
            do { try relinquish(); message = nil } catch { markJournalIntegrity() }
        } else {
            // The write may land at any moment (a setter past its deadline, a readback that did not confirm): a value read
            // before the dispatch is no longer what macOS stores, so no caller decides from it (charge-once, charge-by,
            // the editor shows the reported target or "—" until the next read). A read made after the dispatch (a readback
            // that did not confirm) is what macOS reports now: it stays, so the page does not flash an unknown value.
            let readSinceDispatch = transaction.dispatchedAt.map { dispatched in nativeSetting.map { $0.collectedAt >= dispatched } ?? false }
            if readSinceDispatch != true { nativeSetting = nil }
            journal?.phase = .indeterminate; reviewReason = .mutationUnresolved
            do { try saveJournal(); message = "macOS has not confirmed the last change yet." } catch { markJournalIntegrity() }
        }
    }

    private struct JournalPersistenceFailure: Error, LocalizedError {
        let underlying: any Error
        var errorDescription: String? { underlying.localizedDescription }
    }
    private func saveJournal() throws {
        guard let journal else { return }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        } catch { throw JournalPersistenceFailure(underlying: error) }
    }
    /// How long a session journal waits before a clear read may close it (a write of the same run is never in
    /// flight then: refresh skips while one is pending; the delay only covers a dispatch from a run that just ended).
    static let unresolvedSettleSeconds: TimeInterval = 60
    /// A session journal (any phase or origin, or an unreadable file) only records that a write's outcome was unknown;
    /// nothing is owed to its baseline. The first settled, clear read closes it without a write: confirmed the way a write
    /// is (registry on AC, stored setting on battery), no conflicting rows, a valid state, file at least 60 s old. The value
    /// read does not matter (baseline, requested, a third value set in System Settings, an old validation stage value).
    static func closesSession(value: NativeChargeSnapshot, age: TimeInterval?) -> Bool {
        guard let age, age >= unresolvedSettleSeconds else { return false }
        return value.isFresh && value.policyMatches && !value.registryConflict && NativeChargeAdmission.isValidState(value.configuration)
    }
    private func journalAge() -> TimeInterval? {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: journalURL.path))?[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(date)
    }
    /// Closes the leftover session without any write: an unusable file is set aside (bytes kept, never deleted), a session
    /// journal is removed.
    private func closeSession() throws {
        if unreadableJournal {
            if FileManager.default.fileExists(atPath: journalURL.path) { try setAsideUnreadableJournal() }
            unreadableJournal = false; reviewReason = nil
        }
        if journal != nil { try relinquish() }
    }
    /// `<base>.invalid-<yyyyMMdd-HHmmss>.json` in the same folder. A rename keeps the bytes; moveItem never overwrites (a
    /// name clash gets a UUID suffix). The update probe no longer sees it.
    private func setAsideUnreadableJournal() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = journalURL.deletingLastPathComponent()
        let base = journalURL.deletingPathExtension().lastPathComponent + ".invalid-" + formatter.string(from: Date())
        var destination = folder.appendingPathComponent(base + ".json")
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent(base + "-" + UUID().uuidString + ".json")
        }
        try FileManager.default.moveItem(at: journalURL, to: destination)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    private func relinquish() throws {
        if FileManager.default.fileExists(atPath: journalURL.path) { try FileManager.default.removeItem(at: journalURL) }
        journal = nil; reviewReason = nil
    }
}
