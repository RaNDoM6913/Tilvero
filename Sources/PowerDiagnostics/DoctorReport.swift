import Foundation
import PowerCore

/// A bounded support artifact. Sensitive catalog fields and all raw values are excluded.
public struct DoctorReport: Codable, Sendable {
    public let formatVersion: Int
    public let generatedAt: Date
    public let isSimulation: Bool
    public let note: String
    public let fields: [DiagnosticField]
    public struct DiagnosticField: Codable, Sendable {
        public let id: String
        public let value: CatalogValue?
        public let unit: String?
        public let source: String
        public let keyPath: String
        public let collectedAt: Date
        public let sourceSampleAt: Date?
        public let monotonicAgeSeconds: TimeInterval?
        public let provenance: TelemetryProvenance
        public let availability: TelemetryAvailability
        public let freshness: TelemetryFreshness
        public let reason: String?
    }
    public init(snapshot: BatterySnapshot) {
        formatVersion = 1; generatedAt = Date(); isSimulation = snapshot.isDemo
        note = "Read-only observation report. Fixture and hardware validation are separate. Serials, local identity tokens, raw values and personal paths are excluded."
        fields = snapshot.catalog.filter { $0.privacy == .operational && $0.provenance != .raw }.prefix(BatteryCatalog.definitions.count).map {
            DiagnosticField(id: $0.id, value: Self.safeValue($0.value, depth: 0), unit: $0.unit,
                source: Self.redact($0.source), keyPath: Self.redact($0.keyPath), collectedAt: $0.collectedAt,
                sourceSampleAt: $0.sourceSampleAt, monotonicAgeSeconds: $0.monotonicAgeSeconds,
                provenance: $0.provenance, availability: $0.availability, freshness: $0.freshness,
                reason: $0.reason.map(Self.redact))
        }
    }
    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        guard data.count <= 256_000 else { throw DoctorReportError.sizeLimit }
        return data
    }
    private static func safeValue(_ value: CatalogValue?, depth: Int) -> CatalogValue? {
        guard depth <= 3 else { return .text("[depth limit]") }
        switch value {
        case .text(let text): return .text(redact(text))
        case .list(let values): return .list(values.prefix(24).compactMap { safeValue($0, depth: depth + 1) })
        case .object(let values):
            var result: [String: CatalogValue] = [:]
            for key in values.keys.sorted().prefix(24) {
                let lower = key.lowercased()
                guard !["serial", "token", "password", "account", "username", "path"].contains(where: lower.contains) else { continue }
                result[redact(key)] = safeValue(values[key], depth: depth + 1)
            }
            return .object(result)
        default: return value
        }
    }
    private static func redact(_ value: String) -> String {
        var result = String(value.prefix(512))
        for pattern in [#"/(Users|home|private|Volumes)/[^\s,;\"']+"#, #"(?i)(token|password|serial|account|username)\s*[:=]\s*[^\s,;]+"#] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[redacted]")
            }
        }
        return result
    }
}
public enum DoctorReportError: Error, Sendable { case sizeLimit }
