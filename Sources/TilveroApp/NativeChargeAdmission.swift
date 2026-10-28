import Foundation
import Darwin
import ChargeBackends

/// Local qualification evidence for a user-space setting interface, not a
/// certificate, privileged-helper authorization, or proof of physical cutoff.
struct NativeChargeAdmission: Codable {
    static let version = 1
    let version: Int
    let environment: String
    let offeredTargets: [Int]
    let baseline: NativeChargeConfiguration
    let changed: NativeChargeSnapshot
    let restored: NativeChargeSnapshot
    let completedAt: Date

    static var currentEnvironment: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 && size < 256 else { return "unavailable" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unavailable" }
        return String(cString: bytes) + " / " + ProcessInfo.processInfo.operatingSystemVersionString + " / PowerUI-v1-fixed-ABI"
    }
    static func load(from url: URL, environment: String) -> Bool {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data) else { return false }
        return value.version == version && value.environment == environment && environment != "unavailable"
            && value.offeredTargets == value.changed.supportedTargets && value.offeredTargets == value.restored.supportedTargets
            && value.offeredTargets == value.offeredTargets.sorted() && Set(value.offeredTargets).count == value.offeredTargets.count
            && !value.offeredTargets.isEmpty && value.offeredTargets.allSatisfy({ (80...100).contains($0) })
            && value.changed.configuration.target == 100 && value.changed.policyMatches
            && value.restored.configuration == value.baseline && value.restored.policyMatches
            && value.changed.configuration != value.baseline
            && value.completedAt >= value.restored.collectedAt && value.completedAt.timeIntervalSinceNow <= 5
    }
}
