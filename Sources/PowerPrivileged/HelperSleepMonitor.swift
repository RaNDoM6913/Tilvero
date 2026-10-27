import Foundation
import IOKit
import IOKit.pwr_mgt
import PowerCore

// IOMessage.h defines these through function-like macros that Swift does not import.
// iokit_common_msg(code) = (0x38 << 26) | code; values are the system notification ABI.
private enum RootPowerMessage {
    static let canSleep: UInt32 = (0x38 << 26) | 0x270
    static let willSleep: UInt32 = (0x38 << 26) | 0x280
    static let hasPoweredOn: UInt32 = (0x38 << 26) | 0x300
}

/// Root-helper sleep notifications use an IOKit dispatch source, independently of the GUI process.
public final class HelperSleepMonitor: @unchecked Sendable {
    private let controller: PrivilegedController
    private let queue = DispatchQueue(label: "local.tilvero.helper.power-events", qos: .utility)
    private var notificationPort: IONotificationPortRef?
    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    public init(controller: PrivilegedController) throws {
        self.controller = controller
        let callback: IOServiceInterestCallback = { refcon, _, message, argument in
            guard let refcon else { return }
            let monitor = Unmanaged<HelperSleepMonitor>.fromOpaque(refcon).takeUnretainedValue()
            let notificationID = Int(bitPattern: argument)
            switch message {
            case RootPowerMessage.canSleep:
                // This helper never vetoes ordinary system sleep.
                IOAllowPowerChange(monitor.rootPort, notificationID)
            case RootPowerMessage.willSleep:
                Task { [monitor] in
                    await monitor.controller.prepareForSleep()
                    IOAllowPowerChange(monitor.rootPort, notificationID)
                }
            case RootPowerMessage.hasPoweredOn: Task { await monitor.controller.didWake() }
            default: break
            }
        }
        rootPort = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &notificationPort, callback, &notifier)
        guard rootPort != 0, let notificationPort else { throw ControlUnavailableError(reason: "The helper could not subscribe to system sleep/wake safety events.") }
        IONotificationPortSetDispatchQueue(notificationPort, queue)
    }
    deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if rootPort != 0 { IOServiceClose(rootPort) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }
}
