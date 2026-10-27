/// Typed extension points only. This starter intentionally contains no control backend.
public enum ChargeControlRequest: Sendable, Equatable {
    case setCeiling(percent: Int)
    case chargeToFullOnce
    case cancelOneShot
    case returnToSystemControl
}

public enum FanControlRequest: Sendable, Equatable {
    case returnToSystemAuto
    case setManualRPM(fanID: String, rpm: Int)
}

public struct ControlUnavailableError: Error, Sendable, Equatable {
    public let reason: String

    public init(reason: String) { self.reason = reason }
}

/// A future implementation must add capability discovery, ownership and readback
/// before it is enabled. Returning normally must not be treated as physical proof.
public protocol ChargeControlling: Sendable {
    func submit(_ request: ChargeControlRequest) async throws
}

public protocol FanControlling: Sendable {
    func submit(_ request: FanControlRequest) async throws
}

public struct UnsupportedChargeController: ChargeControlling, Sendable {
    public let reason: String

    public init(reason: String = "Charge control is not implemented or hardware-verified in this starter.") {
        self.reason = reason
    }

    public func submit(_ request: ChargeControlRequest) async throws {
        throw ControlUnavailableError(reason: reason)
    }
}

public struct UnsupportedFanController: FanControlling, Sendable {
    public let reason: String

    public init(reason: String = "Fan control is not implemented or hardware-verified in this starter.") {
        self.reason = reason
    }

    public func submit(_ request: FanControlRequest) async throws {
        throw ControlUnavailableError(reason: reason)
    }
}
