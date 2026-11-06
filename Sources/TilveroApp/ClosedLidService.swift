import AppKit
import Combine
import ClosedLidControl
import Darwin
import PowerPrivileged
import ServiceManagement

/// Normal builds remain gated; fixture memory is explicitly selected by a lab or test.
/// A separately signed immutable trial host can connect to the dedicated lid service.
enum ClosedLidServiceMode { case gated, fixtureMemory }

@MainActor final class ClosedLidService: ObservableObject {
    @Published private(set) var state = ClosedLidState()
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    let isLiveTrial: Bool
    let isFixture: Bool
    var isAvailable: Bool { isLiveTrial || isFixture || injectedClientFactory != nil }
    private var client: (any ClosedLidClientTransport)?
    private var memory: ClamshellMemoryBackend?
    private var memoryClient: ClosedLidMemoryClient?
    private var guardian: ClosedLidGuardian?
    private var heartbeat: Task<Void, Never>?
    private var awakeSubscription: AnyCancellable?
    private var boundAwake: ObjectIdentifier?
    private var boundAwakeOwner: UInt32?
    private var liveIdle: NativeKeepAwakeTransport?
    private var idleID: UInt32?
    private let idleName = "Tilvero Keep Awake Closed Lid " + UUID().uuidString
    private var trust: ClosedLidTrust?
    private var controllerRegistration: SMAppService?
    private var guardianRegistration: SMAppService?
    private var operationRevision: UInt64 = 0
    private var mutationInFlight = false
    private var pendingStop = false
    private var revocationInFlight = false
    private let heartbeatSleep: @Sendable () async throws -> Void
    private let injectedClientFactory: (@MainActor () throws -> any ClosedLidClientTransport)?

