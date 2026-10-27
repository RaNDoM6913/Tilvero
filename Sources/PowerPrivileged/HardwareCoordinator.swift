import Foundation
import PowerCore
import ChargeBackends
import FanBackends

public protocol PrivilegedHardware: Sendable {
    func capabilities() async -> [ControlCapability]
    func qualify(_ resource: OwnedResource) async throws
    func chargeObservation() async throws -> ChargeObservation
    func fanObservation() async throws -> FanObservation
    func readFanRegister(_ register: FanRegister) async throws -> FanRegisterValue
    func writeFanRegister(_ register: FanRegister, value: FanRegisterValue) async throws
    func read(_ resource: OwnedResource) async throws -> HardwareSetting
    func write(_ setting: HardwareSetting, resource: OwnedResource) async throws
}

public extension PrivilegedHardware {
    func fanObservation() async throws -> FanObservation { throw PolicyError.unavailable }
    func readFanRegister(_ register: FanRegister) async throws -> FanRegisterValue {
        let observation = try await fanObservation()
        switch register {
        case let .target(id): guard let rpm = observation.targetRPM[id] else { throw PolicyError.unavailable }; return .rpm(rpm)
        case let .automatic(id): guard let auto = observation.autoMode[id] else { throw PolicyError.unavailable }; return .automatic(auto)
        }
    }
    func writeFanRegister(_ register: FanRegister, value: FanRegisterValue) async throws { throw PolicyError.unavailable }
}

public actor SystemPrivilegedHardware: PrivilegedHardware {
    private let charge = NativeChargeBackend()
    private let energy = EnergyModeBackend()
    private let fans = SMCFanBackend()
    public init() {}
    public func capabilities() async -> [ControlCapability] {
        let native = await charge.discover(), fan = await fans.discover()
        return [native.capability, fan.capability, ControlCapability(backend: "pmset-lowpowermode", readiness: .unverified,
            reason: "Separate battery/adapter settings can be observed. Signed helper and deliberately verified apply/readback/restoration are required for writes.")]
    }
    public func qualify(_ resource: OwnedResource) throws { try HardwareQualification.current.require(resource) }
    public func chargeObservation() async throws -> ChargeObservation { await charge.currentObservation() }
    public func fanObservation() async throws -> FanObservation {
        let discovery = await fans.discover()
        guard !discovery.fans.isEmpty else { throw PolicyError.unavailable }
        return FanObservation(descriptors: discovery.fans, actualRPM: discovery.observedRPM, targetRPM: discovery.targetRPM,
            autoMode: discovery.autoMode, sensorTemperature: nil, sensorFresh: false,
            sampledContinuousSeconds: HelperClock.continuousSeconds())
    }
    public func writeFanRegister(_ register: FanRegister, value: FanRegisterValue) async throws { try await fans.writeRegister(register, value: value) }
    public func read(_ resource: OwnedResource) async throws -> HardwareSetting {
        switch resource {
        case .charging: return try await charge.readOriginal()
        case .batteryEnergyMode, .adapterEnergyMode:
            let source: PowerProfileSource = resource == .batteryEnergyMode ? .battery : .adapter
            guard let mode = try await energy.read()[source] else { throw PolicyError.unavailable }; return .energy(mode)
        case .fans:
            let discovered = await fans.discover()
            guard !discovered.fans.isEmpty, discovered.autoMode.count == discovered.fans.count else { throw PolicyError.unavailable }
            if discovered.autoMode.values.allSatisfy({ $0 }) { return .fanAuto }
            guard discovered.autoMode.values.allSatisfy({ !$0 }), discovered.targetRPM.count == discovered.fans.count else { throw PolicyError.readbackMismatch }
            return .fanRPM(discovered.targetRPM)
        }
    }
    public func write(_ setting: HardwareSetting, resource: OwnedResource) async throws {
        switch (resource, setting) {
        case let (.charging, .nativeCharge(feature, limit)):
            if feature == 1, let limit { try await charge.apply(target: limit) } else { try await charge.restore(setting) }
        case let (.batteryEnergyMode, .energy(mode)): try await energy.apply(source: .battery, mode: mode)
        case let (.adapterEnergyMode, .energy(mode)): try await energy.apply(source: .adapter, mode: mode)
        case let (.fans, .fanRPM(values)): try await fans.setRPM(values)
        case (.fans, .fanAuto): try await fans.restoreAuto()
        default: throw PolicyError.invalidPolicy
        }
    }
}

