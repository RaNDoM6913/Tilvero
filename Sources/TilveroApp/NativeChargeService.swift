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

    func hasPersistentScope(environment: String) -> Bool {
        guard version == 2, self.environment == environment,
              semanticContract == NativeChargeAdmission.semanticContract,
              persistentTargets == NativeChargeAdmission.persistentTargets,
              let baselineSnapshot, baselineSnapshot.configuration == baseline,
              NativeChargeAdmission.persistentTargets.contains(baseline.target),
              NativeChargeAdmission.isPersistent(baselineSnapshot, target: baseline.target, optimizedCharging: baseline.optimizedCharging),
              lastVerified.enabled, NativeChargeAdmission.persistentTargets.contains(lastVerified.target),
              lastVerified.optimizedCharging == baseline.optimizedCharging,
              plannedTarget.map(NativeChargeAdmission.persistentTargets.contains) ?? true,
              expectedMutation.map({ $0.enabled && NativeChargeAdmission.persistentTargets.contains($0.target)
                  && $0.optimizedCharging == baseline.optimizedCharging }) ?? true,
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
        case .sessionReview, .mutationUnresolved, .journalIntegrity, .restorationPending, .lowerTargetPending: true
        case .policyUnconfirmed: hasOwnership
        case .operationPending: pendingTarget != nil || restorationTarget != nil
        case .none: false
        }
    }
}