    init(mode: ClosedLidServiceMode = .gated, allowed: Bool = true) {
        isFixture = allowed && mode == .fixtureMemory
        let trialMarker = Bundle.main.object(forInfoDictionaryKey: "TilveroLidTrialHost") as? Bool == true
        // The marker is part of the signed bundle. It is never read from preferences
        // or environment, and exact process trust is required before live admission.
        if allowed, !isFixture, trialMarker, let candidate = try? ClosedLidTrust.fromBundle(),
           (try? candidate.verify(helper: false)) != nil {
            isLiveTrial = true
        } else {
            isLiveTrial = false
        }
        injectedClientFactory = nil
        heartbeatSleep = { try await Task.sleep(for: .seconds(5)) }
    }
    init(testClientFactory: @escaping @MainActor () throws -> any ClosedLidClientTransport,
         testHeartbeatSleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(5)) }) {
        isLiveTrial = false; isFixture = true; injectedClientFactory = testClientFactory
        heartbeatSleep = testHeartbeatSleep
    }
    var isOn: Bool { [.prepared, .commandAccepted, .restorationRequired].contains(state.phase) }
    var needsRecovery: Bool { state.recoveryRequired || state.phase == .restoreAcceptedAwaitingWitness || state.phase == .conflict }

    func bind(_ awake: KeepAwakeService) {
        guard boundAwake != ObjectIdentifier(awake) else { return }
        if boundAwake != nil { requestOwnerStop() }
        boundAwake = ObjectIdentifier(awake)
        boundAwakeOwner = awake.ownedAssertionID
        awakeSubscription = awake.$ownedAssertionID.dropFirst().sink { [weak self] id in
            guard let self, id != self.boundAwakeOwner else { return }
            let previous = self.boundAwakeOwner
            self.boundAwakeOwner = id
            if previous != nil { self.requestOwnerStop() }
        }
    }

    private func requestOwnerStop() {
        guard !pendingStop else { return }
        pendingStop = true
        operationRevision &+= 1
        heartbeat?.cancel(); heartbeat = nil
        releaseIdleLease()
        if busy {
            if mutationInFlight || isOn { markOutcomeUnknown() }
            let revoked = client
            client = nil
            revocationInFlight = true
            Task { @MainActor [weak self] in
                await revoked?.invalidate()
                guard let self else { return }
                self.revocationInFlight = false
                await self.completePendingStop()
            }
        } else {
            Task { @MainActor [weak self] in await self?.completePendingStop() }
        }
    }

    private func finishOperation() {
        mutationInFlight = false
        busy = false
        if pendingStop {
            Task { @MainActor [weak self] in await self?.completePendingStop() }
        }
    }

    private func completePendingStop() async {
        guard pendingStop, !busy, !revocationInFlight else { return }
        pendingStop = false
        _ = await prepareForTermination()
    }

    private func markOutcomeUnknown() {
        state.phase = .restorationRequired; state.recoveryRequired = true
        state.reason = "The command outcome is unknown; independent recovery must reconcile it."
    }

    func setEnabled(_ enabled: Bool, seconds: Int) async {
        guard !busy, !pendingStop else { return }; busy = true; defer { finishOperation() }
        operationRevision &+= 1
        let revision = operationRevision
        var outcomeUnknown = false
        var commandClient: (any ClosedLidClientTransport)?
        failure = nil
        do {
            try await connectIfNeeded()
            guard revision == operationRevision, let client else { throw ClosedLidFailure.wrongSession }
            commandClient = client
            if enabled {
                guard !needsRecovery, !isOn else { throw ClosedLidFailure.recoveryRequired }
                if let memory { await memory.emitOpenWitness() }
                if let guardian { _ = try await guardian.tick(activeUserID: UInt32(geteuid())) }
                guard revision == operationRevision else { throw ClosedLidFailure.wrongSession }
                if isLiveTrial { try acquireIdleLease() }
                mutationInFlight = true
                outcomeUnknown = true
                let response = try await client.submit(.start(seconds: isLiveTrial ? min(seconds, 120) : seconds))
                guard revision == operationRevision else { throw ClosedLidFailure.wrongSession }
                outcomeUnknown = false
                mutationInFlight = false
                ingest(response)
                guard response.accepted else { throw response.failure ?? .unavailable }
                startHeartbeat()
            } else if let sessionID = state.sessionID {
                mutationInFlight = true
                outcomeUnknown = true
                let response = try await client.submit(.stop(sessionID: sessionID))
                guard revision == operationRevision else { throw ClosedLidFailure.wrongSession }
                outcomeUnknown = false
                mutationInFlight = false
                ingest(response)
                guard response.accepted else { throw response.failure ?? .recoveryRequired }
                if state.restoreCommandAccepted || state.phase == .restored { releaseIdleLease(); heartbeat?.cancel(); heartbeat = nil }
                // The memory event source delivers a separate post-reply event.
                // Emitting inside the setter can share the receipt's clock tick,
                // which correctly fails the production strict-newer-witness gate.
                if let memory { await memory.emitOpenWitness() }
                if let guardian { _ = try await guardian.tick(activeUserID: UInt32(geteuid())) }
                let read = try await client.submit(.readState)
                guard revision == operationRevision else { throw ClosedLidFailure.wrongSession }
                ingest(read)
            }
            if state.phase != .restorationRequired && idleID == nil { failure = nil }
        } catch {
            if outcomeUnknown {
                markOutcomeUnknown()
                await commandClient?.invalidate(); client = nil
            }
            failure = message(error)
            releaseIdleLease()
        }
    }

    @discardableResult func prepareForTermination() async -> Bool {
        if busy { requestOwnerStop(); return false }
        guard !revocationInFlight else { return false }
        operationRevision &+= 1
        if isOn { await setEnabled(false, seconds: 0) }
        else if needsRecovery { await refresh() }
        if !isOn { releaseIdleLease() }
        return !isOn && !needsRecovery && idleID == nil
    }

    func refresh() async {
        guard !busy else { return }
        busy = true; defer { finishOperation() }
        do {
            let revision = operationRevision
            try await connectIfNeeded()
            guard revision == operationRevision, let client else { throw ClosedLidFailure.wrongSession }
            let reply = try await client.submit(.readState)
            guard revision == operationRevision else { throw ClosedLidFailure.wrongSession }
            ingest(reply)
        }
        catch { failure = message(error) }
    }

    func enroll() async {
        guard isLiveTrial, !busy else { return }
        busy = true; defer { finishOperation() }
        do {
            let candidate = try ClosedLidTrust.fromBundle(); try candidate.verify(helper: false)
            guard Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix("/Applications/") else { throw ClosedLidFailure.missingTrust }
            let guardian = SMAppService.daemon(plistName: "local.tilvero.lidlab.guardian.plist")
            let controller = SMAppService.daemon(plistName: "local.tilvero.lidlab.controller.plist")
            try guardian.register()
            do { try controller.register() } catch { try? await guardian.unregister(); throw error }
            guardianRegistration = guardian; controllerRegistration = controller; trust = candidate
            failure = nil
        } catch { failure = message(error) }
    }
    func openApproval() { guard isLiveTrial else { return }; SMAppService.openSystemSettingsLoginItems() }

    func removeHelper() async {
        guard isLiveTrial, !busy else { return }; busy = true; defer { finishOperation() }
        do {
            try await connectIfNeeded()
            guard let client else { throw ClosedLidFailure.wrongSession }
            let reply = try await client.submit(.readState); ingest(reply)
            guard reply.accepted, !isOn, !needsRecovery, idleID == nil,
                  [.idle, .restored, .retiredAfterBoot].contains(state.phase) else { throw ClosedLidFailure.recoveryRequired }
            try await SMAppService.daemon(plistName: "local.tilvero.lidlab.controller.plist").unregister()
            try await SMAppService.daemon(plistName: "local.tilvero.lidlab.guardian.plist").unregister()
            await client.invalidate(); self.client = nil; failure = nil
        } catch { failure = message(error) }
    }

    private func connectIfNeeded() async throws {
        let revision = operationRevision
        if let client {
            if !needsRecovery && [.restored, .retiredAfterBoot].contains(state.phase) {
                // Restoration revokes the controller epoch. Reauthenticate before
                // the next start, retaining the same independently journaled service.
                do {
                    let opened = try await client.openSession()
                    guard revision == operationRevision else { throw ClosedLidFailure.wrongSession }
                    ingest(opened)
                    guard opened.accepted else { throw opened.failure ?? .wrongSession }
                } catch {
                    await client.invalidate(); self.client = nil
                    throw error
                }
            }
            return
        }
        let next: any ClosedLidClientTransport
        if let injectedClientFactory {
            next = try injectedClientFactory()
        } else if isLiveTrial {
            let candidate = try ClosedLidTrust.fromBundle(); try candidate.verify(helper: false)
            trust = candidate; liveIdle = NativeKeepAwakeTransport()
            next = try ClosedLidXPCClient(trust: candidate)
        } else if !isFixture {
            throw ClosedLidFailure.missingTrust
        } else if let memoryClient {
            // A simulated post-disconnect event can witness an accepted clear;
            // emitOpenWitness refuses while the simulated lid override is active.
            if let memory { await memory.emitOpenWitness() }
            if let guardian { _ = try await guardian.tick(activeUserID: UInt32(geteuid())) }
            next = memoryClient
        } else {
            let clock: @Sendable () -> Double = { HelperClock.continuousSeconds() }
            let boot = "fixture-memory-boot"
            let backend = ClamshellMemoryBackend(clock: clock, bootID: boot)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroLidFixture-" + UUID().uuidString)
            let safePath = directory.path.hasPrefix("/var/") ? "/private" + directory.path : directory.path
            let store = try ClosedLidJournal(directory: URL(fileURLWithPath: safePath), requiredOwner: UInt32(geteuid()))
            let controller = ClosedLidController(backend: backend, journal: store, clock: clock, bootID: { boot })
            let guardService = ClosedLidGuardian(backend: backend, journal: store, clock: clock, bootID: { boot })
            _ = try await guardService.tick(activeUserID: UInt32(geteuid()))
            memory = backend; guardian = guardService
            let memoryClient = ClosedLidMemoryClient(controller: controller)
            self.memoryClient = memoryClient
            next = memoryClient
        }
        let opened = try await next.openSession()
        guard revision == operationRevision else { await next.invalidate(); throw ClosedLidFailure.wrongSession }
        ingest(opened)
        guard opened.accepted else { await next.invalidate(); throw opened.failure ?? .wrongSession }
        client = next
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await self?.heartbeatSleep() } catch { return }
                guard !Task.isCancelled, let self, let sessionID = self.state.sessionID,
                      let client = self.client, self.isOn, !self.pendingStop else { return }
                guard !self.busy else { continue }
                self.busy = true
                let revision = self.operationRevision
                do {
                    if let guardian = self.guardian { _ = try await guardian.tick(activeUserID: UInt32(geteuid())) }
                    guard revision == self.operationRevision else { throw ClosedLidFailure.wrongSession }
                    self.mutationInFlight = true
                    let reply = try await client.submit(.heartbeat(sessionID: sessionID))
                    guard revision == self.operationRevision, !Task.isCancelled else { throw ClosedLidFailure.wrongSession }
                    self.ingest(reply)
                    if reply.accepted { try self.renewIdleLease() }
                    else { self.releaseIdleLease() }
                } catch {
                    self.markOutcomeUnknown()
                    await client.invalidate(); self.client = nil
                    self.failure = self.message(error); self.releaseIdleLease()
                }
                self.finishOperation()
            }
        }
    }
    private func acquireIdleLease() throws {
        guard idleID == nil, let liveIdle else { return }
        let id = try liveIdle.create(seconds: 15, name: idleName)
        guard let read = try liveIdle.read(id), read.name == idleName, read.active, read.releasesOnTimeout else {
            try? liveIdle.release(id, name: idleName); throw KeepAwakeError.unconfirmed
        }
        idleID = id
    }
    private func renewIdleLease() throws {
        if let idleID, let liveIdle { try liveIdle.setTimeout(idleID, seconds: 15, name: idleName) }
    }
    private func releaseIdleLease() {
        guard let id = idleID, let liveIdle else { return }
        do { try liveIdle.release(id, name: idleName); idleID = nil }
        catch { failure = error.localizedDescription }
    }
    private func ingest(_ reply: ClosedLidReply) {
        // A generic transport refusal carries no authoritative recovery evidence.
        // Keep an earlier possibly applied operation visible until the service
        // returns a concrete journal state or an authenticated terminal result.
        if !(needsRecovery && !reply.accepted && reply.state == ClosedLidState()) {
            state = reply.state
        }
        if let error = reply.failure { failure = message(error) }
    }
    private func message(_ error: Error) -> String {
        guard let failure = error as? ClosedLidFailure else { return error.localizedDescription }
        let ru = L10n.language == "ru"
        switch failure {
        case .baselineWitnessRequired: return ru ? "После запуска помощника закройте и откройте крышку, затем повторите включение." : "After starting the helper, close and reopen the lid, then try enabling again."
        case .guardianUnavailable: return ru ? "Помощник восстановления ещё не готов." : "The recovery helper is not ready yet."
        case .missingTrust, .unavailable: return ru ? "Нужен установленный подписанный помощник." : "An installed signed helper is required."
        case .recoveryRequired: return ru ? "Нужно подтвердить восстановление управления крышкой." : "Lid restoration still needs confirmation."
        case .contextConflict: return ru ? "Условия изменились; проверьте восстановление." : "Conditions changed; check restoration."
        default: return ru ? "Действие не выполнено: " + failure.rawValue : "Action did not complete: " + failure.rawValue
        }
    }
}

