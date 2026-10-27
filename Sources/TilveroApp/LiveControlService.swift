import Foundation
import Combine
import PowerCore
import PowerPrivileged
import ChargeBackends
import FanBackends

/// The app can replace its transport in fixture tests; production always constructs
/// HelperClient, whose immutable signing requirements are checked in both directions.
protocol LiveHelperTransport: Sendable {
    func openSession() async throws -> HelperReply
    func submit(_ command: HelperCommand) async throws -> HelperReply
    func invalidate() async
}
extension HelperClient: LiveHelperTransport {}

@MainActor protocol LiveHelperRegistrationDriving: AnyObject {
    var state: HelperInstallationState { get }
    func register() async throws
    func unregister(afterVerifiedRestoration: Bool) async throws
}

private final class SignedHelperRegistration: LiveHelperRegistrationDriving {
    private let service = HelperRegistration()
    private let trust: HelperTrustConfiguration?
    init(trust: HelperTrustConfiguration?) { self.trust = trust }
    var state: HelperInstallationState { service.state }
    func register() async throws {
        guard let trust else { throw PrivilegeError.missingTrust }
        try await service.register(trust: trust)
    }
    func unregister(afterVerifiedRestoration verified: Bool) async throws {
        guard let trust else { throw PrivilegeError.missingTrust }
        try trust.verifyCurrentProcess(helper: false)
        try await service.unregister(afterVerifiedRestoration: verified)
    }
}

struct LiveControlDiscovery: Sendable {
    let capabilities: [ControlCapability]
    let fanObservation: FanObservation?
    let loweringBehavior: LoweringBehavior
    init(capabilities: [ControlCapability], fanObservation: FanObservation? = nil, loweringBehavior: LoweringBehavior = .unknown) {
        self.capabilities = capabilities; self.fanObservation = fanObservation; self.loweringBehavior = loweringBehavior
    }
    static func readOnly() async -> Self {
        async let nativeRead = NativeChargeBackend().discover()
        async let fanRead = SMCFanBackend().discover()
        let (native, fans) = await (nativeRead, fanRead)
        return Self(capabilities: [native.capability, fans.capability,
            ControlCapability(backend: "pmset-lowpowermode", readiness: .unverified,
                reason: "Separate battery and adapter modes require signed-helper apply/readback/restoration qualification.")],
            fanObservation: fans.capability.readiness == .unknown ? nil : FanObservation(descriptors: fans.fans,
                actualRPM: fans.observedRPM, targetRPM: fans.targetRPM, autoMode: fans.autoMode,
                sampledContinuousSeconds: HelperClock.continuousSeconds()))
    }
}

enum LiveControlError: Error, LocalizedError, Equatable {
    case unavailable, busy, readbackMismatch, recoveryRequired, notQualified
    var errorDescription: String? {
        switch self {
        case .unavailable: "The trusted helper is unavailable. Monitoring continues without control."
        case .busy: "A helper operation is already in progress."
        case .readbackMismatch: "The requested setting was not independently confirmed. Recovery may be required."
        case .recoveryRequired: "Owned settings have not been verified as restored. Keep the app/helper installed for recovery."
        case .notQualified: "This control is not qualified for the current hardware and trusted signed build."
        }
    }
}

