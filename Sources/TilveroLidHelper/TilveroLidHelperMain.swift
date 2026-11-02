import Foundation
import Darwin
import PowerPrivileged
import ClosedLidControl

/// Dedicated bootstrap: never constructs the production hardware/native-charge coordinator.
@main struct TilveroLidHelperMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--status"] {
            print("Tilvero lid-only helper: \(ClosedLidLimits.mechanism). No global SleepDisabled writer. Signed installation and bounded device qualification remain separate.")
            return
        }
        if args == ["--observe"] {
            do {
                let backend = try ClamshellUserClientBackend()
                let observation = try await backend.observe()
                print("Read-only clamshell observation; no selector mutation or journal opened.")
                print("Lid closed: \(String(describing: observation.lidClosed)); external display: \(String(describing: observation.externalDisplayPresent)); aggregate sleep allowed: \(String(describing: observation.aggregateSleepAllowed)); native witness present: \(observation.witness != nil)")
            } catch { fail("Read-only clamshell observation unavailable.", code: 69) }
            return
        }
        guard args.isEmpty || args == ["--guardian"] else { fail("Unsupported lid-helper role.", code: 64) }
        guard geteuid() == 0 else { fail("Use the normally authorized signed lid service.", code: 77) }
        do {
            let trust = try ClosedLidTrust.fromBundle()
            try trust.verify(helper: true)
            let backend = try ClamshellUserClientBackend()
            let currentBoot = HelperClock.bootID()
            guard currentBoot != "unavailable", !currentBoot.isEmpty else { throw ClosedLidFailure.unavailable }
            let store = try ClosedLidJournal(directory: URL(fileURLWithPath: "/Library/Application Support/TilveroClosedLidLab", isDirectory: true), requiredOwner: 0)
            let clock: @Sendable () -> Double = { HelperClock.continuousSeconds() }
            let boot: @Sendable () -> String = { currentBoot }
            if args == ["--guardian"] {
                let guardian = ClosedLidGuardian(backend: backend, journal: store, clock: clock, bootID: boot)
                _ = try await guardian.tick(startup: true, activeUserID: HelperClock.activeConsoleUserID())
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    do { _ = try await guardian.tick(activeUserID: HelperClock.activeConsoleUserID()) }
                    catch { /* Dedicated journal retains recovery failures; never reset an unknown bit. */ }
                }
            } else {
                let controller = ClosedLidController(backend: backend, journal: store, clock: clock, bootID: boot, maximumSessionSeconds: 120)
                _ = try await controller.recoverAtStartup(activeUserID: HelperClock.activeConsoleUserID())
                let listener = try ClosedLidXPCListener(trust: trust, service: controller)
                listener.resume()
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    _ = try? await controller.currentState()
                    withExtendedLifetime(listener) {}
                }
            }
        } catch { fail("Lid service did not start: trusted identity, native observer or verified recovery is required.", code: 78) }
    }
    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8)); exit(code)
    }
}