actor ClosedLidMemoryClient: ClosedLidClientTransport {
    let controller: ClosedLidController
    let peer = ClosedLidPeer(userID: UInt32(geteuid()), auditSessionID: 1, connectionID: UUID())
    private var token: UUID?
    private var generation: UInt64 = 0
    init(controller: ClosedLidController) { self.controller = controller }
    func openSession() async throws -> ClosedLidReply {
        let reply = try await controller.openSession(peer: peer, activeUserID: peer.userID)
        token = reply.sessionToken; generation = reply.generation; return reply
    }
    func submit(_ command: ClosedLidCommand) async throws -> ClosedLidReply {
        guard let token else { throw ClosedLidFailure.wrongSession }
        let reply = try await controller.perform(.init(sessionToken: token, generation: generation + 1, command: command), peer: peer, activeUserID: peer.userID)
        generation = reply.generation; return reply
    }
    func invalidate() async { await controller.disconnect(peer: peer); token = nil }
}

actor ClamshellMemoryBackend: ClamshellBackend {
    private let clock: @Sendable () -> Double
    private let bootID: String
    private let contextID = UUID()
    private var witness: ClamshellBaselineWitness?
    private var sequence: UInt64 = 0
    private let observerID = UUID()
    private var disabled = false
    init(clock: @escaping @Sendable () -> Double, bootID: String) { self.clock = clock; self.bootID = bootID }
    func emitOpenWitness() {
        guard !disabled else { return }; sequence += 1
        // Exercise the native-event packet contract with simulated values. The
        // composition and all captures are explicitly labeled fixture memory.
        witness = .init(bootID: bootID, receivedAt: clock(), sequence: sequence, contextID: contextID, notificationBits: 2, sleepAllowed: true, observerID: observerID)
    }
    func observe() -> ClamshellObservation {
        .init(bootID: bootID, sampledAt: clock(), contextID: contextID, activeUserID: UInt32(geteuid()), lidClosed: false, externalDisplayPresent: false, aggregateSleepAllowed: !disabled, witness: witness)
    }
    func setLidSleepDisabled(_ disabled: Bool) -> ClamshellCommandReceipt {
        let receipt = ClamshellCommandReceipt(disabled: disabled, acceptedAt: clock())
        self.disabled = disabled
        return receipt
    }
}
