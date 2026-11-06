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

/// Whether presenting the quick panel may skip activating the application.
enum QuickPanelActivationPolicy {
    /// Activating raises the app's windows and switches to the Space that holds them. When the details window is
    /// visible on another Space, show the panel without activating so the current desktop stays put.
    static func avoidsActivation(applicationIsActive: Bool, detailsWindowOnAnotherSpace: Bool) -> Bool {
        !applicationIsActive && detailsWindowOnAnotherSpace
    }
}
