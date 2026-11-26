// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import Darwin
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
    var semanticContract: String?
    var persistentTargets: [Int]?
    var baselineSnapshot: NativeChargeSnapshot?
    /// true: written by a validation run (its stage values are not the user's choice); false: a user apply; nil: a
    /// journal from a build before 0.8.2 that did not record it.
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
              expectedMutation.map(NativeChargeAdmission.isValidState) ?? true,
              !oneShot, oneShotPreviousManagedTarget == nil else { return false }
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
        case none, sessionReview, mutationUnresolved, journalIntegrity, operationPending
        case restorationPending, lowerTargetPending, policyUnconfirmed
    }
    let currentPreference: NativeChargeConfiguration?
    let activePolicy: NativeChargeConfiguration?
    let pendingPurpose: NativeChargeOperationGate.Purpose?
    let hasOwnership: Bool
    let pendingTarget: Int?
    let restorationTarget: Int?
    let attention: Attention
    let hasRecordedMutation: Bool
    let hasSavedAction: Bool
    /// The pending operation has passed its deadline (its XPC call has not returned yet): only then does it get a line.
    var pendingTimedOut = false
    var showsAttentionBanner: Bool {
        guard requiresGlobalAttention else { return false }
        guard attention == .sessionReview else { return true }
        // A saved session stays discoverable in Diagnostics. A recorded
        // unacknowledged mutation or retained action still needs a banner.
        return !hasOwnership || hasRecordedMutation || hasSavedAction || pendingPurpose?.isMutation == true
            || pendingTarget != nil || restorationTarget != nil
    }
    var requiresGlobalAttention: Bool {
        switch attention {
        case .sessionReview, .journalIntegrity, .restorationPending, .lowerTargetPending: true
        // A self-resolving scoped session owns nothing: a local status line, not a banner (fixture sessions still own).
        case .mutationUnresolved: hasOwnership
        case .policyUnconfirmed: hasOwnership
        case .operationPending: pendingTarget != nil || restorationTarget != nil
        case .none: false
        }
    }
}

enum NativeChargeServiceError: Error, LocalizedError {
    case unavailable, busy, unsupportedTarget, unqualifiedTarget, staleBattery, recoveryRequired, readbackMismatch, unsafeEnable
    /// The limit read just before the write was not the one the caller expected (System Settings changed it): nothing written.
    case changedElsewhere
    var errorDescription: String? {
        switch self {
        case .unavailable: "macOS has not reported the charge limit yet. Nothing was changed."
        case .busy: "A native charging operation is still in progress."
        case .unsupportedTarget: "Choose a charge target offered by this Mac."
        case .unqualifiedTarget: "This charge limit is not offered by macOS on this Mac."
        case .staleBattery: "A fresh battery reading is required before changing charging."
        case .recoveryRequired: "The previous charging session needs review before the limit can change."
        case .readbackMismatch: "macOS reported an unclear charge limit, so nothing new was confirmed. Try again in a moment."
        case .unsafeEnable: "Enabling the previous system target could discharge the battery. Waiting for natural discharge."
        case .changedElsewhere: "The charge limit was changed in System Settings. Nothing was written."
        }
    }
}

/// A managed session over the normal-user Apple client. It never registers a
/// helper, changes OBC, guesses a root qualification, or fights external edits.
@MainActor final class NativeChargeService: ObservableObject {
    /// The last read whose policy matched (or the readback of a write); presentation confirms it only while it matches.
    @Published private(set) var observed: NativeChargeSnapshot?
    /// The native preference can exist while macOS registers no active charging
    /// policy on battery. Keep discovery separate from independent confirmation.
    /// Every successful fresh read lands here (`readNative`), whether or not the registry agrees.
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
    private func rememberNativeSetting(_ value: NativeChargeSnapshot) {
        guard value.isFresh else { return }
        nativeSetting = value
        knownTargets = value.supportedTargets
        // The live interface grants the persistent targets (no validation run, no battery floor; see `discovered`).
        if implicitAdmission, !monitoringOnly, admissionScope == nil, !isQualifying,
           let scope = NativeChargeAdmission.discovered(value, environment: environment) {
            admissionScope = scope; admitted = true
        }
    }
    /// Production: the live interface grants the limit. Fixtures keep the explicit validation contract unless they opt in.
    private let implicitAdmission: Bool
    /// A validation proof exists (only that, not the live interface, vouches for a pre-0.8.2 journal of unknown origin).
    private var hasProof: Bool
    /// The limits were proven by a validation run (Diagnostics says «Verified» only then; otherwise «Available»).
    var hasValidationProof: Bool { hasProof || trustedFixtureAuthority }
    /// Not read yet while the live interface is about to grant the limit: no «Validate» button flashes at launch.
    var awaitingDiscovery: Bool { implicitAdmission && !monitoringOnly && !admitted && nativeSetting == nil }
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
    /// Explicit injection is reserved for trusted fixture/Studio compositions.
    /// The production convenience initializer never supplies this blanket grant.
    private let trustedFixtureAuthority: Bool
    private var admissionScope: NativeChargeAdmission.Scope?
    private var qualificationBaseline: NativeChargeSnapshot?
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
    /// The background refresh's own read: it never counts as a pending operation in the presentation (no flicker).
    private var isRefreshing = false
    /// The longest a native apply can take (gate deadline plus the readback budget), for the model's waits.
    var maximumOperationDuration: Duration { operationTimeout + verificationDelay * verificationAttempts + .seconds(2) }
    private var batteryPercent: Int?
    private var batteryFresh = false
    private var reviewReason: NativeChargePresentation.Attention?

    /// Provenance exists only within the current transaction, never inferred from
    /// a reopened v1 journal or from expectedMutation having been cleared.
    private final class Transaction {
        enum Mutation {
            case untouched
            case dispatched(NativeChargeConfiguration)
            case returnedAwaitingConfiguration(NativeChargeConfiguration)
            case configurationConfirmed(NativeChargeConfiguration)
        }
        let entryJournal: NativeChargeJournal?
        let entryBytes: Data?
        let entryRecovery: Bool
        let entryReview: NativeChargePresentation.Attention?
        let entryPending: Int?
        let entryRestoration: Bool
        var sessionID: UUID?
        var everDispatched = false
        var mutation: Mutation = .untouched
        var allDispatchedConfirmed: Bool {
            if case .configurationConfirmed = mutation { return everDispatched }
            return false
        }
        init(journal: NativeChargeJournal?, bytes: Data?, recovery: Bool,
             review: NativeChargePresentation.Attention?, pending: Int?, restoration: Bool) {
            entryJournal = journal; entryBytes = bytes; entryRecovery = recovery
            entryReview = review; entryPending = pending; entryRestoration = restoration
            sessionID = journal?.sessionID
        }
    }

