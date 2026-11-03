import Foundation
import Observation

/// No installation or termination authority is derived from release discovery.
/// A staging session blocks ordinary quit; only fresh, explicit final consent
/// can acquire the model's exclusion and authorize the installer's quit event.
@MainActor @Observable
final class UpdateInstallGate {
    private(set) var installationBlocksQuit = false
    private(set) var validatedHandoffAllowsTermination = false
    private(set) var blockers: [String] = []
    private var preparing = false
    private var generation = 0
    private let readiness: () -> [String]
    private let prepare: () async -> Bool
    private let release: () -> Void

    init(readOnlyReadiness: @escaping () -> [String],
         prepareAfterExplicitConsent: @escaping () async -> Bool,
         releaseInstallationExclusion: @escaping () -> Void) {
        readiness = readOnlyReadiness
        prepare = prepareAfterExplicitConsent
        release = releaseInstallationExclusion
    }

    /// Sparkle can discover a cached already-installing update while checking.
    /// Guard ordinary quit before asking Sparkle to resume any session. This is
    /// read-only with respect to model recovery and acquires no control lease.
    func protectUpdateSession() {
        installationBlocksQuit = true
        validatedHandoffAllowsTermination = false
    }

    func beginStaging(explicitConsent: Bool) -> Bool {
        guard explicitConsent, !preparing else { return false }
        blockers = readiness()
        guard blockers.isEmpty else { return false }
        installationBlocksQuit = true
        validatedHandoffAllowsTermination = false
        return true
    }

    func authorizeHandoff(explicitConsent: Bool) async -> Bool {
        guard explicitConsent, installationBlocksQuit, !preparing else { return false }
        validatedHandoffAllowsTermination = false
        blockers = readiness()
        guard blockers.isEmpty else { return false }
        preparing = true
        let token = generation
        let prepared = await prepare()
        preparing = false
        guard token == generation else { release(); return false }
        blockers = readiness()
        guard prepared, blockers.isEmpty else { release(); return false }
        validatedHandoffAllowsTermination = true
        return true
    }

    /// Retrying a previously canceled quit is another explicit install decision.
    func invalidateHandoff() { validatedHandoffAllowsTermination = false }

    func finish() {
        generation += 1
        validatedHandoffAllowsTermination = false
        installationBlocksQuit = false
        release()
    }
}
