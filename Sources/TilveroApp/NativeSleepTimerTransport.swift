import Foundation
import Darwin
import IOKit.pwr_mgt
import SystemConfiguration

enum NativeSleepTimerError: LocalizedError {
    case inactiveSession, rejected(Int32)
    var errorDescription: String? {
        switch self {
        case .inactiveSession: L10n.text("The sleep timer requires the current console user.")
        case .rejected(let code): L10n.text("macOS rejected the sleep request.") + " (\(code))"
        }
    }
}

/// Explicit system sleep; this never releases foreign idle assertions or changes power settings.
@MainActor final class NativeSleepTimerTransport: SleepTimerTransport {
    private let consoleCheck: @MainActor () -> Bool
    private let request: @MainActor () -> Int32
    private let idleHold: KeepAwakeService
    init(consoleCheck: @escaping @MainActor () -> Bool = NativeSleepTimerTransport.currentConsoleMatches,
         request: @escaping @MainActor () -> Int32 = NativeSleepTimerTransport.submitRequest,
         idleHoldTransport: any KeepAwakeTransport = NativeKeepAwakeTransport()) {
        self.consoleCheck = consoleCheck; self.request = request
        // Separate from the visible Keep Awake mode: ownership never crosses modes.
        idleHold = KeepAwakeService(driver: idleHoldTransport)
    }
    var hasIdleHold: Bool { idleHold.hasOwnedAssertion }
    func acquireIdleHold(seconds: Int) throws { try idleHold.start(seconds: seconds) }
    func extendIdleHold() throws { try idleHold.extend(by: 900) }
    func releaseIdleHold() throws { try idleHold.stop() }
    func isCurrentConsoleSession() -> Bool { consoleCheck() }
    func requestSleep() throws {
        guard consoleCheck() else { throw NativeSleepTimerError.inactiveSession }
        let result = request()
        guard result == kIOReturnSuccess else { throw NativeSleepTimerError.rejected(result) }
    }
    static func consoleMatches(name: String?, consoleUID: uid_t, processUID: uid_t) -> Bool {
        guard let name, !name.isEmpty, name != "loginwindow", consoleUID != 0 else { return false }
        return consoleUID == processUID
    }
    private static func currentConsoleMatches() -> Bool {
        var uid: uid_t = 0
        let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?
        return consoleMatches(name: name, consoleUID: uid, processUID: getuid())
    }
    private static func submitRequest() -> Int32 {
        let connection = IOPMFindPowerManagement(0)
        guard connection != 0 else { return kIOReturnNotOpen }
        defer { IOServiceClose(connection) }
        return IOPMSleepSystem(connection)
    }
}
