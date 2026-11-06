import Foundation
import Darwin
import IOKit
import IOKit.pwr_mgt
import PowerPrivileged

public protocol ClamshellUserClientPort: Sendable {
    func setLidSleepDisabled(_ disabled: Bool) throws
    func requestNormalSleep() throws -> Bool
}
public extension ClamshellUserClientPort {
    func requestNormalSleep() throws -> Bool { throw ClosedLidFailure.unsupported }
}
public protocol ClamshellObserving: Sendable {
    func observation() throws -> ClamshellObservation
}

/// Callable native candidate. Construction subscribes read-only; only the explicit
/// Bool operation can change lid policy. The separate terminal sleep operation
/// is an ordinary system request; both native operations additionally require root.
public struct ClamshellUserClientBackend: ClamshellBackend {
    private let port: any ClamshellUserClientPort
    private let observer: any ClamshellObserving
    private let clock: @Sendable () -> Double
    public init() throws {
        self.init(port: RootDomainClamshellPort(), observer: try NativeClamshellObserver(),
                  clock: { HelperClock.continuousSeconds() })
    }
    public init(port: any ClamshellUserClientPort, observer: any ClamshellObserving,
                clock: @escaping @Sendable () -> Double = { HelperClock.continuousSeconds() }) {
        self.port = port; self.observer = observer; self.clock = clock
    }
    public func observe() async throws -> ClamshellObservation { try observer.observation() }
    /// Controller/guardian may call this only after its journaled terminal clear.
    /// No automatic request occurs during construction, observation or discovery.
    public func requestNormalSleep() async throws -> Bool { try port.requestNormalSleep() }
    public func setLidSleepDisabled(_ disabled: Bool) async throws -> ClamshellCommandReceipt {
        let before = clock()
        guard before.isFinite, before >= 0 else { throw ClosedLidFailure.unavailable }
        try port.setLidSleepDisabled(disabled)
        // A receipt reports IOConnect acceptance only, never exact mask readback.
        let after = clock()
        return .init(disabled: disabled, acceptedAt: after.isFinite && after >= before ? after : before)
    }
}

/// Pinned XNU selector12 has exactly one UInt64 input and no output buffers.
/// No generic selector/key/path is exposed outside this private native boundary.
struct RootDomainClamshellPort: ClamshellUserClientPort {
    private let effectiveUID: @Sendable () -> UInt32
    private let open: @Sendable () -> UInt32
    private let call: @Sendable (UInt32, UInt32, UInt64) -> Int32
    private let close: @Sendable (UInt32) -> Void
    private let sleep: @Sendable (UInt32) -> Int32
    init() {
        self.init(effectiveUID: { geteuid() }, open: { IOPMFindPowerManagement(0) },
                  call: { connection, selector, input in
            var value = input
            return IOConnectCallMethod(connection, selector, &value, 1, nil, 0, nil, nil, nil, nil)
        }, close: { _ = IOServiceClose($0) }, sleep: { IOPMSleepSystem($0) })
    }
    init(effectiveUID: @escaping @Sendable () -> UInt32,
         open: @escaping @Sendable () -> UInt32,
         call: @escaping @Sendable (UInt32, UInt32, UInt64) -> Int32,
         close: @escaping @Sendable (UInt32) -> Void,
         sleep: @escaping @Sendable (UInt32) -> Int32 = { _ in kIOReturnUnsupported }) {
        self.effectiveUID = effectiveUID; self.open = open; self.call = call; self.close = close; self.sleep = sleep
    }
    func setLidSleepDisabled(_ disabled: Bool) throws {
        guard effectiveUID() == 0 else { throw ClosedLidFailure.missingTrust }
        let connection = open()
        guard connection != 0 else { throw ClosedLidFailure.unavailable }
        defer { close(connection) }
        guard call(connection, 12, disabled ? 1 : 0) == 0 else { throw ClosedLidFailure.commandRejected }
    }
    func requestNormalSleep() throws -> Bool {
        guard effectiveUID() == 0 else { throw ClosedLidFailure.missingTrust }
        let connection = open()
        guard connection != 0 else { throw ClosedLidFailure.unavailable }
        defer { close(connection) }
        guard sleep(connection) == 0 else { throw ClosedLidFailure.commandRejected }
        return true // System request accepted, never proof that the Mac slept.
    }
}
