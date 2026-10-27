/// Prevents an accessory panel from becoming visible before macOS finishes
/// activating its application. A cancelled request cannot reappear later.
struct QuickPanelActivationGate {
    private(set) var isWaiting = false
    mutating func request(applicationIsActive: Bool) -> Bool {
        isWaiting = !applicationIsActive
        return applicationIsActive
    }
    mutating func applicationBecameActive() -> Bool {
        guard isWaiting else { return false }
        isWaiting = false
        return true
    }
    mutating func cancel() { isWaiting = false }
}
