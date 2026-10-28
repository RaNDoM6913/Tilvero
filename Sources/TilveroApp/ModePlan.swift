import Foundation
import PowerCore

enum WorkMode: String, CaseIterable, Codable, Identifiable {
    case normal, economy, maximum
    var id: String { rawValue }
    var title: String {
        switch self { case .normal: "Normal"; case .economy: "Economy"; case .maximum: "Maximum autonomy" }
    }
}
enum ModeAction: String, Identifiable { case restore, charge, energy, displayIdle, brightness, cooling, backgroundJobs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .restore: "Release Tilvero settings"
        case .charge: "Charge limit"
        case .energy: "Low Power Mode"
        case .displayIdle: "Display idle"
        case .brightness: "Display brightness"
        case .cooling: "Cooling"
        case .backgroundJobs: "Background jobs"
        }
    }
}
enum ModeActionStatus: String { case available, excluded, preserved, applied, pending, failed
    var title: String {
        switch self {
        case .available: "Available"; case .excluded: "Excluded"; case .preserved: "Unchanged"
        case .applied: "Applied"; case .pending: "Pending"; case .failed: "Failed"
        }
    }
}
struct ModeActionRow: Identifiable, Equatable {
    let action: ModeAction
    var status: ModeActionStatus
    var detail: String
    var id: String { action.id }
}
struct ModePlan: Codable, Equatable {
    let mode: WorkMode
    var chargeTarget: Int?
    var lowPower: Bool
    var displayIdleMinutes: Int?
    var brightnessPercent: Int?
    func validate() throws {
        guard chargeTarget.map({ (80...100).contains($0) }) ?? true,
              displayIdleMinutes.map({ (1...30).contains($0) }) ?? true,
              brightnessPercent.map({ (10...100).contains($0) }) ?? true else { throw PolicyError.invalidPolicy }
    }
    func preview(chargeTargets: [Int], chargeAvailable: Bool, restoreAvailable: Bool) -> [ModeActionRow] {
        var rows: [ModeActionRow] = []
        if mode == .normal {
            rows.append(.init(action: .restore, status: restoreAvailable ? .available : .preserved,
                              detail: restoreAvailable ? "Restore only settings owned by Tilvero." : "No Tilvero settings to restore."))
        } else {
            if let chargeTarget {
                rows.append(.init(action: .charge, status: chargeAvailable && chargeTargets.contains(chargeTarget) ? .available : .excluded,
                                  detail: chargeAvailable && chargeTargets.contains(chargeTarget) ? "Lower targets wait for natural discharge." : "Native charging validation or an offered target is required."))
            }
            if lowPower {
                rows.append(.init(action: .energy, status: .excluded, detail: "Power mode writes require a qualified signed helper."))
            }
            if displayIdleMinutes != nil {
                rows.append(.init(action: .displayIdle, status: .excluded, detail: "Display idle control is not qualified on this Mac."))
            }
            if brightnessPercent != nil {
                rows.append(.init(action: .brightness, status: .excluded, detail: "Brightness control is not qualified on this display."))
            }
        }
        if mode != .normal {
            rows.append(.init(action: .cooling, status: .preserved, detail: "Cooling stays under its current system policy."))
        }
        rows.append(.init(action: .backgroundJobs, status: .preserved, detail: "Apps, downloads, audio and network stay running."))
        return rows
    }
}
struct ModeLibrary: Codable, Equatable {
    private var plans: [ModePlan] = WorkMode.allCases.map {
        ModePlan(mode: $0, chargeTarget: nil, lowPower: $0 != .normal,
                 displayIdleMinutes: $0 == .normal ? nil : $0 == .economy ? 5 : 2, brightnessPercent: nil)
    }
    func plan(_ mode: WorkMode) -> ModePlan { plans.first { $0.mode == mode } ?? Self().plan(mode) }
    mutating func save(_ plan: ModePlan) throws {
        try plan.validate()
        guard let index = plans.firstIndex(where: { $0.mode == plan.mode }) else { throw PolicyError.invalidPolicy }
        plans[index] = plan
    }
    static func load(_ data: Data?) -> Self {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data),
              value.plans.count == WorkMode.allCases.count,
              Set(value.plans.map(\.mode)) == Set(WorkMode.allCases),
              value.plans.allSatisfy({ (try? $0.validate()) != nil }) else { return .init() }
        return value
    }
}
struct ModeApplicationReport {
    let plan: ModePlan
    var rows: [ModeActionRow]
    var isComplete: Bool { !rows.contains { [.excluded, .failed, .pending, .available].contains($0.status) } }
}