    func presentation(at date: Date = Date()) -> NativeChargePresentation {
        let preference = nativeSetting.flatMap { $0.isFresh(at: date) ? $0.configuration : nil }
        // The background refresh's own read keeps the last reading and the state it showed: no status line or height
        // change on every poll. Writes, validation, the reads inside an apply and a read past its deadline still count.
        // The very first read (nothing known yet) still shows its progress.
        let backgroundRead = isRefreshing && operationGate.pendingPurpose == .read && !operationGate.timedOut
            && (nativeSetting != nil || observed != nil || incompleteObservation != nil)
        let policy = observed.flatMap { $0.isFresh(at: date) && $0.policyMatches && !recoveryRequired
            && (!operationGate.pending || backgroundRead) ? $0.configuration : nil }
        let attention: NativeChargePresentation.Attention
        if let reviewReason { attention = reviewReason }
        else if recoveryRequired { attention = .sessionReview }
        else if (operationGate.pending && !backgroundRead) || (isBusy && !isRefreshing) || isQualifying { attention = .operationPending }
        else if restorationPending { attention = .restorationPending }
        else if pendingTarget != nil { attention = .lowerTargetPending }
        else if policy == nil { attention = .policyUnconfirmed }
        else { attention = .none }
        return .init(currentPreference: preference, activePolicy: policy, pendingPurpose: operationGate.pendingPurpose,
                     hasOwnership: hasOwnedSettings, pendingTarget: pendingTarget,
                     restorationTarget: restorationPending ? journal?.baseline.target : nil, attention: attention,
                     hasRecordedMutation: journal?.expectedMutation != nil,
                     hasSavedAction: journal.map { [.pendingTarget, .preparing, .restoring, .restorationPending].contains($0.phase) } ?? false,
                     pendingTimedOut: operationGate.pending && operationGate.timedOut)
    }

    var isMonitoringOnly: Bool { monitoringOnly }
    /// A scoped (v2) session owns nothing: a confirmed limit is the user's macOS setting and an unconfirmed one closes itself.
    /// Only the legacy fixture session still owns what it wrote.
    var hasOwnedSettings: Bool { journal?.hasWritten == true && journal?.version != 2 }
    private var scopedAuthority: Bool { !trustedFixtureAuthority }
    var authorizedPersistentTargets: [Int] {
        guard !monitoringOnly else { return [] }
        return trustedFixtureAuthority ? acceptedTargets : admissionScope?.authorizedPersistentTargets ?? []
    }
    /// A stored state a user write may start from: an authorized target, a valid state and the offered list. The registry
    /// is deliberately not required (on AC both rows follow a write, so the write is what clears a two-row conflict).
    private func isAuthorizedPersistentState(_ value: NativeChargeSnapshot) -> Bool {
        guard let scope = admissionScope, scope.environment == environment,
              scope.authorizedPersistentTargets.contains(value.configuration.target) else { return false }
        return NativeChargeAdmission.isValidState(value.configuration) && NativeChargeAdmission.validOfferedTargets(value.supportedTargets)
    }
    var isAvailable: Bool {
        guard !operationGate.pending, admitted, !monitoringOnly else { return false }
        if trustedFixtureAuthority {
            guard !unreadableJournal, let observed, observed.isFresh, observed.policyMatches else { return false }
            return true
        }
        // The slider works from what macOS stores (as System Settings does); the readback after a write decides.
        guard let setting = nativeSetting, setting.isFresh else { return false }
        return NativeChargeAdmission.isValidState(setting.configuration) && NativeChargeAdmission.validOfferedTargets(setting.supportedTargets)
    }
    var canApply: Bool { isAvailable && !isBusy && !isQualifying && !recoveryRequired && !restorationPending }
    func canApplyTarget(_ target: Int) -> Bool { canApply && acceptedTargets.contains(target) && authorizedPersistentTargets.contains(target) }
    /// Whether the target is on offer at all, ignoring momentary states (a read or an apply in flight, a pending operation, a
    /// lapsed freshness window). Controls take their look from this so they never blink while a limit is being applied; the
    /// tap itself is still gated by `canApplyTarget`.
    func offersTarget(_ target: Int) -> Bool {
        admitted && !monitoringOnly && !recoveryRequired && !restorationPending
            && acceptedTargets.contains(target) && authorizedPersistentTargets.contains(target)
    }
    /// Cached state readiness only. qualify() obtains its own fresh battery and
    /// native preflight before granting the two finite transitions.
    var canRequestQualification: Bool {
        guard !monitoringOnly, !isBusy, !operationGate.pending, !isQualifying,
              journal == nil, !unreadableJournal, !recoveryRequired, !restorationPending, pendingTarget == nil,
              admissionURL != nil, environment != "unavailable", batteryProvider != nil,
              let value = observed, value.isFresh else { return false }
        return NativeChargeAdmission.persistentTargets.contains(value.configuration.target)
            && NativeChargeAdmission.isPersistent(value, target: value.configuration.target, optimizedCharging: value.configuration.optimizedCharging, strict: true)
    }
    func needsApply(target: Int) -> Bool {
        guard canApplyTarget(target) else { return false }
        // An explicit lower pending intent still has a distinct cancellation path.
        if pendingTarget != nil { return requestedIntent != .ceiling(target) }
        // The scoped path compares with what macOS reports (100 is "limit off").
        if !trustedFixtureAuthority { return reportedLimit.map { $0 != target } ?? true }
        guard let observed else { return true }
        // 100 is "limit off"; every other verified target is an enabled limit.
        return observed.configuration.target != target || observed.configuration.enabled != (target != NativeChargeAdmission.unlimitedTarget)
    }
    var canChargeToFullOnce: Bool { canApplyTarget(100) && fullOnceQualified && trustedFixtureAuthority }
    var isOneShot: Bool { journal?.oneShot == true }
    /// Fixture-only intents (a waiting target, a one-shot, a legacy owned session). A scoped session journal's last value
    /// is never shown as an intent: the surfaces show what macOS reports.
    var requestedIntent: ChargeIntent? {
        if isOneShot { return .fullOnce }
        if let pendingTarget { return .ceiling(pendingTarget) }
        if journal?.version == 1, journal?.hasWritten == true, let target = journal?.lastVerified.target { return .ceiling(target) }
        return nil
    }
    var acceptedTargets: [Int] { knownTargets }
    var interfaceWasDiscovered: Bool { !knownTargets.isEmpty || admitted || journal != nil || unreadableJournal }
    var baselineTarget: Int? { journal?.baseline.target }

