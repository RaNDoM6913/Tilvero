import Foundation

public enum TelemetryProvenance: String, Codable, Sendable, Equatable {
    case reported
    case measured
    case estimated
    case inferred
    case configured, observed, recorded, reference, raw
}

public enum TelemetryAvailability: String, Codable, Sendable, Equatable {
    case available
    case unavailable
    case notApplicable
    case requiresPermission
    case temporarilyUnavailable
    case invalid
}

public enum TelemetryFreshness: String, Codable, Sendable, Equatable {
    case fresh
    case stale
    case unknown
}

/// A value and its evidence. Missing values are never replaced by plausible defaults.
///
/// `collectedAt` records collection, not necessarily the hardware sample time.
/// A future provider may add source sample time and monotonic age; this starter
/// does not manufacture them from a new read of an unchanged source snapshot.
public struct TelemetryReading<Value: Sendable & Equatable>: Sendable, Equatable {
    public let value: Value?
    public let source: String
    public let unit: String?
    public let collectedAt: Date
    public let sourceSampleAt: Date?
    public let monotonicAgeSeconds: TimeInterval?
    public let provenance: TelemetryProvenance
    public let availability: TelemetryAvailability
    public let freshness: TelemetryFreshness
    public let reason: String?

    public init(
        value: Value?,
        source: String,
        unit: String? = nil,
        collectedAt: Date = Date(),
        sourceSampleAt: Date? = nil,
        monotonicAgeSeconds: TimeInterval? = nil,
        provenance: TelemetryProvenance = .reported,
        availability: TelemetryAvailability? = nil,
        freshness: TelemetryFreshness? = nil,
        reason: String? = nil
    ) {
        self.value = value
        self.source = source
        self.unit = unit
        self.collectedAt = collectedAt
        self.sourceSampleAt = sourceSampleAt
        self.monotonicAgeSeconds = monotonicAgeSeconds.flatMap { $0 >= 0 && $0.isFinite ? $0 : nil }
        self.provenance = provenance
        if value == nil {
            self.availability = availability == .available ? .invalid : (availability ?? .unavailable)
            self.freshness = .unknown
            self.reason = reason ?? (availability == .available
                ? "The source marked this reading available without supplying a value."
                : nil)
        } else {
            self.availability = availability ?? .available
            self.freshness = freshness ?? .fresh
            self.reason = reason
        }
    }

    public static func unavailable(
        reason: String,
        source: String = "Unavailable",
        at date: Date = Date()
    ) -> Self {
        Self(
            value: nil,
            source: source,
            collectedAt: date,
            availability: .unavailable,
            freshness: .unknown,
            reason: reason
        )
    }
}

extension TelemetryReading: Codable where Value: Codable {}

/// A compact compatibility surface plus the complete availability catalog.
public struct BatterySnapshot: Codable, Sendable, Equatable {
    public let chargePercent: TelemetryReading<Int>
    public let isCharging: TelemetryReading<Bool>
    public let isExternalPower: TelemetryReading<Bool>
    public let cycleCount: TelemetryReading<Int>
    public let manufacturer: TelemetryReading<String>
    public let temperatureCelsius: TelemetryReading<Double>
    public let voltageVolts: TelemetryReading<Double>
    public let currentAmps: TelemetryReading<Double>
    public let timeRemainingSeconds: TelemetryReading<Double>
    public let collectedAt: Date
    public let isDemo: Bool
    public let catalog: [CatalogReading]
    public let monotonicTime: TimeInterval?
    public let batteryIdentityToken: String?

    public init(
        chargePercent: TelemetryReading<Int>? = nil,
        isCharging: TelemetryReading<Bool>? = nil,
        isExternalPower: TelemetryReading<Bool>? = nil,
        cycleCount: TelemetryReading<Int>? = nil,
        manufacturer: TelemetryReading<String>? = nil,
        temperatureCelsius: TelemetryReading<Double>? = nil,
        voltageVolts: TelemetryReading<Double>? = nil,
        currentAmps: TelemetryReading<Double>? = nil,
        timeRemainingSeconds: TelemetryReading<Double>? = nil,
        collectedAt: Date = Date(),
        isDemo: Bool = false,
        catalog: [CatalogReading] = [],
        monotonicTime: TimeInterval? = nil,
        batteryIdentityToken: String? = nil
    ) {
        let reason = "This field was not supplied by the provider."
        self.chargePercent = chargePercent ?? .unavailable(reason: reason, at: collectedAt)
        self.isCharging = isCharging ?? .unavailable(reason: reason, at: collectedAt)
        self.isExternalPower = isExternalPower ?? .unavailable(reason: reason, at: collectedAt)
        self.cycleCount = cycleCount ?? .unavailable(reason: reason, at: collectedAt)
        self.manufacturer = manufacturer ?? .unavailable(reason: reason, at: collectedAt)
        self.temperatureCelsius = temperatureCelsius ?? .unavailable(reason: reason, at: collectedAt)
        self.voltageVolts = voltageVolts ?? .unavailable(reason: reason, at: collectedAt)
        self.currentAmps = currentAmps ?? .unavailable(reason: reason, at: collectedAt)
        self.timeRemainingSeconds = timeRemainingSeconds ?? .unavailable(reason: reason, at: collectedAt)
        self.collectedAt = collectedAt
        self.isDemo = isDemo
        var supplied = catalog
        func add<T>(_ id: String, _ reading: TelemetryReading<T>, _ transform: (T) -> CatalogValue) {
            guard !supplied.contains(where: { $0.id == id }) else { return }
            supplied.append(CatalogReading(definition: BatteryCatalog.definition(id), value: reading.value.map(transform),
                source: reading.source, collectedAt: reading.collectedAt, sourceSampleAt: reading.sourceSampleAt,
                monotonicAgeSeconds: reading.monotonicAgeSeconds, provenance: reading.provenance,
                availability: reading.availability, freshness: reading.freshness, reason: reading.reason))
        }
        add("011", self.chargePercent) { .integer(Int64($0)) }
        add("013", self.isCharging) { .boolean($0) }
        add("015", self.isExternalPower) { .boolean($0) }
        add("027", self.cycleCount) { .integer(Int64($0)) }
        add("057", self.manufacturer) { .text($0) }
        add("039", self.temperatureCelsius) { .decimal($0) }
        add("035", self.voltageVolts) { .decimal($0) }
        add("036", self.currentAmps) { .decimal($0) }
        add("067", self.timeRemainingSeconds) { .decimal($0) }
        self.catalog = BatteryCatalog.complete(supplied, at: collectedAt)
        self.monotonicTime = monotonicTime
        self.batteryIdentityToken = batteryIdentityToken
    }

