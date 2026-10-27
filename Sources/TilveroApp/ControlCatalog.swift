import Foundation
import PowerCore

/// Presentation adapts independent facts; a requested target is never used as readback.
enum ControlCatalog {
    static func readings(state: ChargePolicyState?, capabilities: [ControlCapability], fans: FanObservation?, isDemo: Bool, connected: Bool, at: Date) -> [CatalogReading] {
        let source = isDemo ? "Explicit simulation" : "Control capability/readback provider"
        func field(_ id: String, _ value: CatalogValue?, provenance: TelemetryProvenance = .observed, reason: String? = nil) -> CatalogReading {
            CatalogReading(definition: BatteryCatalog.definition(id), value: value, source: source, collectedAt: at,
                provenance: provenance, freshness: .unknown, reason: reason)
        }
        func capability(_ backend: String) -> CatalogValue? {
            guard let cap = capabilities.first(where: { $0.backend == backend }) else { return nil }
            return .object(["readiness": .text(cap.readiness.rawValue), "reason": .text(cap.reason)])
        }
        let requested: Int?
        switch state?.requested { case .ceiling(let value): requested = value; case .fullOnce: requested = 100; default: requested = nil }
        var rows = [field("008", capability("native-powerui")), field("010", capability("smc-standard-fan")),
            field("018", requested.map { .integer(Int64($0)) }, provenance: .configured),
            field("020", (connected || isDemo ? state?.appliedTarget : nil).map { .integer(Int64($0)) }, reason: connected || isDemo ? nil : "No authenticated current configuration readback is available."),
            field("021", .text(state?.requested == .fullOnce ? "requested" : "none"), provenance: .configured)]
        if let fans {
            rows.append(field("087", .integer(Int64(fans.descriptors.count))))
            rows.append(field("089", .object(fans.actualRPM.mapValues { .integer(Int64($0)) })))
            rows.append(field("092", .object(fans.autoMode.mapValues { .text($0 ? "System Auto" : "Manual") })))
            rows.append(field("093", .object(fans.targetRPM.mapValues { .integer(Int64($0)) })))
        }
        rows.append(field("095", .list(capabilities.map { .text("\($0.backend): \($0.readiness.rawValue)") })))
        return rows
    }
}
