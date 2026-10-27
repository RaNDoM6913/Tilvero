import Foundation

public enum OwnedResource: String, Codable, Sendable, CaseIterable { case charging, batteryEnergyMode, adapterEnergyMode, fans }
public enum HardwareSetting: Codable, Sendable, Equatable {
    case nativeCharge(featureState: Int?, limit: Int?)
    case energy(EnergyMode)
    case fanAuto
    case fanRPM([String: Int])
}
public enum BackendReadiness: String, Codable, Sendable { case available, unavailable, unknown, needsAuthorization, unverified }
public struct ControlCapability: Codable, Sendable, Equatable {
    public let backend: String
    public let readiness: BackendReadiness
    public let reason: String
    public let acceptedTargets: [Int]
    public let observedAt: Date
    public let validationReference: String?
    public init(backend: String, readiness: BackendReadiness, reason: String, acceptedTargets: [Int] = [], observedAt: Date = Date(), validationReference: String? = nil) {
        self.backend = backend; self.readiness = readiness; self.reason = reason; self.acceptedTargets = acceptedTargets
        self.observedAt = observedAt; self.validationReference = validationReference
    }
}

/// The shipped qualification list is empty until signed-helper and real-device restore gates are evidenced.
/// Callers cannot enable physical writes using a UI toggle or an IPC argument.
public struct HardwareQualification: Sendable {
    public static let current = HardwareQualification()
    private init() {}
    public func require(_ resource: OwnedResource) throws {
        throw ControlUnavailableError(reason: "Physical \(resource.rawValue) control is unverified. Trusted signing, deliberate hardware validation and verified restoration are required.")
    }
}

public enum HelperCommand: Codable, Sendable, Equatable {
    case readState
    case heartbeat
    case applyCharge(target: Int)
    case releaseCharge
    case setEnergyMode(source: PowerProfileSource, mode: EnergyMode)
    case setFanRPM([String: Int])
    case setFanPolicy(FanPolicy)
    case releaseFans
    case restoreAll
    public var isMutation: Bool { switch self { case .readState, .heartbeat: false; default: true } }
}
public struct HelperEnvelope: Codable, Sendable, Equatable {
    public static let protocolVersion = 2
    public static let maximumBytes = 32_768
    public let version: Int
    public let requestID: UUID
    public let sessionToken: UUID
    public let generation: UInt64
    public let command: HelperCommand
    public init(version: Int = protocolVersion, requestID: UUID = UUID(), sessionToken: UUID, generation: UInt64, command: HelperCommand) {
        self.version = version; self.requestID = requestID; self.sessionToken = sessionToken; self.generation = generation; self.command = command
    }
}
public struct HelperReply: Codable, Sendable, Equatable {
    public var accepted: Bool
    public var configurationVerified: Bool
    public var behaviorObserved: Bool
    public var generation: UInt64
    public var sessionToken: UUID?
    public var reason: String?
    public var capabilities: [ControlCapability]
    public var observedSettings: [OwnedResource: HardwareSetting]
    public var chargeObservation: ChargeObservation?
    public var fanObservation: FanObservation?
    public var ownedResources: [OwnedResource]
    public var recoveryRequired: Bool
    public var fanPolicyState: FanPolicyState?
    public var registrationOwnerUserID: UInt32?
    public init(accepted: Bool = false, configurationVerified: Bool = false, behaviorObserved: Bool = false, generation: UInt64 = 0, sessionToken: UUID? = nil, reason: String? = nil, capabilities: [ControlCapability] = [], observedSettings: [OwnedResource: HardwareSetting] = [:], chargeObservation: ChargeObservation? = nil, fanObservation: FanObservation? = nil, ownedResources: [OwnedResource] = [], recoveryRequired: Bool = false, fanPolicyState: FanPolicyState? = nil, registrationOwnerUserID: UInt32? = nil) {
        self.accepted = accepted; self.configurationVerified = configurationVerified; self.behaviorObserved = behaviorObserved
        self.generation = generation; self.sessionToken = sessionToken; self.reason = reason; self.capabilities = capabilities
        self.observedSettings = observedSettings; self.chargeObservation = chargeObservation; self.fanObservation = fanObservation
        self.ownedResources = ownedResources; self.recoveryRequired = recoveryRequired; self.fanPolicyState = fanPolicyState
        self.registrationOwnerUserID = registrationOwnerUserID
    }
}

public struct FanObservation: Codable, Sendable, Equatable {
    public let descriptors: [FanDescriptor]
    public let actualRPM: [String: Int]
    public let targetRPM: [String: Int]
    public let autoMode: [String: Bool]
    public let sensorTemperature: Double?
    public let sensorFresh: Bool
    public let observedAt: Date
    public let sampledContinuousSeconds: Double
    public let sleeping: Bool
    public init(descriptors: [FanDescriptor] = [], actualRPM: [String: Int] = [:], targetRPM: [String: Int] = [:], autoMode: [String: Bool] = [:], sensorTemperature: Double? = nil, sensorFresh: Bool = false, observedAt: Date = Date(), sampledContinuousSeconds: Double = 0, sleeping: Bool = false) {
        self.descriptors = descriptors; self.actualRPM = actualRPM; self.targetRPM = targetRPM; self.autoMode = autoMode
        self.sensorTemperature = sensorTemperature; self.sensorFresh = sensorFresh; self.observedAt = observedAt
        self.sampledContinuousSeconds = sampledContinuousSeconds; self.sleeping = sleeping
    }
    public func isFresh(now: Double) -> Bool {
        sampledContinuousSeconds.isFinite && now.isFinite && now >= sampledContinuousSeconds && now - sampledContinuousSeconds <= 3
    }
}

public enum FanRegister: Codable, Sendable, Equatable, Hashable {
    case target(fanID: String)
    case automatic(fanID: String)
    public var fanID: String { switch self { case let .target(id), let .automatic(id): id } }
}
public enum FanRegisterValue: Codable, Sendable, Equatable { case rpm(Int), automatic(Bool) }