enum NativeChargeServiceError: Error, LocalizedError {
    case unavailable, busy, unsupportedTarget, unqualifiedTarget, staleBattery, recoveryRequired, readbackMismatch, unsafeEnable
    var errorDescription: String? {
        switch self {
        case .unavailable: "Native charging control has not completed its local validation."
        case .busy: "A native charging operation is still in progress."
        case .unsupportedTarget: "Choose a charge target offered by this Mac."
        case .unqualifiedTarget: "This charge target has not completed local validation. Only the verified persistent 80%, 85%, 90% and 95% targets are authorized."
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
        didSet { if let observed { rememberNativeSetting(observed) } }
    }
    /// The native preference can exist while macOS registers no active charging
    /// policy on battery. Keep discovery separate from independent confirmation.
    @Published private(set) var nativeSetting: NativeChargeSnapshot?
    @Published private(set) var incompleteObservation: NativeChargeReadFailure?
    var currentReportedTarget: Int? {
        if let setting = nativeSetting, setting.isFresh { return setting.configuration.target }
        guard let incompleteObservation, incompleteObservation.isFresh(at: Date()) else { return nil }
        return incompleteObservation.currentTarget
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
    /// Explicit injection is reserved for trusted fixture/Studio compositions.
    /// The production convenience initializer never supplies this blanket grant.
    private let trustedFixtureAuthority: Bool
    private var admissionScope: NativeChargeAdmission.Scope?
    private var qualificationBaseline: NativeChargeSnapshot?
    private let verificationAttempts: Int
    private let verificationDelay: Duration
    private let environment: String
    private var journal: NativeChargeJournal?
    private var journalInvalid = false
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
        let policy = observed.flatMap { $0.isFresh(at: date) && $0.policyMatches && !recoveryRequired
            && !operationGate.pending ? $0.configuration : nil }
        let attention: NativeChargePresentation.Attention
        if let reviewReason { attention = reviewReason }
        else if recoveryRequired || journalInvalid { attention = .sessionReview }
        else if operationGate.pending || isBusy || isQualifying { attention = .operationPending }
        else if restorationPending { attention = .restorationPending }
        else if pendingTarget != nil { attention = .lowerTargetPending }
        else if policy == nil { attention = .policyUnconfirmed }
        else { attention = .none }
        return .init(currentPreference: preference, activePolicy: policy, pendingPurpose: operationGate.pendingPurpose,
                     hasOwnership: hasOwnedSettings, pendingTarget: pendingTarget,
                     restorationTarget: restorationPending ? journal?.baseline.target : nil, attention: attention,
                     hasRecordedMutation: journal?.expectedMutation != nil,
                     hasSavedAction: journal.map { [.pendingTarget, .preparing, .restoring, .restorationPending].contains($0.phase) } ?? false)
    }

    var isMonitoringOnly: Bool { monitoringOnly }
    var hasOwnedSettings: Bool { journal?.hasWritten == true }
    var authorizedPersistentTargets: [Int] {
        guard !monitoringOnly else { return [] }
        return trustedFixtureAuthority ? acceptedTargets : admissionScope?.authorizedPersistentTargets ?? []
    }
    private func isAuthorizedPersistentState(_ value: NativeChargeSnapshot) -> Bool {
        guard let scope = admissionScope, scope.environment == environment,
              scope.authorizedPersistentTargets.contains(value.configuration.target) else { return false }
        return NativeChargeAdmission.isPersistent(value, target: value.configuration.target, optimizedCharging: scope.optimizedCharging)
    }
    var isAvailable: Bool {
        guard !operationGate.pending, admitted, !monitoringOnly, !journalInvalid,
              let observed, observed.isFresh, observed.policyMatches else { return false }
        return trustedFixtureAuthority || isAuthorizedPersistentState(observed)
    }
    var canApply: Bool { isAvailable && !isBusy && !isQualifying && !recoveryRequired && !restorationPending }
    func canApplyTarget(_ target: Int) -> Bool { canApply && acceptedTargets.contains(target) && authorizedPersistentTargets.contains(target) }
    /// Cached state readiness only. qualify() obtains its own fresh battery and
    /// native preflight before granting the two finite transitions.
    var canRequestQualification: Bool {
        guard !monitoringOnly, !isBusy, !operationGate.pending, !isQualifying,
              journal == nil, !journalInvalid, !recoveryRequired, !restorationPending, pendingTarget == nil,
              admissionURL != nil, environment != "unavailable", batteryProvider != nil,
              let value = observed, value.isFresh else { return false }
        return NativeChargeAdmission.persistentTargets.contains(value.configuration.target)
            && NativeChargeAdmission.isPersistent(value, target: value.configuration.target, optimizedCharging: value.configuration.optimizedCharging)
    }
    func needsApply(target: Int) -> Bool {
        guard canApplyTarget(target) else { return false }
        // An explicit lower pending intent still has a distinct cancellation path.
        if pendingTarget != nil { return requestedIntent != .ceiling(target) }
        return observed?.configuration.enabled != true || observed?.configuration.target != target
    }
    var canChargeToFullOnce: Bool { canApplyTarget(100) && fullOnceQualified && trustedFixtureAuthority }
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

    init(client: any NativeChargeTransport, journalURL: URL, admitted: Bool = false, admissionScope: NativeChargeAdmission.Scope? = nil, monitoringOnly: Bool = false,
         verificationAttempts: Int = 30, verificationDelay: Duration = .zero,
         environment: String = ProcessInfo.processInfo.operatingSystemVersionString,
         batteryProvider: (@Sendable () async -> ChargeObservation)? = nil, admissionURL: URL? = nil,
         operationTimeout: Duration = .seconds(15), fullOnceQualified: Bool = false) {
        operationGate = NativeChargeOperationGate(timeout: operationTimeout); self.fullOnceQualified = fullOnceQualified
        self.client = client; self.journalURL = journalURL; self.monitoringOnly = monitoringOnly
        trustedFixtureAuthority = admitted && !monitoringOnly
        self.admissionScope = !monitoringOnly && admissionScope?.environment == environment ? admissionScope : nil
        self.admitted = !monitoringOnly && (admitted || self.admissionScope != nil)
        self.batteryProvider = batteryProvider; self.admissionURL = admissionURL
        self.verificationAttempts = max(1, verificationAttempts); self.verificationDelay = verificationDelay; self.environment = environment
        if !monitoringOnly && FileManager.default.fileExists(atPath: journalURL.path) {
            do {
                let saved = try JSONDecoder().decode(NativeChargeJournal.self, from: Data(contentsOf: journalURL))
                let trustedLegacy = trustedFixtureAuthority && saved.version == 1 && saved.environment == environment
                    && (80...100).contains(saved.baseline.target) && (80...100).contains(saved.lastVerified.target)
                    && (saved.plannedTarget.map({ (80...100).contains($0) }) ?? true)
                guard trustedLegacy || saved.hasPersistentScope(environment: environment) else { throw NativeChargeServiceError.recoveryRequired }
                journal = saved; recoveryRequired = true; reviewReason = .sessionReview
                restorationPending = saved.phase == .restorationPending
                message = "A previous native charge session needs review. Saved intent was not reapplied."
            } catch {
                journalInvalid = true; recoveryRequired = true; reviewReason = .sessionReview
                message = "The saved native charge session cannot be read safely. It was preserved."
            }
        }
        operationGate.onTimeout = { [weak self] purpose in
            guard let self else { return }
            if purpose.isMutation, self.journal != nil {
                self.journal?.phase = .indeterminate; self.recoveryRequired = true
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
        self.init(client: PowerUIChargeClient(), journalURL: root.appendingPathComponent("native-charge-session.json"),
                  admissionScope: monitoring ? nil : NativeChargeAdmission.loadScope(from: admission, environment: environment), monitoringOnly: monitoring,
                  verificationAttempts: 30, verificationDelay: .seconds(2), environment: environment,
                  batteryProvider: { await reader.currentObservation() }, admissionURL: admission)
    }

    func qualify() async throws {
        guard !monitoringOnly, !isBusy, !operationGate.pending, !isQualifying, journal == nil, !journalInvalid,
              !recoveryRequired, !restorationPending, pendingTarget == nil,
              let admissionURL, environment != "unavailable", let batteryProvider else { throw NativeChargeServiceError.unavailable }
        isQualifying = true
        defer { isQualifying = false; qualificationBaseline = nil }
        let baseline = try await readNative(); observed = baseline
        let battery = await batteryProvider()
        guard baseline.isFresh, NativeChargeAdmission.persistentTargets.contains(baseline.configuration.target),
              NativeChargeAdmission.isPersistent(baseline, target: baseline.configuration.target, optimizedCharging: baseline.configuration.optimizedCharging) else {
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
            journal = makeScopedJournal(baseline: baseline, plannedTarget: stageTargets[0])
            transaction.sessionID = journal?.sessionID
            try saveJournal()
            var stages: [NativeChargeSnapshot] = []
            for (index, target) in stageTargets.enumerated() {
                if index > 0 { journal?.plannedTarget = target; journal?.phase = .preparing; try saveJournal() }
                try await mutate(transaction: transaction,
                                 expected: .init(enabled: true, target: target, optimizedCharging: baseline.configuration.optimizedCharging)) {
                    try await self.setNativeLimit(target, transaction: transaction)
                }
                let changed = try await verify(target: target, enabled: true)
                guard NativeChargeAdmission.isPersistent(changed, target: target, optimizedCharging: baseline.configuration.optimizedCharging),
                      changed.supportedTargets == baseline.supportedTargets else { throw NativeChargeServiceError.readbackMismatch }
                journal?.lastVerified = changed.configuration; journal?.phase = .owned; journal?.plannedTarget = nil
                try saveJournal()
                stages.append(changed)
            }
            stagesComplete = true
            let after = await batteryProvider()
            guard try await restoreInternal(batteryPercent: after.percent, batteryFresh: after.fresh), let restored = observed,
                  NativeChargeAdmission.isPersistent(restored, target: baseline.configuration.target, optimizedCharging: baseline.configuration.optimizedCharging),
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
            admissionScope = scope; admitted = true
            message = "Persistent 80%, 85%, 90% and 95% settings and restoration passed on this Mac. Other targets and physical cutoff remain unqualified."
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

    private func makeScopedJournal(baseline: NativeChargeSnapshot, plannedTarget: Int) -> NativeChargeJournal {
        var saved = NativeChargeJournal(sessionID: UUID(), environment: environment, baseline: baseline.configuration,
            lastVerified: baseline.configuration, plannedTarget: plannedTarget, phase: .preparing)
        saved.version = 2; saved.semanticContract = NativeChargeAdmission.semanticContract
        saved.persistentTargets = NativeChargeAdmission.persistentTargets; saved.baselineSnapshot = baseline
        return saved
    }

    func refresh() async {
        guard !isBusy, !isQualifying, !operationGate.pending else { return }
        isBusy = true; defer { isBusy = false }
        do {
            let value = try await readNative()
            rememberNativeSetting(value)
            guard value.isFresh && value.policyMatches else {
                observed = nil
                message = "The native policy readback is unavailable or inconsistent. The ownership journal was preserved."
                return
            }
            observed = value
            if !monitoringOnly, let journal, journal.version == 2,
               (!NativeChargeAdmission.isPersistent(value, target: value.configuration.target, optimizedCharging: journal.baseline.optimizedCharging)
                || !NativeChargeAdmission.persistentTargets.contains(value.configuration.target)
                || value.supportedTargets != journal.baselineSnapshot?.supportedTargets
                || (journal.expectedMutation == nil && value.configuration != journal.lastVerified)) {
                recoveryRequired = true
                message = "The current macOS state is outside the verified persistent session. Its recovery journal was preserved without a write."
                return
            }
            if !monitoringOnly, let journal, journal.version != 2, journal.phase != .preparing && journal.phase != .restoring && journal.phase != .indeterminate,
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
        if !trustedFixtureAuthority {
            guard admissionScope?.authorizedPersistentTargets.contains(target) == true else { throw NativeChargeServiceError.unqualifiedTarget }
            guard isAuthorizedPersistentState(current) else { throw NativeChargeServiceError.readbackMismatch }
        }
        if let journal, !(journal.version == 2 ? current.configuration == journal.lastVerified : current.configuration.matchesManual(journal.lastVerified)) {
            try relinquish(); throw NativeChargeServiceError.recoveryRequired
        }
        if current.configuration.enabled && current.configuration.target == target {
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
                } else { journal = makeScopedJournal(baseline: current, plannedTarget: target) }
            }
            transaction.sessionID = journal?.sessionID
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
            if !current.configuration.enabled {
                try await mutate(transaction: transaction, expected: .init(enabled: true, target: current.configuration.target, optimizedCharging: current.configuration.optimizedCharging)) {
                    try await self.setNativeEnabled(true, transaction: transaction)
                }
            }
            try await mutate(transaction: transaction, expected: .init(enabled: true, target: target, optimizedCharging: current.configuration.optimizedCharging), permitDisabled100: target == 100) {
                try await self.setNativeLimit(target, transaction: transaction)
            }
            let verified = try await verify(target: target, enabled: nil)
            journal?.lastVerified = verified.configuration; journal?.phase = .owned; journal?.plannedTarget = nil
            try saveJournal(); observed = verified; pendingTarget = nil
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
            guard !restoringFromDisabled100 || value.configuration == saved.baseline else { throw NativeChargeServiceError.readbackMismatch }
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
        if saved.hasWritten, current.configuration == saved.baseline,
           (saved.expectedMutation != nil || [.indeterminate, .preparing, .restoring].contains(saved.phase)) {
            recoveryRequired = true
            message = "An unconfirmed native operation may still take effect. The recovery journal was preserved; no follow-up write was started."
            return false
        }
        if current.configuration == saved.baseline {
            try relinquish(); message = "The verified persistent baseline is confirmed."; return true
        }
        guard current.configuration == saved.lastVerified || current.configuration == saved.expectedMutation else {
            throw NativeChargeServiceError.recoveryRequired
        }
        let battery = await batteryProvider?()
        let fresh = battery?.fresh ?? batteryFresh
        let percent = battery != nil ? battery!.percent : batteryPercent
        guard fresh, let percent, (0...100).contains(percent) else { throw NativeChargeServiceError.staleBattery }
        self.batteryPercent = percent; self.batteryFresh = true
        let transaction = makeTransaction()
        do {
            guard percent < saved.baseline.target else {
                journal?.phase = .restorationPending; restorationPending = true
                try saveJournal()
                message = "Restoring the persistent baseline is waiting for natural discharge."
                return false
            }
            journal?.phase = .restoring; journal?.lastVerified = current.configuration; try saveJournal()
            try await mutate(transaction: transaction, expected: saved.baseline) {
                try await self.setNativeLimit(saved.baseline.target, transaction: transaction)
            }
            let restored = try await verify(target: saved.baseline.target, enabled: true)
            guard restored.configuration == saved.baseline else { throw NativeChargeServiceError.readbackMismatch }
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
                        allowRestoredBaseline: Bool = false, operation: @MainActor () async throws -> Void) async throws {
        guard let saved = journal else { throw NativeChargeServiceError.recoveryRequired }
        let before = try await readNative(); observed = before
        guard before.isFresh, before.policyReadbackAvailable, before.policyMatches else {
            throw NativeChargeServiceError.readbackMismatch
        }
        let scoped = saved.version == 2
        if scoped {
            guard saved.hasPersistentScope(environment: environment), before.supportedTargets == saved.baselineSnapshot?.supportedTargets,
                  NativeChargeAdmission.isPersistent(before, target: before.configuration.target, optimizedCharging: saved.baseline.optimizedCharging),
                  NativeChargeAdmission.persistentTargets.contains(before.configuration.target), expected.enabled,
                  NativeChargeAdmission.persistentTargets.contains(expected.target), expected.optimizedCharging == saved.baseline.optimizedCharging,
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
        guard scoped ? before.configuration == saved.lastVerified : before.configuration.matchesManual(saved.lastVerified) else {
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
        let recalledBaseline = allowRestoredBaseline && saved.phase == .restoring && !before.configuration.enabled
            && before.configuration.target == 100 && saved.baseline.enabled ? saved.baseline : nil
        if let recalledBaseline, percent >= recalledBaseline.target {
            throw NativeChargeServiceError.unsafeEnable
        }
        // Write-ahead state includes even intermediate enable/disable operations.
        // A crash or error cannot make an unacknowledged mutation look untouched.
        journal?.expectedMutation = expected; journal?.hasWritten = true; try saveJournal()
        try await operation()
        transaction.mutation = .returnedAwaitingConfiguration(expected)
        let after = try await readNative(); observed = after
        let baselineWasRecalled = recalledBaseline.map { after.configuration == $0 && after.policyMatches } ?? false
        guard after.isFresh && (after.configuration.matchesManual(expected) || (permitDisabled100 && after.configuration.target == 100) || baselineWasRecalled) else {
            throw NativeChargeServiceError.readbackMismatch
        }
        if scoped {
            guard NativeChargeAdmission.isPersistent(after, target: expected.target, optimizedCharging: saved.baseline.optimizedCharging),
                  after.supportedTargets == saved.baselineSnapshot?.supportedTargets else { throw NativeChargeServiceError.readbackMismatch }
        }
        // Setter return and the first fresh matching configuration are separate
        // proofs. Registration is intentionally verified by the later policy read.
        transaction.mutation = .configurationConfirmed(after.configuration)
        journal?.lastVerified = after.configuration; journal?.expectedMutation = nil; try saveJournal()
    }

    private func readNative() async throws -> NativeChargeSnapshot {
        do {
            let value = try await operationGate.call(purpose: .read) { [client] in try await client.read() }
            if let previous = incompleteObservation, message == previous.localizedDescription { message = nil }
            incompleteObservation = nil
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
                  saved.expectedMutation?.enabled == true, saved.expectedMutation?.target == target else { throw NativeChargeServiceError.unqualifiedTarget }
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
        recoveryRequired = true; reviewReason = .journalIntegrity; observed = nil
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
                if failure is JournalPersistenceFailure { markJournalIntegrity() }
            } catch { markJournalIntegrity() }
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
            journal?.phase = .indeterminate; recoveryRequired = true; reviewReason = .mutationUnresolved
            do {
                try saveJournal()
                message = "A dispatched native setting lacks a confirmed outcome. The session needs review."
            } catch { markJournalIntegrity() }
        }
    }

    private func verify(target: Int, enabled: Bool?) async throws -> NativeChargeSnapshot {
        for attempt in 0..<verificationAttempts {
            let value = try await readNative(); observed = value
            if value.isFresh && value.configuration.target == target && (enabled.map { $0 == value.configuration.enabled } ?? true) && value.policyMatches {
                if let saved = journal, saved.version == 2 {
                    guard NativeChargeAdmission.isPersistent(value, target: target, optimizedCharging: saved.baseline.optimizedCharging),
                          value.supportedTargets == saved.baselineSnapshot?.supportedTargets else { throw NativeChargeServiceError.readbackMismatch }
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
    private func relinquish() throws {
        if FileManager.default.fileExists(atPath: journalURL.path) { try FileManager.default.removeItem(at: journalURL) }
        journal = nil; pendingTarget = nil; restorationPending = false; recoveryRequired = false; reviewReason = nil
    }
}
