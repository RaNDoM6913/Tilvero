import Foundation
import Darwin

/// Read-only inputs. Hardware ownership is deliberately outside the first
/// Monitoring updater profile; even apparently restorable ownership defers it.
struct UpdateRecoverySnapshot {
    var nativeOwnership = false
    var nativeRecovery = false
    var helperOwnership = false
    var helperRecovery = false
    var lidOwnership = false
    var lidRecovery = false
    var operationInFlight = false
    var sleepTransition = false
    var persistentEvidence = false
    var externalController = false
    var environmentUnknown = false
    var awakeActive = false
    var timerActive = false

    var blockers: [String] {
        var result: [String] = []
        if operationInFlight { result.append("Finish the current operation before installing.") }
        if sleepTransition { result.append("Wait until sleep preparation or wake recovery has finished.") }
        if nativeOwnership || nativeRecovery { result.append("Review app-owned charging settings in Diagnostics.") }
        if helperOwnership || helperRecovery { result.append("Review app-owned helper settings in Diagnostics.") }
        if lidOwnership || lidRecovery { result.append("Review the closed-lid session in Diagnostics.") }
        if persistentEvidence { result.append("Saved control evidence needs manual review in Diagnostics.") }
        if externalController { result.append("Another controller is active. Keep this app open and try later.") }
        if environmentUnknown { result.append("Control recovery status could not be verified.") }
        return result
    }
    var consequences: [String] {
        (awakeActive ? ["End Keep Awake."] : []) + (timerActive ? ["Cancel the sleep timer."] : [])
    }
}

enum UpdateEvidenceProbe {
    enum Result: Equatable { case absent, present, unknown }

    /// No journal decoder, service connection, mkdir, or restoration belongs here.
    static func inspect(_ url: URL) -> Result {
        guard url.isFileURL, url.path.hasPrefix("/"),
              !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else { return .unknown }
        var path = ""
        let components = url.pathComponents.filter { $0 != "/" }
        for (index, component) in components.enumerated() {
            path += "/" + component
            var info = stat()
            guard lstat(path, &info) == 0 else { return errno == ENOENT ? .absent : .unknown }
            let type = info.st_mode & S_IFMT
            guard type != S_IFLNK else { return .unknown }
            if index < components.count - 1, type != S_IFDIR { return .unknown }
        }
        return components.isEmpty ? .unknown : .present
    }
}
