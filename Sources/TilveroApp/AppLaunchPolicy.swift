import Foundation

/// Immutable for this process. No preference or later UI action promotes a
/// monitoring session into a controller session.
struct AppLaunchPolicy: Equatable {
    static let knownBundleIdentifiers: Set<String> = [
        "local.tilvero.prototype", "io.github.random6913.tilvero", "local.tilvero.lab"
    ]
    private enum Reason: Equatable { case release, requested, sibling, leaseUnavailable, simulation }
    private let reason: Reason?
    var monitoringOnly: Bool { reason != nil }
    var monitoringReasonKey: String? {
        switch reason {
        case .release: "This build runs a monitoring-only session."
        case .requested: "Monitoring-only session was selected at launch."
        case .sibling: "Another Tilvero is running. This session monitors only; reopen it after the other app quits to use controls."
        case .leaseUnavailable: "Exclusive control is unavailable. This session monitors only; reopen it when the other controller has finished."
        case .simulation: nil // Existing simulation labeling remains authoritative.
        case nil: nil
        }
    }

    static func resolve(metadata: [String: Any], arguments: [String] = [], runningBundleIdentifiers: Set<String> = []) -> Self {
        if metadata["TilveroReleaseMode"] as? String == "monitoring" { return Self(reason: .release) }
        if arguments.contains("--monitor-only") { return Self(reason: .requested) }
        if arguments.contains("--demo") { return Self(reason: .simulation) }
        if !knownBundleIdentifiers.isDisjoint(with: runningBundleIdentifiers) { return Self(reason: .sibling) }
        return Self(reason: nil)
    }

    static func current(bundle: Bundle = .main, arguments: [String] = CommandLine.arguments) -> Self {
        resolve(metadata: bundle.infoDictionary ?? [:], arguments: arguments)
    }

    func tighteningForUnavailableController() -> Self {
        monitoringOnly ? self : Self(reason: .leaseUnavailable)
    }
}