/// Live control facade. Requested intent is persisted independently of actual
/// settings. A relaunch never converts a saved intent into an automatic write.
@MainActor final class LiveControlService: ObservableObject {
    @Published private(set) var chargeState = ChargePolicyState()
    @Published private(set) var fanState = FanPolicyState()
    @Published private(set) var fanObservation: FanObservation?
    @Published private(set) var capabilities: [ControlCapability] = []
    @Published private(set) var registrationState: HelperInstallationState = .unavailable
    @Published private(set) var message: String?
    @Published private(set) var isBusy = false
    @Published private(set) var requestedIntent: ChargeIntent?
    @Published private(set) var ownedResources: [OwnedResource] = []
    @Published private(set) var recoveryRequired = false
    @Published private(set) var connected = false
    @Published private(set) var acceptedTargets: [Int] = []
    private var engine: ChargePolicyEngine?
    private var lastSnapshot: BatterySnapshot?
    private var lastSnapshotArrivedAt: Double?
    private var snapshotWasTimely = false
    private var lastHelperObservation: ChargeObservation?
    private var observedSettings: [OwnedResource: HardwareSetting] = [:]
    private var loweringBehavior: LoweringBehavior = .unknown
    private var transport: (any LiveHelperTransport)?
    private let makeTransport: @MainActor () throws -> any LiveHelperTransport
    private let registration: any LiveHelperRegistrationDriving
    private let discovery: @Sendable () async -> LiveControlDiscovery
    private let preferences: UserDefaults
    private let trustVerified: Bool
    private let monitoringOnly: Bool
    private let clock: @Sendable () -> Double
    private let heartbeatEnabled: Bool
    private var started = false
    private var activatedIntent = false
    private var priorOneShotIntent: ChargeIntent?
    private var terminating = false
    private var unregistering = false
    private var transportBusy = false
    private var heartbeatTask: Task<Void, Never>?
    private var lastReadback: Double?

    var canCharge: Bool { usable && capability("native-powerui")?.readiness == .available && engine != nil && !acceptedTargets.isEmpty }
    var canFans: Bool { usable && capability("smc-standard-fan")?.readiness == .available && fanObservation?.descriptors.isEmpty == false }
    var canRegister: Bool {
        trustVerified && !isBusy && !terminating && !unregistering && registrationState != .enabled && registrationState != .requiresApproval
        && capabilities.contains { $0.readiness == .available }
    }
    var hasOwnedSettings: Bool { !ownedResources.isEmpty }
    private var hasActiveFanPolicy: Bool { fanState.requested != .systemAuto && (fanState.phase == .acquiring || fanState.phase == .managed) }
    var needsExplicitReapply: Bool { requestedIntent != nil && !activatedIntent }
    private var usable: Bool { trustVerified && connected && registrationState == .enabled && !recoveryRequired && !terminating && !unregistering }

    convenience init(preferences: UserDefaults = .standard) {
        let monitoringOnly = Bundle.main.object(forInfoDictionaryKey: "TilveroReleaseMode") as? String == "monitoring"
        let trust: HelperTrustConfiguration?
        do {
            guard !monitoringOnly else { throw PrivilegeError.missingTrust }
            let candidate = try HelperTrustConfiguration.fromBundle(); try candidate.verifyCurrentProcess(helper: false); trust = candidate }
        catch { trust = nil }
        self.init(preferences: preferences, trustVerified: trust != nil,
            registration: SignedHelperRegistration(trust: trust),
            makeTransport: { guard let trust else { throw PrivilegeError.missingTrust }; return try HelperClient(trust: trust) },
            discovery: { await LiveControlDiscovery.readOnly() }, clock: { HelperClock.continuousSeconds() }, heartbeatEnabled: true, monitoringOnly: monitoringOnly)
    }

    /// Dependency injection is internal to this module's fixture tests. No UI,
    /// preference, process argument or IPC field can select an untrusted transport.
    init(preferences: UserDefaults, trustVerified: Bool, registration: any LiveHelperRegistrationDriving,
         makeTransport: @escaping @MainActor () throws -> any LiveHelperTransport,
         discovery: @escaping @Sendable () async -> LiveControlDiscovery,
         clock: @escaping @Sendable () -> Double = { HelperClock.continuousSeconds() }, heartbeatEnabled: Bool = false, monitoringOnly: Bool = false) {
        self.preferences = preferences; self.trustVerified = trustVerified && !monitoringOnly; self.registration = registration
        self.monitoringOnly = monitoringOnly
        self.makeTransport = makeTransport; self.discovery = discovery; self.clock = clock; self.heartbeatEnabled = heartbeatEnabled
        registrationState = monitoringOnly ? .unavailable : registration.state
        if !monitoringOnly, let data = preferences.data(forKey: "liveRequestedChargeIntent") {
            requestedIntent = try? JSONDecoder().decode(ChargeIntent.self, from: data)
        }
        if !monitoringOnly, let data = preferences.data(forKey: "livePriorOneShotChargeIntent") { priorOneShotIntent = try? JSONDecoder().decode(ChargeIntent.self, from: data) }
        if requestedIntent == .fullOnce {
            requestedIntent = priorOneShotIntent == .fullOnce ? nil : priorOneShotIntent
            priorOneShotIntent = nil; persistIntent()
        }
        syncChargeState()
    }