    init(client: any NativeChargeTransport, journalURL: URL, admitted: Bool = false, admissionScope: NativeChargeAdmission.Scope? = nil, monitoringOnly: Bool = false,
         verificationAttempts: Int = 30, verificationDelay: Duration = .zero,
         environment: String = ProcessInfo.processInfo.operatingSystemVersionString,
         batteryProvider: (@Sendable () async -> ChargeObservation)? = nil, admissionURL: URL? = nil,
         operationTimeout: Duration = .seconds(15), fullOnceQualified: Bool = false, implicitAdmission: Bool = false) {
        operationGate = NativeChargeOperationGate(timeout: operationTimeout); self.fullOnceQualified = fullOnceQualified
        self.client = client; self.journalURL = journalURL; self.monitoringOnly = monitoringOnly
        trustedFixtureAuthority = admitted && !monitoringOnly
        self.admissionScope = !monitoringOnly && admissionScope?.environment == environment ? admissionScope : nil
        self.admitted = !monitoringOnly && (admitted || self.admissionScope != nil)
        self.implicitAdmission = implicitAdmission; hasProof = self.admissionScope != nil
        self.batteryProvider = batteryProvider; self.admissionURL = admissionURL
        self.verificationAttempts = max(1, verificationAttempts); self.verificationDelay = verificationDelay; self.environment = environment
        self.operationTimeout = operationTimeout
        if !monitoringOnly && FileManager.default.fileExists(atPath: journalURL.path) {
            do {
                let saved = try JSONDecoder().decode(NativeChargeJournal.self, from: Data(contentsOf: journalURL))
                let trustedLegacy = trustedFixtureAuthority && saved.version == 1 && saved.environment == environment
                    && (80...100).contains(saved.baseline.target) && (80...100).contains(saved.lastVerified.target)
                    && (saved.plannedTarget.map({ (80...100).contains($0) }) ?? true)
                if saved.version == 2, !saved.hasWritten {
                    // Nothing was dispatched (a waiting target, or a crash before the write-ahead): the user's macOS setting
                    // is untouched, whatever phase or macOS version wrote the journal. Nothing to review.
                    try FileManager.default.removeItem(at: journalURL)
                } else if saved.version == 2, saved.hasPersistentScope(environment: environment) {
                    // A dispatched write whose outcome is unknown, of any phase or origin. Nothing is owed to its baseline
                    // (a confirmed limit is the user's own): it blocks nothing and closes at the first settled clear read.
                    journal = saved; reviewReason = .mutationUnresolved
                } else if trustedLegacy {
                    journal = saved; recoveryRequired = true; reviewReason = .sessionReview
                    restorationPending = saved.phase == .restorationPending
                    message = "A previous native charge session needs review. Saved intent was not reapplied."
                } else { throw NativeChargeServiceError.recoveryRequired }
            } catch {
                // Unreadable, v1, another contract or another Mac: never acted on, kept in place for now (set aside later).
                unreadableJournal = true; reviewReason = .mutationUnresolved
            }
        }
        operationGate.onTimeout = { [weak self] purpose in
            guard let self else { return }
            if purpose.isMutation, self.journal != nil {
                // The outcome is unknown: recorded (status line only on the scoped path, which closes itself later).
                self.journal?.phase = .indeterminate
                if self.journal?.version == 1 { self.recoveryRequired = true }
                self.reviewReason = .mutationUnresolved
                do { try self.saveJournal() } catch { self.reviewReason = .journalIntegrity }
            }
            self.observed = nil
            self.message = purpose.isMutation
                ? "The native setting operation timed out. Its outcome needs review; further writes are blocked."
                : "The native policy read timed out. Further actions wait for the read to return."
        }
        operationGate.onLateCompletion = { [weak self] purpose in
            self?.objectWillChange.send()
            self?.message = purpose.isMutation
                ? "The delayed setting operation returned. Its outcome still needs explicit review."
                : "The delayed policy read returned. Refresh to obtain a current policy reading."
        }
    }

