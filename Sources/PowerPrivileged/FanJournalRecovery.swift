import Foundation
import PowerCore

enum FanJournalRecovery {
    /// Reconcile each owned fan independently. A foreign register yields the entire affected fan.
    static func restore(hardware: any PrivilegedHardware, journal: SecureJournal, record: inout OwnershipJournal, lock: JournalLock) async throws {
        guard var entry = record.entries[.fans], !entry.fanSteps.isEmpty else { throw PrivilegeError.recoveryRequired }
        var unresolved = false
        for fanID in entry.fanOriginals.keys.sorted() {
            let indices = entry.fanSteps.indices.filter { entry.fanSteps[$0].register.fanID == fanID && entry.fanSteps[$0].phase != .restored }
            guard !indices.isEmpty, let original = entry.fanOriginals[fanID] else { continue }
            do {
                let mode = try await hardware.readFanRegister(.automatic(fanID: fanID))
                let target = try await hardware.readFanRegister(.target(fanID: fanID))
                func owned(_ register: FanRegister, current: FanRegisterValue, original: FanRegisterValue) -> Bool {
                    if current == original { return true }
                    return indices.contains { index in
                        let step = entry.fanSteps[index]
                        return step.register == register && (current == step.intended || current == step.applied || current == step.previous)
                    }
                }
                guard owned(.automatic(fanID: fanID), current: mode, original: .automatic(original.automatic)),
                      owned(.target(fanID: fanID), current: target, original: .rpm(original.targetRPM)) else {
                    throw ControlUnavailableError(reason: "An external controller changed fan \(fanID); this fan was left untouched.")
                }
                // Applying writes target then manual mode; reversing restores Auto before the original target.
                for index in indices.reversed() {
                    var step = entry.fanSteps[index]
                    let current = try await hardware.readFanRegister(step.register)
                    guard current == step.original || current == step.intended || current == step.applied || current == step.previous else { throw PrivilegeError.recoveryRequired }
                    step.phase = .recovering; entry.fanSteps[index] = step
                    record.entries[.fans] = entry; try journal.write(record, lock: lock)
                    if current != step.original { try await hardware.writeFanRegister(step.register, value: step.original) }
                    guard try await hardware.readFanRegister(step.register) == step.original else { throw PolicyError.readbackMismatch }
                    step.phase = .restored; entry.fanSteps[index] = step
                    record.entries[.fans] = entry; try journal.write(record, lock: lock)
                }
            } catch {
                unresolved = true; entry.failure = String(String(describing: error).prefix(512))
                entry.phase = .unresolved; record.entries[.fans] = entry; try journal.write(record, lock: lock)
            }
        }
        guard !unresolved, entry.fanSteps.allSatisfy({ $0.phase == .restored }) else { throw PrivilegeError.recoveryRequired }
    }
}