    func start() async {
        guard !started else { return }; started = true
        let result = await discovery()
        capabilities = result.capabilities; fanObservation = result.fanObservation; loweringBehavior = result.loweringBehavior
        if monitoringOnly {
            capabilities = capabilities.map { ControlCapability(backend: $0.backend, readiness: .unavailable,
                reason: "Monitoring Preview does not enroll or use privileged services.") }
            registrationState = .unavailable
            message = "Monitoring Preview: hardware controls and helper enrollment are unavailable."
            return
        }
        registrationState = registration.state
        rebuildEngineIfNeeded()
        guard trustVerified else {
            message = "Trusted app/helper signing is unavailable. Read-only monitoring works without enrollment."; return
        }
        guard registrationState == .enabled else {
            message = registrationState == .requiresApproval ? "Approve the registered helper in macOS Login Items settings before using qualified control." : "Helper is not enabled. Only independently qualified controls can request registration."
            return
        }
        do { try await connect() }
        catch { report(error) }
    }

    func observe(_ snapshot: BatterySnapshot) async {
        guard !snapshot.isDemo else { return }
        lastSnapshot = snapshot; lastSnapshotArrivedAt = clock()
        let collectionAge = Date().timeIntervalSince(snapshot.collectedAt)
        snapshotWasTimely = collectionAge >= -5 && collectionAge <= 65
        guard !isBusy, !transportBusy else { return }
        if connected, lastReadback.map({ clock() - $0 >= 60 || clock() < $0 }) ?? true {
            do { let reply = try await send(.readState); try ingest(reply, command: .readState); lastReadback = clock() }
            catch { report(error) }
        }
        guard activatedIntent, canCharge, var engine else { return }
        let effects = engine.observe(currentObservation())
        self.engine = engine; syncChargeState()
        guard !effects.isEmpty else { return }
        isBusy = true; defer { isBusy = false }
        do { try await execute(effects) } catch { report(error) }
    }

    func submit(_ request: ChargeControlRequest) async throws {
        guard !isBusy else { throw LiveControlError.busy }
        isBusy = true; defer { isBusy = false }
        do { try await submitCharge(request) } catch { report(error); throw error }
    }
    func cancelPending() async throws {
        guard !isBusy else { throw LiveControlError.busy }
        guard var engine else { throw LiveControlError.unavailable }
        isBusy = true; defer { isBusy = false }
        let effects = try engine.cancelPending()
        self.engine = engine; requestedIntent = engine.state.requested; persistIntent(); syncChargeState()
        do { try await execute(effects) } catch { report(error); throw error }
    }
    func setFanPolicy(_ policy: FanPolicy) async throws {
        guard !isBusy else { throw LiveControlError.busy }
        isBusy = true; defer { isBusy = false }
        do { try await submitFans(policy) } catch { report(error); throw error }
    }
    func applyProfile(_ profile: PowerProfile, source: PowerProfileSource) async -> ProfileApplicationResult {
        guard !isBusy else { return .init(charge: LiveControlError.busy.localizedDescription, powerMode: LiveControlError.busy.localizedDescription, fans: LiveControlError.busy.localizedDescription) }
        isBusy = true; defer { isBusy = false }
        var result = ProfileApplicationResult()
        if profile.oneShotFullCharge || profile.chargeTarget != nil {
            do { try await submitCharge(profile.oneShotFullCharge ? .chargeToFullOnce : .setCeiling(percent: profile.chargeTarget!)) }
            catch { result.charge = safeReason(error); report(error) }
        }
        do { try await submitEnergy(source: source, mode: profile.mode) }
        catch { result.powerMode = safeReason(error); report(error) }
        do { try await submitFans(profile.fanPolicy) }
        catch { result.fans = safeReason(error); report(error) }
        return result
    }