    convenience init(historyURL: URL, launchPolicy: AppLaunchPolicy = .current()) {
        let root = historyURL.deletingLastPathComponent()
        let environment = NativeChargeAdmission.currentEnvironment
        let admission = root.appendingPathComponent("native-charge-validation.json")
        let monitoring = launchPolicy.monitoringOnly
        let reader = NativeChargeBackend()
        // A normal write reads back in one or two reads; six one-second tries bound the wait (an unconfirmed write closes
        // itself later, the slider keeps working).
        self.init(client: Self.liveTransport(), journalURL: root.appendingPathComponent("native-charge-session.json"),
                  admissionScope: monitoring ? nil : NativeChargeAdmission.loadScope(from: admission, environment: environment), monitoringOnly: monitoring,
                  verificationAttempts: 6, verificationDelay: .seconds(1), environment: environment,
                  batteryProvider: { await reader.currentObservation() }, admissionURL: admission, implicitAdmission: true)
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

    func qualify() async throws {
        guard !monitoringOnly, !isBusy, !operationGate.pending, !isQualifying, journal == nil, !unreadableJournal,
              !recoveryRequired, !restorationPending, pendingTarget == nil,
              let admissionURL, environment != "unavailable", let batteryProvider else { throw NativeChargeServiceError.unavailable }
        isQualifying = true
        defer { isQualifying = false; qualificationBaseline = nil }
        let baseline = try await readNative(); observed = baseline
        let battery = await batteryProvider()
        guard baseline.isFresh, NativeChargeAdmission.persistentTargets.contains(baseline.configuration.target),
              NativeChargeAdmission.isPersistent(baseline, target: baseline.configuration.target, optimizedCharging: baseline.configuration.optimizedCharging, strict: true) else {
            throw NativeChargeServiceError.readbackMismatch
        }
        // Every other persistent target is written in ascending order. A target at or below the battery level would
        // leave a "lower target pending" state, so the battery must be below the lowest one.
        let stageTargets = NativeChargeAdmission.persistentTargets.filter { $0 != baseline.configuration.target }
        guard battery.fresh, let percent = battery.percent, percent < (stageTargets.min() ?? 0) else {
            message = "Validation requires a confirmed persistent baseline and a fresh battery level below 80%. No setting was written."
            throw NativeChargeServiceError.staleBattery
        }
        // This grant never sets admitted=true. It only permits the finite persistent targets with unchanged OBC, a
        // complete persistent state and a durable scoped journal; the baseline is restored at the end.
        qualificationBaseline = baseline
        self.batteryPercent = percent; self.batteryFresh = true
        let transaction = makeTransaction()
        var stagesComplete = false
        do {
            journal = makeScopedJournal(baseline: baseline, plannedTarget: stageTargets[0], qualification: true)
            transaction.sessionID = journal?.sessionID
            try saveJournal()
            var stages: [NativeChargeSnapshot] = []
            for (index, target) in stageTargets.enumerated() {
                if index > 0 { journal?.plannedTarget = target; journal?.phase = .preparing; try saveJournal() }
                try await mutate(transaction: transaction,
                                 expected: .init(enabled: target != NativeChargeAdmission.unlimitedTarget, target: target,
                                                 optimizedCharging: baseline.configuration.optimizedCharging)) {
                    try await self.setNativeLimit(target, transaction: transaction)
                }
                let changed = try await verify(target: target, enabled: target != NativeChargeAdmission.unlimitedTarget)
                guard NativeChargeAdmission.isPersistent(changed, target: target, optimizedCharging: baseline.configuration.optimizedCharging, strict: true),
                      changed.supportedTargets == baseline.supportedTargets else { throw NativeChargeServiceError.readbackMismatch }
                journal?.lastVerified = changed.configuration; journal?.phase = .owned; journal?.plannedTarget = nil
                try saveJournal()
                stages.append(changed)
            }
            stagesComplete = true
            let after = await batteryProvider()
            guard try await restoreInternal(batteryPercent: after.percent, batteryFresh: after.fresh), let restored = observed,
                  NativeChargeAdmission.isPersistent(restored, target: baseline.configuration.target, optimizedCharging: baseline.configuration.optimizedCharging, strict: true),
                  restored.supportedTargets == baseline.supportedTargets else { throw NativeChargeServiceError.recoveryRequired }
            let proof = NativeChargeAdmission(version: NativeChargeAdmission.version, environment: environment,
                semanticContract: NativeChargeAdmission.semanticContract, authorizedPersistentTargets: NativeChargeAdmission.persistentTargets,
                offeredTargets: baseline.supportedTargets, baseline: baseline.configuration, before: baseline,
                stages: stages, restored: restored, completedAt: Date())
            // Encode/validate before replacing historical proof bytes. No failed
            // qualification can migrate an old proof into current authority.
            guard let scope = NativeChargeAdmission.validatedScope(proof, environment: environment) else { throw NativeChargeServiceError.readbackMismatch }
            let encoded = try JSONEncoder().encode(proof)
            do { try persistAdmission(encoded, to: admissionURL) }
            catch { throw AdmissionPersistenceFailure() }
            admissionScope = scope; admitted = true; hasProof = true
            message = "Persistent 80%, 85%, 90%, 95% and 100% settings and restoration passed on this Mac. Other targets and physical cutoff remain unqualified."
        } catch {
            if !stagesComplete { handleFailure(transaction, failure: error) }
            if journal != nil { recoveryRequired = true }
            if error is AdmissionPersistenceFailure { message = error.localizedDescription }
            throw error
        }
    }

    private struct AdmissionPersistenceFailure: Error, LocalizedError {
        var errorDescription: String? {
            "The persistent baseline was restored, but the validation proof could not be saved safely. The previous proof was preserved."
        }
    }

    /// Only the successful, restored qualification commits evidence. Existing
    /// proof bytes are retained privately and verified before atomic replacement.
    private func persistAdmission(_ encoded: Data, to url: URL) throws {
        let failure = AdmissionPersistenceFailure()
        guard let proof = try? JSONDecoder().decode(NativeChargeAdmission.self, from: encoded),
              NativeChargeAdmission.validatedScope(proof, environment: environment) != nil else { throw failure }
        let root = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw failure }
        defer { close(root) }

        func regularMetadata(_ descriptor: Int32, mode: mode_t? = nil) throws -> stat {
            var value = stat()
            guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
                  value.st_nlink == 1, value.st_uid == geteuid(),
                  mode.map({ value.st_mode & 0o777 == $0 }) ?? true else { throw failure }
            return value
        }
        func readRegular(_ directory: Int32, _ name: String, mode: mode_t? = nil) throws -> (Data, stat) {
            let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw failure }
            defer { close(descriptor) }
            let before = try regularMetadata(descriptor, mode: mode)
            let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
            let after = try regularMetadata(descriptor, mode: mode)
            guard before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_size == after.st_size, Int64(data.count) == after.st_size else { throw failure }
            return (data, after)
        }
        func writeRegular(_ directory: Int32, _ name: String, data: Data, mode: mode_t) throws {
            let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard descriptor >= 0 else { throw failure }
            defer { close(descriptor) }
            _ = try regularMetadata(descriptor, mode: 0o600)
            try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: data)
            guard fchmod(descriptor, mode) == 0, fsync(descriptor) == 0 else { throw failure }
            _ = try regularMetadata(descriptor, mode: mode)
        }

        let liveName = url.lastPathComponent
        var live = stat()
        let existing = fstatat(root, liveName, &live, AT_SYMLINK_NOFOLLOW) == 0
        guard existing || errno == ENOENT else { throw failure }
        var previous: Data?
        var publicationMode: mode_t = 0o600
        if existing {
            let (bytes, metadata) = try readRegular(root, liveName)
            guard live.st_dev == metadata.st_dev, live.st_ino == metadata.st_ino else { throw failure }
            previous = bytes; publicationMode = metadata.st_mode & 0o600
            let historyName = "native-charge-proof-history"
            guard mkdirat(root, historyName, mode_t(0o700)) == 0 || errno == EEXIST else { throw failure }
            let history = openat(root, historyName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard history >= 0 else { throw failure }
            defer { close(history) }
            var directory = stat()
            guard fstat(history, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
                  directory.st_uid == geteuid(), directory.st_mode & 0o777 == 0o700 else { throw failure }
            let receipt = "proof-\(UUID().uuidString).json"
            try writeRegular(history, receipt, data: bytes, mode: 0o600)
            let (archived, _) = try readRegular(history, receipt, mode: 0o600)
            guard archived == bytes else { throw failure }
        }

        let stagedName = ".native-charge-proof-\(UUID().uuidString).tmp"
        defer { unlinkat(root, stagedName, 0) }
        try writeRegular(root, stagedName, data: encoded, mode: publicationMode)
        let (staged, _) = try readRegular(root, stagedName, mode: publicationMode)
        guard staged == encoded else { throw failure }
        // A changed, linked or replaced live proof must not be overwritten after
        // the archive was checked. Descriptor-relative operations never follow
        // a replacement symlink for either the receipt or publication target.
        if let previous {
            let (current, metadata) = try readRegular(root, liveName)
            guard current == previous, metadata.st_dev == live.st_dev, metadata.st_ino == live.st_ino,
                  metadata.st_mode == live.st_mode else { throw failure }
        } else {
            var appeared = stat()
            guard fstatat(root, liveName, &appeared, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw failure }
        }
        guard renameat(root, stagedName, root, liveName) == 0 else { throw failure }
    }

    private func makeScopedJournal(baseline: NativeChargeSnapshot, plannedTarget: Int, qualification: Bool) -> NativeChargeJournal {
        var saved = NativeChargeJournal(sessionID: UUID(), environment: environment, baseline: baseline.configuration,
            lastVerified: baseline.configuration, plannedTarget: plannedTarget, phase: .preparing)
        saved.version = 2; saved.semanticContract = NativeChargeAdmission.semanticContract
        saved.persistentTargets = NativeChargeAdmission.persistentTargets; saved.baselineSnapshot = baseline
        saved.qualification = qualification
        return saved
    }

    static let registryConflictMessage = "macOS lists two different charge limits. Set the limit once in System Settings › Battery to bring them together."
    static let policyUnconfirmedMessage = "macOS has not confirmed the active limit yet."

    func refresh() async {
        guard !isBusy, !isQualifying, !operationGate.pending else { return }
        isBusy = true; isRefreshing = true; defer { isBusy = false; isRefreshing = false }
        do {
            let value = try await readNative()   // a fresh read lands in nativeSetting whether or not the registry agrees
            guard value.isFresh && value.policyMatches else {
                observed = nil
                message = value.registryConflict ? Self.registryConflictMessage : Self.policyUnconfirmedMessage
                return
            }
            observed = value
            if message == Self.registryConflictMessage || message == Self.policyUnconfirmedMessage { message = nil }
            // A session journal (any scoped phase or origin, or an unusable file) only records that a write's outcome was
            // unknown. The first settled, clear read closes it without any write: that limit is the user's macOS setting.
            if !monitoringOnly, hasUnresolvedSession, journal?.version != 1, Self.closesSession(value: value, age: journalAge()) {
                do { try closeSession(); message = nil } catch { markJournalIntegrity() }
                return
            }
            if !monitoringOnly, let journal, journal.version == 1, journal.phase != .preparing && journal.phase != .restoring && journal.phase != .indeterminate,
               !value.configuration.matchesManual(journal.lastVerified) {
                try relinquish()
                message = "The macOS charge setting changed outside Tilvero. Control was released without overwriting it."
            }
        } catch { observed = nil; message = error.localizedDescription }
    }

    /// `expectedCurrent`: the limit the caller saw (charge-by, charge-once). A different fresh value means System Settings
    /// changed it: `changedElsewhere`, nothing written.
    func apply(_ target: Int, batteryPercent: Int?, batteryFresh: Bool, expectedCurrent: Int? = nil) async throws {
        guard !isQualifying else { throw NativeChargeServiceError.busy }
        if trustedFixtureAuthority {
            try await applyInternal(target, batteryPercent: batteryPercent, batteryFresh: batteryFresh, expectedCurrent: expectedCurrent)
        } else {
            try await applyScoped(target, expectedCurrent: expectedCurrent)
        }
    }

    /// The one production write path, exactly what System Settings does: a fresh read, a write-ahead journal, one
    /// setMCLLimit inside the gate, a bounded readback, then the journal goes (a confirmed limit is the user's own setting).
    /// No battery reading, no validation run; a level below the charge is set at once. An unconfirmed write leaves an
    /// indeterminate journal that blocks nothing and closes itself at the first settled clear read.
    private func applyScoped(_ target: Int, expectedCurrent: Int?) async throws {
        guard !monitoringOnly, admitted else { throw NativeChargeServiceError.unavailable }
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
        let transaction = makeTransaction()   // entry: no journal, no bytes
        journal = makeScopedJournal(baseline: current, plannedTarget: target, qualification: false)
        transaction.sessionID = journal?.sessionID
        do {
            try saveJournal()
            try await mutate(transaction: transaction, expected: .init(enabled: target != NativeChargeAdmission.unlimitedTarget, target: target,
                                                                       optimizedCharging: current.configuration.optimizedCharging),
                             allowBelowCharge: true) {
                try await self.setNativeLimit(target, transaction: transaction)
            }
            // Confirmed: the user's own macOS setting. No baseline is kept to rewrite later.
            try relinquish(); message = nil
        } catch {
            handleFailure(transaction, failure: error)
            throw error
        }
    }

    private func applyInternal(_ target: Int, batteryPercent: Int?, batteryFresh: Bool, expectedCurrent: Int? = nil) async throws {
        guard !monitoringOnly, admitted, !unreadableJournal else { throw NativeChargeServiceError.unavailable }
        guard !isBusy, !operationGate.pending else { throw NativeChargeServiceError.busy }
        guard !recoveryRequired && !restorationPending else { throw NativeChargeServiceError.recoveryRequired }
        isBusy = true; defer { isBusy = false }
        // Presentation readings can honestly have unknown sensor age. Explicit
        // native control uses the same dedicated current observation as qualification.
        let actionBattery = await batteryProvider?()
        let fresh = actionBattery?.fresh ?? batteryFresh
        let actionPercent = actionBattery != nil ? actionBattery!.percent : batteryPercent
        guard fresh, let percent = actionPercent, (0...100).contains(percent) else { throw NativeChargeServiceError.staleBattery }
        self.batteryPercent = percent; self.batteryFresh = true
        let current = try await readNative()
        observed = current
        guard current.isFresh && current.policyMatches else { throw NativeChargeServiceError.readbackMismatch }
        guard current.supportedTargets.contains(target) else { throw NativeChargeServiceError.unsupportedTarget }
        if let expectedCurrent, Self.limit(current.configuration) != expectedCurrent { throw NativeChargeServiceError.changedElsewhere }
        if let journal, !current.configuration.matchesManual(journal.lastVerified) {
            try relinquish(); throw NativeChargeServiceError.recoveryRequired
        }
        if current.configuration.target == target && current.configuration.enabled == (target != NativeChargeAdmission.unlimitedTarget || !scopedAuthority) {
            pendingTarget = nil
            if journal?.hasWritten == false { try relinquish() }
            else if journal != nil { journal?.phase = .owned; journal?.plannedTarget = nil; try saveJournal() }
            message = "The selected native limit is already active."; return
        }
        let transaction = makeTransaction()
        do {
            if journal == nil {
                if trustedFixtureAuthority {
                    journal = .init(sessionID: UUID(), environment: environment, baseline: current.configuration,
                                    lastVerified: current.configuration, plannedTarget: target, phase: .preparing)
                } else { journal = makeScopedJournal(baseline: current, plannedTarget: target, qualification: false) }
            }
            transaction.sessionID = journal?.sessionID
            journal?.plannedTarget = target
            // Owner decision 2026-11-26: the slider does exactly what System Settings does, so a limit below the charge level
            // is written at once too (macOS then stops charging there, as it does for its own slider). Only the legacy
            // fixture path still waits for natural discharge. An already-active limit is handled above, without a write.
            let safeFloor = current.configuration.enabled ? target : min(target, current.configuration.target)
            if trustedFixtureAuthority, percent > safeFloor {
                journal?.phase = .pendingTarget; try saveJournal()
                pendingTarget = target
                message = "Waiting for natural discharge before applying the lower native limit. The current system setting remains active."
                return
            }
            journal?.phase = .preparing; try saveJournal()
            // A scoped session re-enables the limit through the limit write itself (read back and journalled);
            // the separate enable operation belongs to the legacy fixture path only.
            if !current.configuration.enabled && journal?.version != 2 {
                try await mutate(transaction: transaction, expected: .init(enabled: true, target: current.configuration.target, optimizedCharging: current.configuration.optimizedCharging)) {
                    try await self.setNativeEnabled(true, transaction: transaction)
                }
            }
            let scoped = journal?.version == 2
            let toUnlimited = scoped && target == NativeChargeAdmission.unlimitedTarget
            try await mutate(transaction: transaction, expected: .init(enabled: !toUnlimited, target: target, optimizedCharging: current.configuration.optimizedCharging),
                             permitDisabled100: target == 100 && !scoped, allowBelowCharge: !trustedFixtureAuthority) {
                try await self.setNativeLimit(target, transaction: transaction)
            }
            let verified = try await verify(target: target, enabled: toUnlimited ? false : nil)
            journal?.lastVerified = verified.configuration; journal?.phase = .owned; journal?.plannedTarget = nil
            try saveJournal(); observed = verified; pendingTarget = nil
            // A limit macOS has independently confirmed is the user's own system setting (the slider does what System
            // Settings does). The scoped session ends here: no baseline is kept to rewrite when Tilvero quits, and a later
            // change made in System Settings is simply observed. Unresolved or unconfirmed states never reach this point.
            if journal?.version == 2 { try relinquish() }
            message = "The native macOS charge limit was independently confirmed."
        } catch {
            if case NativeChargeServiceError.unsafeEnable = error,
               !transaction.everDispatched || transaction.allDispatchedConfirmed {
                journal?.phase = .pendingTarget; pendingTarget = target
                do { try saveJournal() } catch { markJournalIntegrity(); throw error }
                message = NativeChargeServiceError.unsafeEnable.localizedDescription
                return
            }
            handleFailure(transaction, failure: error)
            throw error
        }
    }

    func observeBattery(percent: Int?, fresh: Bool) async {
        batteryPercent = percent; batteryFresh = fresh
        guard !monitoringOnly else { return }
        guard !isBusy, !isQualifying, !operationGate.pending, !recoveryRequired else { return }
        let observation = (pendingTarget != nil || restorationPending || isOneShot) ? await batteryProvider?() : nil
        let currentFresh = observation?.fresh ?? fresh
        let currentPercent = observation != nil ? observation!.percent : percent
        guard currentFresh, let percent = currentPercent else { return }
        if isOneShot && percent >= 100 {
            try? await cancelOneShot(batteryPercent: percent, batteryFresh: true)
        } else if restorationPending {
            _ = try? await restore(batteryPercent: percent, batteryFresh: true)
        } else if let target = pendingTarget, percent <= target {
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
        // Nothing is owed to a scoped session's baseline (a confirmed limit is the user's macOS setting) and an unusable
        // file is never acted on: no write and no refusal; the session closes at the next settled clear read. Only a
        // validation run's own final restore still writes.
        if !trustedFixtureAuthority || unreadableJournal || journal?.version == 2 {
            guard isQualifying, let saved = journal, saved.version == 2 else { return true }
            return try await restorePersistent(saved, batteryPercent: batteryPercent, batteryFresh: batteryFresh)
        }
        guard !monitoringOnly, (admitted || journal?.hasWritten == true) else {
            if journal != nil { throw NativeChargeServiceError.unavailable }
            return true
        }
        guard let saved = journal else {
            guard reviewReason != .journalIntegrity else { throw NativeChargeServiceError.recoveryRequired }
            pendingTarget = nil; recoveryRequired = false; return true
        }
        if saved.version == 2 { return try await restorePersistent(saved, batteryPercent: batteryPercent, batteryFresh: batteryFresh) }
        guard trustedFixtureAuthority else { throw NativeChargeServiceError.unavailable }
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
        let restoringFromDisabled100 = !current.configuration.enabled && current.configuration.target == 100 && saved.baseline.enabled
        let canDisableWithoutTargetChange = !saved.baseline.enabled && !needsTargetChange
        let transaction = makeTransaction()
        do {
            if !canDisableWithoutTargetChange && safeRestoreFloor <= percent {
                journal?.phase = .restorationPending; restorationPending = true
                recoveryRequired = transaction.entryRecovery; try saveJournal()
                message = "Restoring the original limit is waiting for natural discharge. Keep Tilvero open; the current limit remains active."
                return false
            }
            journal?.phase = .restoring; try saveJournal()
            journal?.lastVerified = current.configuration; try saveJournal()
            if !current.configuration.enabled {
                try await mutate(transaction: transaction, expected: .init(enabled: true, target: current.configuration.target, optimizedCharging: current.configuration.optimizedCharging),
                                 allowRestoredBaseline: restoringFromDisabled100) {
                    try await self.setNativeEnabled(true, transaction: transaction)
                }
            }
            // enableMCL may recall the previously selected limit itself.
            if observed?.configuration.target != saved.baseline.target {
                try await mutate(transaction: transaction, expected: .init(enabled: true, target: saved.baseline.target, optimizedCharging: current.configuration.optimizedCharging)) {
                    try await self.setNativeLimit(saved.baseline.target, transaction: transaction)
                }
            }
            if !saved.baseline.enabled {
                try await mutate(transaction: transaction, expected: .init(enabled: false, target: saved.baseline.target, optimizedCharging: current.configuration.optimizedCharging)) {
                    try await self.setNativeEnabled(false, transaction: transaction)
                }
            }
            let value = try await verify(target: saved.baseline.target, enabled: saved.baseline.enabled)
            guard !restoringFromDisabled100 || value.configuration.matchesManual(saved.baseline) else { throw NativeChargeServiceError.readbackMismatch }
            observed = value; try relinquish()
            message = "The original macOS charge setting was verified as restored."
            return true
        } catch {
            if case NativeChargeServiceError.unsafeEnable = error,
               !transaction.everDispatched || transaction.allDispatchedConfirmed {
                journal?.phase = .restorationPending; restorationPending = true
                recoveryRequired = transaction.entryRecovery
                do { try saveJournal() } catch { markJournalIntegrity(); throw error }
                message = NativeChargeServiceError.unsafeEnable.localizedDescription
                return false
            }
            handleFailure(transaction, failure: error)
            throw error
        }
    }

    /// A scoped journal can authorize only restoration to its verified persistent
    /// pair baseline. It never grants Apply and never enters legacy recall paths.
    private func restorePersistent(_ saved: NativeChargeJournal, batteryPercent: Int?, batteryFresh: Bool) async throws -> Bool {
        guard saved.hasPersistentScope(environment: environment) else { throw NativeChargeServiceError.recoveryRequired }
        isBusy = true; defer { isBusy = false }
        let current = try await readNative(); observed = current
        guard current.isFresh, NativeChargeAdmission.persistentTargets.contains(current.configuration.target),
              current.supportedTargets == saved.baselineSnapshot?.supportedTargets,
              NativeChargeAdmission.isPersistent(current, target: current.configuration.target, optimizedCharging: saved.baseline.optimizedCharging)
        else { throw NativeChargeServiceError.readbackMismatch }
        if saved.hasWritten, current.configuration.matchesManual(saved.baseline),
           (saved.expectedMutation != nil || [.indeterminate, .preparing, .restoring].contains(saved.phase)) {
            recoveryRequired = true
            message = "An unconfirmed native operation may still take effect. The recovery journal was preserved; no follow-up write was started."
            return false
        }
        if current.configuration.matchesManual(saved.baseline) {
            try relinquish(); message = "The verified persistent baseline is confirmed."; return true
        }
        guard current.configuration.matchesManual(saved.lastVerified) || saved.expectedMutation.map(current.configuration.matchesManual) == true else {
            throw NativeChargeServiceError.recoveryRequired
        }
        let battery = await batteryProvider?()
        let fresh = battery?.fresh ?? batteryFresh
        let percent = battery != nil ? battery!.percent : batteryPercent
        guard fresh, let percent, (0...100).contains(percent) else { throw NativeChargeServiceError.staleBattery }
        self.batteryPercent = percent; self.batteryFresh = true
        let transaction = makeTransaction()
        do {
            guard percent <= saved.baseline.target else {
                journal?.phase = .restorationPending; restorationPending = true
                try saveJournal()
                message = "Restoring the persistent baseline is waiting for natural discharge."
                return false
            }
            journal?.phase = .restoring; journal?.lastVerified = current.configuration; try saveJournal()
            try await mutate(transaction: transaction, expected: saved.baseline) {
                try await self.setNativeLimit(saved.baseline.target, transaction: transaction)
            }
            let restored = try await verify(target: saved.baseline.target, enabled: saved.baseline.enabled)
            guard restored.configuration.matchesManual(saved.baseline) else { throw NativeChargeServiceError.readbackMismatch }
            observed = restored; try relinquish()
            message = "The original persistent macOS charge setting was verified as restored."
            return true
        } catch {
            if case NativeChargeServiceError.unsafeEnable = error,
               !transaction.everDispatched || transaction.allDispatchedConfirmed {
                journal?.phase = .restorationPending; restorationPending = true
                recoveryRequired = transaction.entryRecovery
                do { try saveJournal() } catch { markJournalIntegrity(); throw error }
                return false
            }
            handleFailure(transaction, failure: error)
            throw error
        }
    }

    func chargeToFullOnce(batteryPercent: Int?, batteryFresh: Bool) async throws {
        guard fullOnceQualified, trustedFixtureAuthority else { throw NativeChargeServiceError.unavailable }
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

    private func mutate(transaction: Transaction, expected: NativeChargeConfiguration, permitDisabled100: Bool = false,
                        allowRestoredBaseline: Bool = false, allowBelowCharge: Bool = false,
                        operation: @MainActor () async throws -> Void) async throws {
        guard let saved = journal else { throw NativeChargeServiceError.recoveryRequired }
        let scoped = saved.version == 2
        // A user's own write starts from what macOS stores, like System Settings: no registry agreement, no battery reading.
        let userApply = scoped && allowBelowCharge && !isQualifying
        let before = try await readNative(); observed = before
        // policyMatches needs a clean registry on AC; on battery power the registry is not evidence (see policyMatches).
        guard before.isFresh, userApply || before.policyMatches else {
            throw NativeChargeServiceError.readbackMismatch
        }
        if scoped {
            guard saved.hasPersistentScope(environment: environment), NativeChargeAdmission.validOfferedTargets(before.supportedTargets),
                  userApply || NativeChargeAdmission.isPersistent(before, target: before.configuration.target, optimizedCharging: saved.baseline.optimizedCharging),
                  // Validation pins OBC (its evidence is strict): a changed OBC stops the run before the next stage write;
                  // the final restore of the user's own limit still goes ahead (no proof is recorded then).
                  !isQualifying || saved.phase == .restoring || before.configuration.optimizedCharging == saved.baseline.optimizedCharging,
                  NativeChargeAdmission.isValidState(before.configuration), NativeChargeAdmission.isValidState(expected),
                  !permitDisabled100, !allowRestoredBaseline else { throw NativeChargeServiceError.readbackMismatch }
            if isQualifying {
                guard let baseline = qualificationBaseline,
                      baseline.configuration == saved.baseline, expected.target != before.configuration.target,
                      (saved.phase == .preparing && expected.target != saved.baseline.target)
                        || (saved.phase == .restoring && expected.target == saved.baseline.target)
                else { throw NativeChargeServiceError.unqualifiedTarget }
            } else if saved.phase != .restoring {
                guard admissionScope?.authorizedPersistentTargets.contains(expected.target) == true,
                      isAuthorizedPersistentState(before) else { throw NativeChargeServiceError.unqualifiedTarget }
            }
        }
        guard before.configuration.matchesManual(saved.lastVerified) else {
            try relinquish()
            // Changed in System Settings between the reads: that is the user's setting; nothing is written.
            if userApply { throw NativeChargeServiceError.changedElsewhere }
            message = "An external charge change was preserved before the next operation."
            throw NativeChargeServiceError.recoveryRequired
        }
        var percent: Int?
        if !userApply {
            let battery = await batteryProvider?()
            let fresh = battery?.fresh ?? batteryFresh
            let level = battery != nil ? battery!.percent : batteryPercent
            guard fresh, let level else { throw NativeChargeServiceError.staleBattery }
            percent = level
        }
        // A user's own limit may sit below the charge, as in System Settings; validation and restores keep the guard.
        if let percent, !allowBelowCharge || isQualifying {
            if expected.enabled && expected.target != before.configuration.target && percent > expected.target {
                throw NativeChargeServiceError.unsafeEnable
            }
            if expected.enabled && !before.configuration.enabled && percent > before.configuration.target {
                throw NativeChargeServiceError.unsafeEnable
            }
        }
        let recalledBaseline = allowRestoredBaseline && saved.phase == .restoring && !before.configuration.enabled
            && before.configuration.target == 100 && saved.baseline.enabled ? saved.baseline : nil
        if let recalledBaseline, let percent, percent > recalledBaseline.target {
            throw NativeChargeServiceError.unsafeEnable
        }
        // Write-ahead state includes even intermediate enable/disable operations.
        // A crash or error cannot make an unacknowledged mutation look untouched.
        journal?.expectedMutation = expected; journal?.hasWritten = true; try saveJournal()
        try await operation()
        transaction.mutation = .returnedAwaitingConfiguration(expected)
        let after: NativeChargeSnapshot
        if scoped {
            after = try await confirmScopedWrite(expected: expected, baseline: saved.baseline)
        } else {
            let value = try await readNative(); observed = value
            let baselineWasRecalled = recalledBaseline.map { value.configuration.matchesManual($0) && value.policyMatches } ?? false
            guard value.isFresh && (value.configuration.matchesManual(expected) || (permitDisabled100 && value.configuration.target == 100) || baselineWasRecalled) else {
                throw NativeChargeServiceError.readbackMismatch
            }
            after = value
        }
        // The setter's return and a fresh read of the requested configuration are separate proofs. A scoped write is also
        // confirmed against the registry (policyMatches) above; the fixture path verifies registration in its later read.
        transaction.mutation = .configurationConfirmed(after.configuration)
        journal?.lastVerified = after.configuration; journal?.expectedMutation = nil; try saveJournal()
    }

    /// A bounded readback of a scoped write: fresh, the requested configuration, a valid state and the policy confirmed
    /// (strict registry evidence while validating). A failed read is retried; a hung read (gate) means the outcome is
    /// unknown. No confirming read leaves the mutation awaiting its configuration (an indeterminate journal).
    private func confirmScopedWrite(expected: NativeChargeConfiguration, baseline: NativeChargeConfiguration) async throws -> NativeChargeSnapshot {
        for attempt in 0..<verificationAttempts {
            do {
                let value = try await readNative(); observed = value
                let policyConfirmed = isQualifying
                    ? NativeChargeAdmission.isPersistent(value, target: expected.target, optimizedCharging: baseline.optimizedCharging, strict: true)
                    : value.policyMatches
                if value.isFresh, value.configuration.matchesManual(expected), NativeChargeAdmission.isValidState(value.configuration), policyConfirmed {
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
            incompleteObservation = nil
            // Every successful fresh read is what macOS stores now (and discovers the interface), even when its policy
            // is not confirmed (a registry conflict): the surfaces show it, confirmation is separate.
            rememberNativeSetting(value)
            return value
        }
        catch {
            observed = nil
            incompleteObservation = nil
            if let failure = error as? NativeChargeReadFailure {
                // Discovery is independent of a usable current setting. Keep
                // offered targets visible without inferring enabled state,
                // admission, ownership or permission to dispatch a setter.
                knownTargets = failure.supportedTargets
                nativeSetting = nil
                incompleteObservation = failure
                message = failure.localizedDescription
            }
            throw error
        }
    }
    private func setNativeLimit(_ target: Int, transaction: Transaction) async throws {
        if let saved = journal, saved.version == 2 {
            guard saved.hasPersistentScope(environment: environment), NativeChargeAdmission.persistentTargets.contains(target),
                  saved.expectedMutation.map(NativeChargeAdmission.isValidState) == true, saved.expectedMutation?.target == target else { throw NativeChargeServiceError.unqualifiedTarget }
        }
        try await operationGate.call(purpose: .setLimit(target: target), onDispatch: {
            transaction.everDispatched = true
            if let expected = self.journal?.expectedMutation { transaction.mutation = .dispatched(expected) }
        }) { [client] in try await client.setLimit(target) }
    }
    private func setNativeEnabled(_ enabled: Bool, transaction: Transaction) async throws {
        guard journal?.version != 2, trustedFixtureAuthority, !isQualifying else { throw NativeChargeServiceError.unqualifiedTarget }
        try await operationGate.call(purpose: .setEnabled(enabled: enabled), onDispatch: {
            transaction.everDispatched = true
            if let expected = self.journal?.expectedMutation { transaction.mutation = .dispatched(expected) }
        }) { [client] in try await client.setEnabled(enabled) }
    }

    private func makeTransaction() -> Transaction {
        .init(journal: journal, bytes: try? Data(contentsOf: journalURL), recovery: recoveryRequired,
              review: reviewReason, pending: pendingTarget, restoration: restorationPending)
    }

    private func markJournalIntegrity() {
        // Only the legacy fixture session is blocked by it; a scoped session keeps the slider (the next apply or a settled
        // clear read retries closing it).
        if journal?.version == 1 || (journal == nil && trustedFixtureAuthority && !unreadableJournal) { recoveryRequired = true }
        reviewReason = .journalIntegrity; observed = nil
        message = "The native session journal could not be saved safely. The session needs review."
    }

    private func handleFailure(_ transaction: Transaction, failure: any Error) {
        // A fresh external change may already have relinquished this session.
        // Never recreate that session during logical rollback.
        guard journal?.sessionID == transaction.sessionID, journal != nil else { return }
        observed = nil
        if !transaction.everDispatched {
            journal = transaction.entryJournal
            pendingTarget = transaction.entryPending; restorationPending = transaction.entryRestoration
            recoveryRequired = transaction.entryRecovery; reviewReason = transaction.entryReview
            do {
                if let bytes = transaction.entryBytes {
                    try bytes.write(to: journalURL, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
                } else if transaction.entryJournal != nil {
                    // Losing the durable entry journal is itself a review issue.
                    throw NativeChargeServiceError.recoveryRequired
                } else if FileManager.default.fileExists(atPath: journalURL.path) {
                    try FileManager.default.removeItem(at: journalURL)
                }
                message = "The native read or preparation failed before any new setting was dispatched."
                // With no entry journal and nothing dispatched, macOS was not touched and no journal is left: this tap's
                // error only. A lost entry journal still needs review.
                if failure is JournalPersistenceFailure {
                    if transaction.entryJournal != nil { markJournalIntegrity() } else { message = failure.localizedDescription }
                }
            } catch { markJournalIntegrity() }
        } else if transaction.allDispatchedConfirmed, journal?.version == 2, journal?.qualification != true {
            // The configuration was read back: the user's own macOS setting (as after a confirmed apply). Nothing owed.
            do { try relinquish(); message = nil } catch { markJournalIntegrity() }
        } else if transaction.allDispatchedConfirmed {
            // Owned means a settings/restoration obligation, not current policy.
            // Keep the last *actual* confirmed configuration, including a partial
            // enable, rather than promoting the final requested target.
            journal?.phase = .owned
            // A confirmed replacement supersedes any earlier lower-target
            // request, even while independent policy confirmation is missing.
            // Restoration intent is separate and remains explicitly retained.
            pendingTarget = nil; journal?.plannedTarget = nil
            if case let .configurationConfirmed(configuration) = transaction.mutation {
                journal?.lastVerified = configuration; journal?.expectedMutation = nil
            }
            recoveryRequired = transaction.entryRecovery; reviewReason = transaction.entryReview
            do {
                try saveJournal()
                message = "The native setting was confirmed, but the active policy is currently unconfirmed. Refresh before applying another target."
                if failure is JournalPersistenceFailure { markJournalIntegrity() }
            } catch { markJournalIntegrity() }
        } else {
            // The outcome is unknown. A scoped session keeps the slider (status line only) and closes itself at the first
            // settled clear read; only the legacy fixture session is blocked for review.
            journal?.phase = .indeterminate; reviewReason = .mutationUnresolved
            if journal?.version != 2 { recoveryRequired = true }
            do {
                try saveJournal()
                message = journal?.version == 2 ? "macOS has not confirmed the last change yet."
                    : "A dispatched native setting lacks a confirmed outcome. The session needs review."
            } catch { markJournalIntegrity() }
        }
    }

    private func verify(target: Int, enabled: Bool?) async throws -> NativeChargeSnapshot {
        for attempt in 0..<verificationAttempts {
            let value = try await readNative(); observed = value
            if value.isFresh && value.configuration.target == target && (enabled.map { $0 == value.configuration.enabled } ?? true) && value.policyMatches {
                if let saved = journal, saved.version == 2 {
                    guard NativeChargeAdmission.isPersistent(value, target: target, optimizedCharging: saved.baseline.optimizedCharging, strict: isQualifying)
                    else { throw NativeChargeServiceError.readbackMismatch }
                }
                return value
            }
            if attempt + 1 < verificationAttempts { try await Task.sleep(for: verificationDelay) }
        }
        throw NativeChargeServiceError.readbackMismatch
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
    /// A session journal (any v2 phase or origin, or an unreadable file) only records that a write's outcome was unknown;
    /// nothing is owed to its baseline. The first settled, clear read closes it without a write: confirmed the way a write
    /// is (registry on AC, stored setting on battery), no conflicting rows, a valid state, file at least 60 s old. The value
    /// read does not matter (baseline, requested, a third value set in System Settings, a validation stage value).
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
        journal = nil; pendingTarget = nil; restorationPending = false; recoveryRequired = false; reviewReason = nil
    }
}