/// Serialized controller. The cross-process lock is held from baseline through readback/commit.
public actor PrivilegedController {
    private let hardware: any PrivilegedHardware
    private let journal: SecureJournal
    private let bootID: String
    private var busy = false
    private var validators: [UUID: RequestValidator] = [:]
    private var sessionEpochs: [UUID: UUID] = [:]
    private var fanEngine: FanPolicyEngine?
    private var fanContext: (envelope: HelperEnvelope, peer: PeerSession, epoch: UUID)?
    private var pendingFanReadback: (effect: FanEffect, deadline: Double)?
    private var fanLeaseDeadline: Double?
    private var sleepRequested = false
    public init(hardware: any PrivilegedHardware, journal: SecureJournal, bootID: String = HelperClock.bootID()) {
        self.hardware = hardware; self.journal = journal; self.bootID = bootID
    }
    public func openSession(peer: PeerSession, version: Int, activeUserID: UInt32?) throws -> HelperReply {
        guard version == HelperEnvelope.protocolVersion else { throw PrivilegeError.incompatibleProtocol }
        guard peer.userID >= 500, activeUserID == peer.userID else { throw PrivilegeError.wrongUser }
        guard validators.count < 16 else { throw PrivilegeError.busy }
        let lock = try journal.acquireLock()
        let epoch = try journal.authorityEpoch(lock: lock)
        let token = UUID(); validators[peer.connectionID] = RequestValidator(sessionToken: token, peer: peer)
        sessionEpochs[peer.connectionID] = epoch
        return HelperReply(accepted: true, sessionToken: token)
    }
    public func disconnect(peer: PeerSession) { validators.removeValue(forKey: peer.connectionID); sessionEpochs.removeValue(forKey: peer.connectionID) }
    public func perform(_ data: Data, peer: PeerSession, activeUserID: UInt32?, now: Double = HelperClock.continuousSeconds()) async throws -> HelperReply {
        guard !busy else { throw PrivilegeError.busy }
        guard var validator = validators[peer.connectionID] else { throw PrivilegeError.wrongSession }
        let envelope = try validator.validate(data, peer: peer, activeUserID: activeUserID)
        validators[peer.connectionID] = validator
        busy = true; defer { busy = false }
        if envelope.command == .readState { return try await readState(generation: envelope.generation, now: now) }
        let lock = try journal.acquireLock()
        let authorityEpoch = try journal.authorityEpoch(lock: lock)
        guard authorityEpoch == sessionEpochs[peer.connectionID] else { throw PrivilegeError.recoveryRequired }
        var record = try journal.read(lock: lock)
        if let context = fanContext {
            if context.epoch != authorityEpoch {
                // The guardian already assumed recovery. Discard only the old
                // in-memory policy; its durable hardware evidence remains intact.
                fanContext = nil; fanEngine = nil; pendingFanReadback = nil; fanLeaseDeadline = nil
            } else {
                guard context.envelope.sessionToken == envelope.sessionToken else { throw PrivilegeError.recoveryRequired }
            }
        }
        if let existing = record, existing.ownerRevoked, existing.entries.isEmpty, existing.ownerToken != envelope.sessionToken {
            // Only a newly authenticated session may acquire after guardian takeover.
            record = nil
        } else if let existing = record {
            guard !existing.ownerRevoked, existing.ownerToken == envelope.sessionToken, existing.bootID == bootID,
                  existing.generation <= envelope.generation, existing.leaseDeadline > now else { throw PrivilegeError.recoveryRequired }
        }
        if envelope.command == .heartbeat {
            if record != nil { record!.heartbeat = now; record!.leaseDeadline = now + 15; try journal.write(record!, lock: lock) }
            if var engine = fanEngine, engine.state.requested != .systemAuto {
                try engine.renewLease(now: now); fanEngine = engine
                fanLeaseDeadline = now + 15
            }
            if fanContext != nil { fanContext = (envelope, peer, authorityEpoch) }
            return HelperReply(accepted: true, generation: envelope.generation, ownedResources: record.map { Array($0.entries.keys) } ?? [], recoveryRequired: record?.ownerRevoked ?? false, fanPolicyState: fanEngine?.state, registrationOwnerUserID: record?.ownerUserID)
        }
        switch envelope.command {
        case .restoreAll:
            try await restore(record: &record, resources: OwnedResource.allCases, lock: lock)
            fanContext = nil; pendingFanReadback = nil; fanEngine = nil
        case .releaseCharge: try await restore(record: &record, resources: [.charging], lock: lock)
        case .releaseFans:
            try await restore(record: &record, resources: [.fans], lock: lock)
            fanContext = nil; pendingFanReadback = nil; fanEngine = nil
        case let .applyCharge(target): try await apply(.nativeCharge(featureState: 1, limit: target), resource: .charging, envelope: envelope, peer: peer, now: now, record: &record, lock: lock)
        case let .setEnergyMode(source, mode): try await apply(.energy(mode), resource: source == .battery ? .batteryEnergyMode : .adapterEnergyMode, envelope: envelope, peer: peer, now: now, record: &record, lock: lock)
        case let .setFanRPM(values): try await setFanPolicy(.manual(values), envelope: envelope, peer: peer, now: now, record: &record, lock: lock)
        case let .setFanPolicy(policy): try await setFanPolicy(policy, envelope: envelope, peer: peer, now: now, record: &record, lock: lock)
        case .heartbeat, .readState: break
        }
        var reply = await makeReply(generation: envelope.generation, record: record, now: now)
        reply.configurationVerified = pendingFanReadback == nil && fanEngine?.state.phase != .acquiring
        return reply
    }

    public func readState(generation: UInt64 = 0, now: Double = HelperClock.continuousSeconds()) async throws -> HelperReply {
        let lock = try journal.acquireLock(), record = try journal.read(lock: lock)
        let reply = await makeReply(generation: generation, record: record, now: now)
        withExtendedLifetime(lock) {}; return reply
    }
    private func makeReply(generation: UInt64, record: OwnershipJournal?, now: Double) async -> HelperReply {
        var settings: [OwnedResource: HardwareSetting] = [:]
        for resource in OwnedResource.allCases { if let setting = try? await hardware.read(resource) { settings[resource] = setting } }
        let charge = try? await hardware.chargeObservation(), fan = try? await hardware.fanObservation()
        let resources = record.map { Array($0.entries.keys).sorted { $0.rawValue < $1.rawValue } } ?? []
        let recovery = record.map { journal in
            !journal.entries.isEmpty && (journal.ownerRevoked || journal.leaseDeadline <= now || journal.entries.values.contains { $0.phase == .unresolved || $0.phase == .recovering })
        } ?? false
        return HelperReply(accepted: true, generation: generation, capabilities: await hardware.capabilities(), observedSettings: settings,
            chargeObservation: charge, fanObservation: fan, ownedResources: resources, recoveryRequired: recovery,
            fanPolicyState: fanEngine?.state, registrationOwnerUserID: resources.isEmpty ? nil : record?.ownerUserID)
    }

    private func setFanPolicy(_ policy: FanPolicy, envelope: HelperEnvelope, peer: PeerSession, now: Double, record: inout OwnershipJournal?, lock: JournalLock) async throws {
        if policy == .systemAuto {
            try await restore(record: &record, resources: [.fans], lock: lock)
            fanEngine = nil; fanContext = nil; pendingFanReadback = nil; return
        }
        try await hardware.qualify(.fans)
        let observation = try await hardware.fanObservation()
        try validateFanObservation(observation, now: now)
        if case .curve = policy {
            guard observation.sensorFresh, observation.sensorTemperature?.isFinite == true else { throw ControlUnavailableError(reason: "No fresh hardware-qualified controlling temperature sensor is available.") }
        }
        if fanEngine == nil { fanEngine = FanPolicyEngine(fans: observation.descriptors) }
        guard fanEngine?.fans == observation.descriptors else { throw PolicyError.invalidContract }
        var engine = fanEngine!
        let effects = try engine.submit(policy, now: now)
        guard let epoch = sessionEpochs[peer.connectionID] else { throw PrivilegeError.wrongSession }
        fanEngine = engine; fanContext = (envelope, peer, epoch); pendingFanReadback = nil
        fanLeaseDeadline = now + 15
        do {
            for effect in effects { try await executeFanEffect(effect, envelope: envelope, peer: peer, now: now, record: &record, lock: lock) }
        } catch {
            fanEngine?.markRecoveryRequired(reason: "Fan transition failed; journaled per-fan recovery is required.")
            throw error
        }
    }

    /// Invoked by a helper-owned periodic task, independently of GUI refresh or UI task scheduling.
    public func tickFanPolicy(now: Double = HelperClock.continuousSeconds(), activeUserID: UInt32? = HelperClock.activeConsoleUserID(), sleeping: Bool = false) async {
        guard !busy, let context = fanContext, var engine = fanEngine else { return }
        busy = true; defer { busy = false }
        do {
            let lock = try journal.acquireLock()
            guard try journal.authorityEpoch(lock: lock) == context.epoch else {
                engine.markRecoveryRequired(reason: "The authenticated control session was revoked.")
                fanEngine = engine; fanContext = nil; pendingFanReadback = nil; return
            }
            var record = try journal.read(lock: lock)
            if let existing = record, existing.ownerRevoked || existing.ownerToken != context.envelope.sessionToken || existing.bootID != bootID {
                engine.markRecoveryRequired(reason: "Guardian ownership takeover revoked this controller generation.")
                fanEngine = engine; fanContext = nil; pendingFanReadback = nil; return
            }
            let observation = try? await hardware.fanObservation()
            let validObservation = observation.map { (try? validateFanObservation($0, now: now)) != nil } ?? false
            let lostAuthority = activeUserID != context.peer.userID || record.map({ $0.leaseDeadline <= now }) ?? false
            var safetyReason: String?
            if sleeping || sleepRequested || observation?.sleeping == true { safetyReason = "Sleep entry releases fan ownership." }
            else if lostAuthority { safetyReason = "The UI lease or active user authority expired." }
            else if !validObservation { safetyReason = "Fan observation is stale, missing or incomplete." }
            if let observation, validObservation {
                if pendingFanReadback != nil {
                    let pending = pendingFanReadback!
                    if case let .setRPM(targets, _) = pending.effect {
                        let configured = targets.allSatisfy { observation.targetRPM[$0.key] == $0.value && observation.autoMode[$0.key] == false }
                        if !configured { safetyReason = "Fan mode or target diverged from the owned configuration." }
                        else if targets.allSatisfy({ item in observation.actualRPM[item.key].map { abs($0 - item.value) <= 250 } == true }) {
                            try engine.acknowledge(pending.effect, observedRPM: observation.actualRPM, auto: false)
                            fanEngine = engine; pendingFanReadback = nil
                        } else if now >= pending.deadline { safetyReason = "Actual fan RPM did not settle within the bounded observation window." }
                    }
                } else if engine.state.phase == .managed {
                    let coherent = engine.state.appliedRPM.allSatisfy { item in
                        observation.targetRPM[item.key] == item.value && observation.autoMode[item.key] == false && observation.actualRPM[item.key].map { abs($0 - item.value) <= 250 } == true
                    }
                    if !coherent { safetyReason = "Observed mode, target or RPM diverged; fan ownership is releasing." }
                }
            }
            let effects: [FanEffect]
            if let safetyReason { effects = engine.release(reason: safetyReason) }
            else { effects = engine.tick(now: now, sensorTemperature: observation?.sensorTemperature, sensorFresh: observation?.sensorFresh ?? false) }
            fanEngine = engine
            for effect in effects { try await executeFanEffect(effect, envelope: context.envelope, peer: context.peer, now: now, record: &record, lock: lock, renewOwnershipLease: false) }
        } catch PrivilegeError.locked {
            // An active controller/guardian holds the hardware lock; retry on the next bounded tick.
        } catch {
            fanEngine?.markRecoveryRequired(reason: "Per-fan restoration remains unresolved: \(error)")
            fanContext = nil; pendingFanReadback = nil
        }
    }
    public func prepareForSleep() async {
        sleepRequested = true
        for _ in 0..<50 {
            if !busy { await tickFanPolicy(sleeping: true); return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Preserve the journal for guardian/startup recovery if an operation cannot be interrupted in time.
    }
    public func didWake() { sleepRequested = false }
    private func validateFanObservation(_ observation: FanObservation, now: Double) throws {
        guard observation.isFresh(now: now), !observation.descriptors.isEmpty, Set(observation.descriptors.map(\.id)).count == observation.descriptors.count,
              observation.descriptors.allSatisfy({ fan in
                  fan.minimumRPM > 0 && fan.maximumRPM > fan.minimumRPM && observation.actualRPM[fan.id].map({ (0...20_000).contains($0) }) == true &&
                  observation.targetRPM[fan.id].map({ (0...20_000).contains($0) }) == true && observation.autoMode[fan.id] != nil
              }) else { throw PolicyError.unavailable }
    }
    private func executeFanEffect(_ effect: FanEffect, envelope: HelperEnvelope, peer: PeerSession, now: Double, record: inout OwnershipJournal?, lock: JournalLock, renewOwnershipLease: Bool = true) async throws {
        switch effect {
        case let .setRPM(targets, _):
            try await applyFanTargets(targets, envelope: envelope, peer: peer, now: now, record: &record, lock: lock, renewOwnershipLease: renewOwnershipLease)
            let observation = try await hardware.fanObservation()
            try validateFanObservation(observation, now: now)
            if targets.allSatisfy({ item in observation.actualRPM[item.key].map { abs($0 - item.value) <= 250 } == true && observation.autoMode[item.key] == false }) {
                try fanEngine?.acknowledge(effect, observedRPM: observation.actualRPM, auto: false)
                pendingFanReadback = nil
            } else { pendingFanReadback = (effect, now + 5) }
        case .systemAuto:
            try await restore(record: &record, resources: [.fans], lock: lock)
            let observation = try await hardware.fanObservation()
            try validateFanObservation(observation, now: now)
            guard observation.autoMode.values.allSatisfy({ $0 }) else { throw PolicyError.readbackMismatch }
            try fanEngine?.acknowledge(effect, observedRPM: observation.actualRPM, auto: true)
            pendingFanReadback = nil; fanContext = nil
        }
    }

    private func applyFanTargets(_ targets: [String: Int], envelope: HelperEnvelope, peer: PeerSession, now: Double, record: inout OwnershipJournal?, lock: JournalLock, renewOwnershipLease: Bool) async throws {
        try await hardware.qualify(.fans)
        let observation = try await hardware.fanObservation(); try validateFanObservation(observation, now: now)
        guard targets.count == observation.descriptors.count, observation.descriptors.allSatisfy({ fan in targets[fan.id].map(fan.accepts) == true }) else { throw PolicyError.invalidPolicy }
        if record == nil { record = OwnershipJournal(bootID: bootID, generation: envelope.generation, ownerToken: envelope.sessionToken, ownerUserID: peer.userID, heartbeat: now, leaseDeadline: min(now + 15, fanLeaseDeadline ?? now + 15)) }
        var entry = record!.entries[.fans] ?? JournalEntry(original: .fanAuto, intended: .fanRPM(targets))
        if entry.fanOriginals.isEmpty {
            guard observation.autoMode.values.allSatisfy({ $0 }) else { throw ControlUnavailableError(reason: "Another controller owns manual fan settings.") }
            for fan in observation.descriptors { entry.fanOriginals[fan.id] = FanOriginalState(targetRPM: observation.targetRPM[fan.id]!, automatic: true) }
        }
        guard entry.phase != .unresolved, entry.phase != .recovering else { throw PrivilegeError.recoveryRequired }
        entry.intended = .fanRPM(targets); entry.phase = .prepared
        if renewOwnershipLease { record!.heartbeat = now; record!.leaseDeadline = now + 15 }
        record!.generation = max(record!.generation, envelope.generation); record!.entries[.fans] = entry
        try journal.write(record!, lock: lock)
        do {
            for fanID in targets.keys.sorted() {
                guard let original = entry.fanOriginals[fanID], let rpm = targets[fanID] else { throw PolicyError.invalidContract }
                let operations: [(FanRegister, FanRegisterValue, FanRegisterValue)] = [(.target(fanID: fanID), .rpm(original.targetRPM), .rpm(rpm)), (.automatic(fanID: fanID), .automatic(original.automatic), .automatic(false))]
                for (register, baseline, intended) in operations {
                    let current = try await hardware.readFanRegister(register)
                    let old = entry.fanSteps.first(where: { $0.register == register })
                    guard current == baseline || current == old?.applied || current == old?.intended else { throw ControlUnavailableError(reason: "External fan register change detected; ownership yielded.") }
                    var step = FanJournalStep(register: register, original: baseline, intended: intended, previous: current)
                    let index: Int
                    if let existing = entry.fanSteps.firstIndex(where: { $0.register == register }) { index = existing; entry.fanSteps[index] = step }
                    else { index = entry.fanSteps.count; entry.fanSteps.append(step) }
                    record!.entries[.fans] = entry; try journal.write(record!, lock: lock)
                    if current != intended { try await hardware.writeFanRegister(register, value: intended) }
                    let actual = try await hardware.readFanRegister(register)
                    guard actual == intended else { throw PolicyError.readbackMismatch }
                    step.applied = actual; step.phase = .applied; entry.fanSteps[index] = step
                    record!.entries[.fans] = entry; try journal.write(record!, lock: lock)
                }
            }
            entry.applied = .fanRPM(targets); entry.phase = .applied; record!.entries[.fans] = entry; try journal.write(record!, lock: lock)
        } catch {
            entry.phase = .unresolved; entry.failure = String(String(describing: error).prefix(512))
            record!.entries[.fans] = entry; try journal.write(record!, lock: lock); throw error
        }
    }
    private func apply(_ target: HardwareSetting, resource: OwnedResource, envelope: HelperEnvelope, peer: PeerSession, now: Double, record: inout OwnershipJournal?, lock: JournalLock) async throws {
        try await hardware.qualify(resource)
        if resource == .charging, case let .nativeCharge(feature, limit) = target, feature == 1, let limit, limit < 100 {
            let observation = try await hardware.chargeObservation()
            guard observation.fresh, let percent = observation.percent, percent <= limit else {
                throw ControlUnavailableError(reason: "A lower native target remains pending until fresh natural discharge reaches it; the helper will not conceal active drain.")
            }
        }
        let current = try await hardware.read(resource)
        if resource == .fans, record?.entries[.fans] == nil, current != .fanAuto { throw ControlUnavailableError(reason: "Another controller owns manual fan settings.") }
        if let entry = record?.entries[resource], let applied = entry.applied, applied != current { throw ControlUnavailableError(reason: "External settings changed; restore/reconcile ownership explicitly before retrying.") }
        if record == nil { record = OwnershipJournal(bootID: bootID, generation: envelope.generation, ownerToken: envelope.sessionToken, ownerUserID: peer.userID, heartbeat: now, leaseDeadline: now + 15) }
        var entry = record!.entries[resource] ?? JournalEntry(original: current, intended: target)
        entry.intended = target; entry.phase = .prepared
        record!.generation = envelope.generation; record!.heartbeat = now; record!.leaseDeadline = now + 15; record!.entries[resource] = entry
        try journal.write(record!, lock: lock)
        do {
            try await hardware.write(target, resource: resource)
            let actual = try await hardware.read(resource)
            guard actual == target else { throw PolicyError.readbackMismatch }
            entry.applied = actual; entry.phase = .applied; record!.entries[resource] = entry
            try journal.write(record!, lock: lock)
        } catch {
            entry.phase = .unresolved; entry.failure = String(String(describing: error).prefix(512)); record!.entries[resource] = entry
            try journal.write(record!, lock: lock)
            throw error
        }
    }
    private func restore(record: inout OwnershipJournal?, resources: [OwnedResource], lock: JournalLock) async throws {
        guard record != nil else { return }
        var failed = false
        for resource in resources {
            guard var entry = record!.entries[resource] else { continue }
            do {
                if resource == .fans, !entry.fanSteps.isEmpty {
                    var detailed = record!
                    do { try await FanJournalRecovery.restore(hardware: hardware, journal: journal, record: &detailed, lock: lock) }
                    catch { record = detailed; throw error }
                    record = detailed; record!.entries.removeValue(forKey: resource); try journal.write(record!, lock: lock)
                    continue
                }
                let current = try await hardware.read(resource)
                guard current == entry.applied || current == entry.intended || current == entry.original else {
                    // Yield to an external controller. Do not overwrite its setting or erase unresolved evidence.
                    throw ControlUnavailableError(reason: "An external setting differs from journaled ownership; automatic restoration yielded.")
                }
                entry.phase = .recovering; record!.entries[resource] = entry; try journal.write(record!, lock: lock)
                if current != entry.original { try await hardware.write(entry.original, resource: resource) }
                guard try await hardware.read(resource) == entry.original else { throw PolicyError.readbackMismatch }
                record!.entries.removeValue(forKey: resource); try journal.write(record!, lock: lock)
            } catch {
                entry = record!.entries[resource] ?? entry
                failed = true; entry.phase = .unresolved; entry.failure = String(String(describing: error).prefix(512)); entry.recoveryAttempts += 1
                record!.entries[resource] = entry; try journal.write(record!, lock: lock)
            }
        }
        if record!.entries.isEmpty { try journal.removeVerifiedEmpty(lock: lock); record = nil }
        if failed { throw PrivilegeError.recoveryRequired }
    }
}

/// Runs in a separate launchd process. It expires controller generations before bounded journal-only recovery.
public actor RecoveryGuardian {
    private let hardware: any PrivilegedHardware
    private let journal: SecureJournal
    private let bootID: String
    public init(hardware: any PrivilegedHardware, journal: SecureJournal, bootID: String = HelperClock.bootID()) { self.hardware = hardware; self.journal = journal; self.bootID = bootID }
    @discardableResult public func recover(now: Double = HelperClock.continuousSeconds(), startup: Bool = false, activeUserID: UInt32? = HelperClock.activeConsoleUserID()) async throws -> Bool {
        let lock = try journal.acquireLock()
        guard var record = try journal.read(lock: lock) else { return true }
        if record.ownerRevoked && record.entries.isEmpty { return true }
        guard startup || record.bootID != bootID || record.leaseDeadline <= now || activeUserID != record.ownerUserID else { return false }
        guard record.generation < UInt64.max - 1 else { throw PrivilegeError.corruptJournal }
        if !record.ownerRevoked { try journal.revokeAuthority(lock: lock) }
        record.generation += 1; record.leaseDeadline = 0; record.ownerRevoked = true
        for resource in record.entries.keys { record.entries[resource]?.phase = .recovering }
        try journal.write(record, lock: lock)
        var failed = false
        for resource in OwnedResource.allCases {
            guard var entry = record.entries[resource] else { continue }
            guard entry.recoveryAttempts < 3 else { failed = true; continue }
            do {
                if resource == .fans, !entry.fanSteps.isEmpty {
                    try await FanJournalRecovery.restore(hardware: hardware, journal: journal, record: &record, lock: lock)
                    record.entries.removeValue(forKey: resource); try journal.write(record, lock: lock)
                    continue
                }
                let current = try await hardware.read(resource)
                guard current == entry.original || current == entry.applied || current == entry.intended else { throw PrivilegeError.recoveryRequired }
                if current != entry.original { try await hardware.write(entry.original, resource: resource) }
                guard try await hardware.read(resource) == entry.original else { throw PolicyError.readbackMismatch }
                record.entries.removeValue(forKey: resource)
            } catch {
                entry = record.entries[resource] ?? entry
                failed = true; entry.recoveryAttempts += 1; entry.phase = .unresolved
                entry.failure = String(String(describing: error).prefix(512)); record.entries[resource] = entry
            }
            try journal.write(record, lock: lock)
        }
        // Retain an empty revocation tombstone: deleting it would let a resumed stale controller reacquire.
        if record.entries.isEmpty { try journal.write(record, lock: lock) }
        if failed { throw PrivilegeError.recoveryRequired }
        return true
    }
}