    /// Also used by disable, sleep, quit and uninstall. Failure preserves ownership
    /// evidence and must prevent the UI from claiming restoration or removal.
    @discardableResult func restoreAll() async throws -> Bool {
        // This build cannot acquire ownership; a different installed service is not ours to restore.
        if monitoringOnly { return true }
        guard !isBusy else { throw LiveControlError.busy }
        isBusy = true; defer { isBusy = false }
        do {
            if !connected, registration.state == .enabled, trustVerified { try await connect() }
            if !hasOwnedSettings, !recoveryRequired, registration.state != .enabled {
                clearIntent(); return true
            }
            guard connected else { throw LiveControlError.recoveryRequired }
            let reply = try await performMutation(.restoreAll)
            guard reply.configurationVerified, !reply.recoveryRequired, reply.ownedResources.isEmpty else { throw LiveControlError.recoveryRequired }
            ownedResources = []; recoveryRequired = false
            fanState = reply.fanPolicyState ?? FanPolicyState(); fanObservation = reply.fanObservation
            clearIntent(); stopHeartbeat()
            message = "App-owned settings were verified as restored."
            return true
        } catch { recoveryRequired = hasOwnedSettings || recoveryRequired; report(error); throw error }
    }
    func prepareForTermination() async -> Bool {
        terminating = true
        do {
            guard try await restoreAll() else { return false }
            stopHeartbeat(); await transport?.invalidate(); transport = nil; connected = false
            return true
        } catch { terminating = false; return false }
    }
    func prepareForSleep() async -> Bool {
        do { let restored = try await restoreAll(); stopHeartbeat(); return restored }
        catch { stopHeartbeat(); return false }
    }
    func registerHelper() async throws {
        guard canRegister else { throw LiveControlError.notQualified }
        isBusy = true; defer { isBusy = false; registrationState = registration.state }
        do {
            try await registration.register(); registrationState = registration.state
            if registrationState == .enabled { try await connect() }
            else { message = "macOS approval is required before the registered helper can operate." }
        } catch { report(error); throw error }
    }
    func unregisterHelper() async throws {
        guard !monitoringOnly else { throw LiveControlError.notQualified }
        guard !isBusy, !unregistering else { throw LiveControlError.busy }
        unregistering = true; defer { unregistering = false }
        guard try await restoreAll() else { throw LiveControlError.recoveryRequired }
        guard !hasOwnedSettings, !recoveryRequired else { throw LiveControlError.recoveryRequired }
        isBusy = true; defer { isBusy = false }
        do {
            try await registration.unregister(afterVerifiedRestoration: true)
            registrationState = registration.state
            stopHeartbeat(); await transport?.invalidate(); transport = nil; connected = false
            message = "Helper removed after verified restoration."
        } catch { report(error); throw error }
    }

