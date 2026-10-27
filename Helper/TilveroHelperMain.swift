import Foundation
import Darwin
import PowerPrivileged
import PowerCore
import ChargeBackends
import FanBackends

@main struct TilveroHelperMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--status"] {
            print("Tilvero helper protocol \(HelperEnvelope.protocolVersion). Physical writes remain gated by signed trust and hardware qualification.")
            return
        }
        if arguments == ["--discover"] {
            let charge = await NativeChargeBackend().discover(), fans = await SMCFanBackend().discover()
            let energy = try? await EnergyModeBackend().read()
            print("Read-only discovery. No control writes or helper registration occurred.")
            print("Native client: \(charge.clientPresent); registered targets: \(String(describing: charge.registeredTargets)); readiness: \(charge.capability.readiness.rawValue)")
            print("\(charge.capability.reason)")
            print("Fan records discovered: \(fans.fans.count); enumeration readiness: \(fans.capability.readiness.rawValue). \(fans.capability.reason)")
            print("Battery energy mode: \(energy?[.battery]?.rawValue ?? "unavailable"); adapter energy mode: \(energy?[.adapter]?.rawValue ?? "unavailable")")
            return
        }
        guard arguments.isEmpty || arguments == ["--guardian"] else { fail("Unsupported helper mode.", code: 64) }
        guard geteuid() == 0 else { fail("The authenticated launchd helper requires its normal privileged service context.", code: 77) }
        do {
            let trust = try HelperTrustConfiguration.fromBundle()
            try trust.verifyCurrentProcess(helper: true)
            let journal = try SecureJournal()
            let hardware = SystemPrivilegedHardware()
            let guardian = RecoveryGuardian(hardware: hardware, journal: journal)
            if arguments == ["--guardian"] {
                while !Task.isCancelled {
                    do { _ = try await guardian.recover() } catch { /* Root journal retains bounded failure evidence. */ }
                    try await Task.sleep(for: .seconds(2))
                }
            } else {
                // Await on the cooperative executor; no main-thread semaphore can block startup recovery.
                _ = try await guardian.recover(startup: true)
                let controller = PrivilegedController(hardware: hardware, journal: journal)
                let powerEvents = try HelperSleepMonitor(controller: controller)
                let policyLoop = Task {
                    while !Task.isCancelled {
                        await controller.tickFanPolicy()
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                defer { policyLoop.cancel() }
                let listener = try AuthenticatedHelperListener(trust: trust, controller: controller)
                listener.resume()
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(60))
                    withExtendedLifetime(listener) {}
                    withExtendedLifetime(powerEvents) {}
                }
            }
        } catch { fail("Tilvero helper remains disabled: trusted signing configuration or verified recovery is unavailable.", code: 78) }
    }
    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8)); exit(code)
    }
}