    public static func unavailable(
        at date: Date = Date(),
        reason: String = "Battery information is not currently available."
    ) -> Self {
        Self(
            chargePercent: .unavailable(reason: reason, at: date),
            isCharging: .unavailable(reason: reason, at: date),
            isExternalPower: .unavailable(reason: reason, at: date),
            cycleCount: .unavailable(reason: reason, at: date),
            manufacturer: .unavailable(reason: reason, at: date),
            temperatureCelsius: .unavailable(reason: reason, at: date),
            voltageVolts: .unavailable(reason: reason, at: date),
            currentAmps: .unavailable(reason: reason, at: date),
            timeRemainingSeconds: .unavailable(reason: reason, at: date),
            collectedAt: date,
            isDemo: false
        )
    }

    /// Synthetic fixture only. Production observation must never fall back to this.
    public static func demo(at date: Date = Date()) -> Self {
        Self(
            chargePercent: .init(value: 76, source: "Demo fixture", unit: "%", collectedAt: date),
            isCharging: .init(value: true, source: "Demo fixture", collectedAt: date),
            isExternalPower: .init(value: true, source: "Demo fixture", collectedAt: date),
            cycleCount: .init(value: 124, source: "Demo fixture", unit: "cycles", collectedAt: date),
            manufacturer: .unavailable(reason: "No manufacturer is invented for demo mode.", source: "Demo fixture", at: date),
            temperatureCelsius: .init(value: 31.2, source: "Demo fixture", unit: "°C", collectedAt: date),
            voltageVolts: .init(value: 12.1, source: "Demo fixture", unit: "V", collectedAt: date),
            currentAmps: .init(value: 1.2, source: "Demo fixture", unit: "A", collectedAt: date),
            timeRemainingSeconds: .unavailable(reason: "Runtime is unavailable while charging in this fixture.", source: "Demo fixture", at: date),
            collectedAt: date,
            isDemo: true
        )
    }
}

extension BatterySnapshot {
    /// A failed collection retains visible last-good values without refreshing their
    /// collection/sample time. Stale values remain unsuitable for control or history.
    public func retainingPreviousReadings(_ previous: BatterySnapshot) -> BatterySnapshot {
        guard !isDemo, !previous.isDemo else { return self }
        if let old = previous.batteryIdentityToken, let new = batteryIdentityToken, old != new { return self }
        if case .boolean(false)? = catalog.first(where: { $0.id == "006" })?.value { return self }
        // A working new source that lost a formerly known identity cannot be assumed
        // to be the same pack. A total collection failure may retain a labelled cache.
        if previous.batteryIdentityToken != nil, batteryIdentityToken == nil, chargePercent.value != nil { return self }
        let currentUptime = monotonicTime ?? ProcessInfo.processInfo.systemUptime
        let elapsed = previous.monotonicTime.flatMap { old in currentUptime >= old ? currentUptime - old : nil }
        let oldFields = Dictionary(previous.catalog.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let retained = catalog.map { field -> CatalogReading in
            guard let old = oldFields[field.id], let elapsed else { return field }
            return field.retainingPrevious(old, age: (old.monotonicAgeSeconds ?? 0) + elapsed)
        }
        func retain<T>(_ current: TelemetryReading<T>, _ old: TelemetryReading<T>) -> TelemetryReading<T> {
            guard current.value == nil, let value = old.value, let elapsed else { return current }
            return TelemetryReading(value: value, source: old.source, unit: old.unit, collectedAt: old.collectedAt,
                sourceSampleAt: old.sourceSampleAt, monotonicAgeSeconds: (old.monotonicAgeSeconds ?? 0) + elapsed,
                provenance: old.provenance, availability: .temporarilyUnavailable, freshness: .stale,
                reason: "The latest collection failed; this is the last valid observation. " + (current.reason ?? "Source sample time may be unknown."))
        }
        return BatterySnapshot(chargePercent: retain(chargePercent, previous.chargePercent),
            isCharging: retain(isCharging, previous.isCharging), isExternalPower: retain(isExternalPower, previous.isExternalPower),
            cycleCount: retain(cycleCount, previous.cycleCount), manufacturer: retain(manufacturer, previous.manufacturer),
            temperatureCelsius: retain(temperatureCelsius, previous.temperatureCelsius), voltageVolts: retain(voltageVolts, previous.voltageVolts),
            currentAmps: retain(currentAmps, previous.currentAmps), timeRemainingSeconds: retain(timeRemainingSeconds, previous.timeRemainingSeconds),
            collectedAt: collectedAt, catalog: retained, monotonicTime: currentUptime, batteryIdentityToken: batteryIdentityToken ?? previous.batteryIdentityToken)
    }
}