    private func submitCharge(_ request: ChargeControlRequest) async throws {
        if request == .returnToSystemControl {
            if ownedResources.contains(.charging) || recoveryRequired {
                let reply = try await performMutation(.releaseCharge)
                guard reply.configurationVerified, !reply.ownedResources.contains(.charging), !reply.recoveryRequired else { throw LiveControlError.recoveryRequired }
            }
            clearIntent(); return
        }
        guard canCharge, var engine else { throw LiveControlError.notQualified }
        let effects: [ChargeEffect]
        switch request {
        case .setCeiling(let target): effects = try engine.submit(.ceiling(target), observation: currentObservation())
        case .chargeToFullOnce:
            if requestedIntent != .fullOnce { priorOneShotIntent = engine.state.requested ?? requestedIntent }
            effects = try engine.submit(.fullOnce, observation: currentObservation())
        case .cancelOneShot: effects = engine.cancelOneShot(observation: currentObservation())
        case .returnToSystemControl: effects = try engine.submit(.system, observation: currentObservation())
        }
        activatedIntent = true; self.engine = engine; requestedIntent = engine.state.requested; persistIntent(); syncChargeState()
        try await execute(effects)
    }
    private func execute(_ effects: [ChargeEffect]) async throws {
        for effect in effects {
            let command: HelperCommand
            switch effect { case .apply(let target, _): command = .applyCharge(target: target); case .restore: command = .releaseCharge }
            do {
                let reply = try await performMutation(command)
                guard reply.configurationVerified else { throw LiveControlError.readbackMismatch }
                guard var engine else { throw LiveControlError.unavailable }
                let restoration = !reply.recoveryRequired && !reply.ownedResources.contains(.charging)
                try engine.acknowledge(effect, effectiveTarget: observedEffectiveTarget(reply), restorationVerified: restoration)
                self.engine = engine; requestedIntent = engine.state.requested; persistIntent(); syncChargeState()
            } catch {
                engine?.fail(generation: effect.generation, reason: safeReason(error))
                recoveryRequired = true; stopHeartbeat(); syncChargeState(); throw error
            }
        }
    }
    private func submitEnergy(source: PowerProfileSource, mode: EnergyMode) async throws {
        guard usable, capability("pmset-lowpowermode")?.readiness == .available else { throw LiveControlError.notQualified }
        let resource: OwnedResource = source == .battery ? .batteryEnergyMode : .adapterEnergyMode
        if observedSettings[resource] == .energy(mode) { return }
        let reply = try await performMutation(.setEnergyMode(source: source, mode: mode))
        guard reply.configurationVerified, reply.observedSettings[resource] == .energy(mode), !reply.recoveryRequired else {
            recoveryRequired = true; stopHeartbeat(); throw LiveControlError.readbackMismatch
        }
    }
    private func submitFans(_ policy: FanPolicy) async throws {
        if policy == .systemAuto, !ownedResources.contains(.fans), !hasActiveFanPolicy, !recoveryRequired { return }
        guard connected else { throw LiveControlError.unavailable }
        if policy != .systemAuto {
            let fresh = try await send(.readState)
            try ingest(fresh, command: .readState); lastReadback = clock()
            guard canFans, let observation = fresh.fanObservation, observation.isFresh(now: clock()) else { throw LiveControlError.notQualified }
            var validator = FanPolicyEngine(fans: observation.descriptors)
            _ = try validator.submit(policy, now: clock())
            if case .curve = policy, !observation.sensorFresh || observation.sensorTemperature == nil { throw LiveControlError.notQualified }
        }
        let command: HelperCommand = policy == .systemAuto ? .releaseFans : .setFanPolicy(policy)
        let reply = try await performMutation(command)
        do {
        guard !reply.recoveryRequired else { throw LiveControlError.recoveryRequired }
        if policy == .systemAuto {
            guard reply.configurationVerified, !reply.ownedResources.contains(.fans),
                  reply.fanObservation?.autoMode.values.allSatisfy({ $0 }) != false else { throw LiveControlError.readbackMismatch }
        } else {
            guard let state = reply.fanPolicyState, state.requested == policy,
                  state.phase == .managed || state.phase == .acquiring else { throw LiveControlError.readbackMismatch }
            if state.phase == .managed {
                guard reply.configurationVerified, let observation = reply.fanObservation,
                      observation.isFresh(now: clock()), !observation.descriptors.isEmpty,
                      observation.actualRPM.count == observation.descriptors.count,
                      observation.targetRPM.count == observation.descriptors.count,
                      observation.autoMode.count == observation.descriptors.count,
                      state.appliedRPM.count == observation.descriptors.count,
                      observation.descriptors.allSatisfy({ fan in
                          guard let actual = observation.actualRPM[fan.id], let target = observation.targetRPM[fan.id] else { return false }
                          return fan.accepts(target) && observation.autoMode[fan.id] == false
                              && state.appliedRPM[fan.id] == target && abs(actual - target) <= 250
                      }) else { throw LiveControlError.readbackMismatch }
            }
        }
        } catch {
            fanState.phase = .recoveryRequired; fanState.reason = safeReason(error)
            recoveryRequired = true; stopHeartbeat(); throw error
        }
    }
    private func connect() async throws {
        guard trustVerified, registration.state == .enabled else { throw LiveControlError.unavailable }
        if transport == nil { transport = try makeTransport() }
        guard let transport, !transportBusy else { throw LiveControlError.busy }
        transportBusy = true
        let opened: HelperReply
        do { opened = try await transport.openSession(); transportBusy = false }
        catch { transportBusy = false; throw error }
        guard opened.accepted else { throw LiveControlError.unavailable }
        connected = true; registrationState = registration.state
        let reply = try await send(.readState); try ingest(reply, command: .readState); lastReadback = clock()
    }
    private func send(_ command: HelperCommand) async throws -> HelperReply {
        guard connected, let transport else { throw LiveControlError.unavailable }
        guard !transportBusy else { throw LiveControlError.busy }
        transportBusy = true; defer { transportBusy = false }
        return try await transport.submit(command)
    }
    private func performMutation(_ command: HelperCommand) async throws -> HelperReply {
        guard command.isMutation else { throw LiveControlError.unavailable }
        do {
            let reply = try await send(command); try ingest(reply, command: command); return reply
        } catch {
            // A lost reply cannot prove that the helper made no partial change.
            recoveryRequired = true; stopHeartbeat(); throw error
        }
    }
    private func ingest(_ reply: HelperReply, command: HelperCommand) throws {
        guard reply.accepted else {
            if command.isMutation { recoveryRequired = hasOwnedSettings || reply.recoveryRequired }
            throw reply.recoveryRequired ? LiveControlError.recoveryRequired : LiveControlError.unavailable
        }
        if !reply.capabilities.isEmpty { capabilities = reply.capabilities; rebuildEngineIfNeeded() }
        if command != .heartbeat || !reply.ownedResources.isEmpty || reply.recoveryRequired {
            ownedResources = reply.ownedResources; recoveryRequired = reply.recoveryRequired
        }
        if !reply.observedSettings.isEmpty { observedSettings = reply.observedSettings }
        if let observation = reply.chargeObservation { lastHelperObservation = observation }
        else if reply.observedSettings[.charging] != nil {
            lastHelperObservation = ChargeObservation(percent: nil, externalPower: nil, fresh: true,
                effectiveTarget: observedEffectiveTarget(reply))
        } else if command == .readState { lastHelperObservation = nil }
        if let observation = reply.fanObservation { fanObservation = observation }
        if let state = reply.fanPolicyState { fanState = state }
        if command == .readState, !activatedIntent, var engine {
            let observation = reply.chargeObservation ?? ChargeObservation(percent: nil, externalPower: nil, fresh: true, effectiveTarget: observedEffectiveTarget(reply))
            _ = engine.observe(observation); self.engine = engine; syncChargeState()
        }
        if recoveryRequired { stopHeartbeat() } else { beginHeartbeatIfOwned() }
    }
    private func observedEffectiveTarget(_ reply: HelperReply) -> Int? {
        if let setting = reply.observedSettings[.charging] {
            guard case let .nativeCharge(feature, limit) = setting, feature == 1 else { return nil }
            return limit
        }
        return reply.chargeObservation?.effectiveTarget
    }
    private func currentObservation() -> ChargeObservation {
        guard let snapshot = lastSnapshot else {
            guard let lastReadback, clock() >= lastReadback, clock() - lastReadback <= 65 else {
                return .init(percent: nil, externalPower: nil, fresh: false)
            }
            return lastHelperObservation ?? .init(percent: nil, externalPower: nil, fresh: false)
        }
        func usable<T>(_ reading: TelemetryReading<T>) -> T? { reading.availability == .available && reading.freshness != .stale ? reading.value : nil }
        let percent = usable(snapshot.chargePercent), external = usable(snapshot.isExternalPower)
        let age = lastSnapshotArrivedAt.map { clock() - $0 }
        let timely = snapshotWasTimely && age.map { $0 >= 0 && $0 <= 65 } == true
        let full = snapshot.catalog.first { $0.id == "014" && $0.availability == .available && $0.freshness != .stale }.flatMap { reading -> Bool? in
            if case .boolean(let value)? = reading.value { return value }; return nil
        }
        return ChargeObservation(percent: percent, externalPower: external, fresh: timely && percent != nil && external != nil,
            effectiveTarget: lastHelperObservation?.effectiveTarget,
            systemOverride: lastHelperObservation?.systemOverride ?? false, isCharging: usable(snapshot.isCharging), fullyCharged: full)
    }
    private func capability(_ backend: String) -> ControlCapability? { capabilities.first { $0.backend == backend } }
    private func rebuildEngineIfNeeded() {
        let targets = capability("native-powerui").flatMap { $0.readiness == .available ? $0.acceptedTargets : nil } ?? []
        guard targets != acceptedTargets else { return }
        acceptedTargets = targets
        engine = targets.isEmpty ? nil : try? ChargePolicyEngine(acceptedTargets: targets, loweringBehavior: loweringBehavior)
        activatedIntent = false; syncChargeState()
    }
    private func syncChargeState() {
        chargeState = engine?.state ?? ChargePolicyState()
        if !activatedIntent, let requestedIntent {
            chargeState.requested = requestedIntent; chargeState.phase = .observing
            chargeState.reason = "Saved intent only. Reapply explicitly after fresh capability and hardware readback checks."
        }
    }
    private func persistIntent() {
        if requestedIntent == .fullOnce, let priorOneShotIntent, let data = try? JSONEncoder().encode(priorOneShotIntent) {
            preferences.set(data, forKey: "livePriorOneShotChargeIntent")
        } else {
            preferences.removeObject(forKey: "livePriorOneShotChargeIntent")
            if requestedIntent != .fullOnce { priorOneShotIntent = nil }
        }
        if let requestedIntent, let data = try? JSONEncoder().encode(requestedIntent) { preferences.set(data, forKey: "liveRequestedChargeIntent") }
        else { preferences.removeObject(forKey: "liveRequestedChargeIntent") }
    }
    private func clearIntent() {
        requestedIntent = nil; activatedIntent = false; persistIntent()
        engine = acceptedTargets.isEmpty ? nil : try? ChargePolicyEngine(acceptedTargets: acceptedTargets, loweringBehavior: loweringBehavior)
        if let lastHelperObservation { _ = engine?.observe(lastHelperObservation) }
        syncChargeState()
    }
    private func beginHeartbeatIfOwned() {
        guard heartbeatEnabled, hasOwnedSettings || hasActiveFanPolicy, !recoveryRequired, heartbeatTask == nil else { return }
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self else { return }
                await self.heartbeatIfOwned()
            }
        }
    }
    private func heartbeatIfOwned() async {
        guard hasOwnedSettings || hasActiveFanPolicy, !recoveryRequired, !isBusy, !transportBusy else { return }
        do { let reply = try await send(.heartbeat); try ingest(reply, command: .heartbeat) }
        catch { recoveryRequired = true; stopHeartbeat(); report(error) }
    }
    private func stopHeartbeat() { heartbeatTask?.cancel(); heartbeatTask = nil }
    private func report(_ error: Error) { message = safeReason(error) }
    private func safeReason(_ error: Error) -> String {
        if let error = error as? LiveControlError { return error.localizedDescription }
        if let error = error as? PolicyError { return "Charge/fan policy could not be confirmed (\(error))." }
        return "The trusted helper operation failed. Existing ownership evidence is retained; monitoring continues."
    }
    isolated deinit { heartbeatTask?.cancel() }
}
