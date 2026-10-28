import Foundation
import CoreFoundation
import PowerCore

/// Allowlisted battery diagnostics; unknown units remain raw, not guessed sensors.
enum BatteryDetailDecoder {
    static func lifetime(in registry: [String: Any]) -> (path: String, values: [String: Any]) {
        let battery = registry["BatteryData"] as? [String: Any] ?? [:]
        let pack = registry["AppleSmartBatteryPack"] as? [String: Any] ?? [:]
        let nested = pack["BatteryData"] as? [String: Any] ?? [:]
        for (path, value) in [("BatteryData/LifetimeData", battery["LifetimeData"]), ("AppleSmartBatteryPack/BatteryData/LifetimeData", nested["LifetimeData"]),
                              ("AppleSmartBatteryPack/LifetimeData", pack["LifetimeData"]), ("LifetimeData", registry["LifetimeData"])] {
            if let value = value as? [String: Any] { return (path, value) }
        }
        return ("LifetimeData", [:])
    }
    static func readings(registry: [String: Any], model: String?, qualification: RegistryQualification, at: Date) -> [CatalogReading] {
        let life = lifetime(in: registry)
        let battery = registry["BatteryData"] as? [String: Any] ?? [:]
        let pack = registry["AppleSmartBatteryPack"] as? [String: Any] ?? [:]
        let packData = pack["BatteryData"] as? [String: Any] ?? pack
        func field(_ key: String) -> Any? { registry[key] ?? battery[key] ?? packData[key] }
        let profile = qualification == .appleSilicon && model == "Mac17,3" && TelemetryDecoder.text(field("DeviceName")) == "bq40z651"
        let inference = "Scale inferred for the observed Mac17,3 / bq40z651 profile. Battery-reported lifetime history, not app history; independent sample age is unknown."
        var result: [CatalogReading] = []
        func add(_ id: String, _ value: CatalogValue?, raw: CatalogValue? = nil, path: String, provenance: TelemetryProvenance, reason: String) {
            result.append(.init(definition: BatteryCatalog.definition(id), value: value, rawValue: raw, source: "AppleSmartBattery", keyPath: path,
                collectedAt: at, provenance: provenance, freshness: .unknown, reason: reason))
        }
        func rawValue(_ value: Any) -> CatalogValue? {
            func exact(_ value: Any, depth: Int) -> CatalogValue? {
                guard depth <= 2 else { return nil }
                if let list = value as? [Any], list.count <= 16 {
                    let values = list.compactMap { exact($0, depth: depth + 1) }
                    return values.count == list.count ? .list(values) : nil
                }
                if let data = value as? Data { return data.count <= 4096 ? .text(data.base64EncodedString()) : nil }
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
                let encoding = String(cString: number.objCType)
                if ["c","s","i","l","q","C","S","I","L","Q"].contains(encoding) {
                    let text = number.stringValue
                    return Int64(text).map(CatalogValue.integer) ?? .text(text)
                }
                guard let decimal = TelemetryDecoder.number(value) else { return nil }
                return abs(decimal) <= 9_007_199_254_740_992 ? .decimal(decimal) : .text(number.stringValue)
            }
            return exact(value, depth: 0)
        }
        let lifeKeys = ["MaximumTemperature","MinimumTemperature","AverageTemperature","MaximumPackVoltage","MinimumPackVoltage","MaximumChargeCurrent","MaximumDischargeCurrent","TemperatureSamples","TotalOperatingTime","TimeAtHighSoc","UpdateTime"]
        let powerKeys = ["SystemLoad","SystemPowerIn","SystemCurrentIn","SystemVoltageIn","BatteryPower","AdapterEfficiencyLoss","SystemEnergyConsumed","WallEnergyEstimate",
                         "AccumulatedSystemLoad","SystemLoadAccumulatorCount","AccumulatedSystemPowerIn","SystemPowerInAccumulatorCount","AccumulatedBatteryPower","BatteryPowerAccumulatorCount",
                         "AccumulatedBatteryDischarge","BatteryDischargeAccumulatorCount","AccumulatedAdapterEfficiencyLoss","AdapterEfficiencyLossAccumulatorCount","AccumulatedSystemEnergyConsumed","AccumulatedWallEnergyEstimate","PowerTelemetryErrorCount"]
        func object(_ values: [String: Any], keys: [String]) -> CatalogValue? {
            let fields = Dictionary(uniqueKeysWithValues: keys.compactMap { key in values[key].flatMap(rawValue).map { (key, $0) } })
            return fields.isEmpty ? nil : .object(fields)
        }
        let rawReason = "Raw allowlisted battery counters. Units, interval or blob layout may be unqualified; no W/Wh conversion is implied."
        add("101", object(life.values, keys: lifeKeys), path: life.path, provenance: .raw, reason: rawReason)
        add("102", object(registry["PowerTelemetryData"] as? [String: Any] ?? [:], keys: powerKeys), path: "PowerTelemetryData", provenance: .raw, reason: rawReason)
        for (id, key, divisor, bounds) in [
            ("103","MaximumTemperature",1.0,-40.0...120.0), ("104","MinimumTemperature",1.0,-40.0...120.0), ("105","AverageTemperature",10.0,-40.0...120.0),
            ("106","MaximumPackVoltage",1000.0,1.0...100.0), ("107","MinimumPackVoltage",1000.0,1.0...100.0),
            ("108","MaximumChargeCurrent",1000.0,0.0...100.0), ("109","MaximumDischargeCurrent",1000.0,-100.0...0.0)
        ] {
            let raw = life.values[key].flatMap(TelemetryDecoder.number)
            let normalized = raw.map { $0 / divisor }.flatMap { profile && bounds.contains($0) ? $0 : nil }
            add(id, normalized.map(CatalogValue.decimal), raw: raw.map(CatalogValue.decimal), path: life.path + "/" + key, provenance: .inferred,
                reason: profile ? inference : "No lifetime scale profile is admitted for this device. The original counter remains in raw diagnostics.")
        }
        let count = TelemetryDecoder.integer(life.values["TemperatureSamples"]).flatMap { $0 >= 0 ? $0 : nil }
        add("110", count.map(CatalogValue.integer), path: life.path + "/TemperatureSamples", provenance: .reported, reason: "Reported sample count; cadence and coverage duration are unknown.")
        let update = TelemetryDecoder.number(life.values["UpdateTime"]).flatMap { seconds -> Date? in
            guard seconds >= 946684800, seconds <= at.timeIntervalSince1970 + 5 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        add("111", update.map(CatalogValue.date), path: life.path + "/UpdateTime", provenance: .inferred, reason: "Inferred Unix timestamp for the lifetime counter update, not the current power-sensor time.")
        let design = TelemetryDecoder.number(field("DesignCapacity")), full = TelemetryDecoder.number(field("AppleRawMaxCapacity") ?? field("NominalChargeCapacity") ?? field("FullChargeCapacity"))
        let difference: Double? = qualification != .unqualified && design.map({ $0 > 0 && $0 <= 100000 }) == true && full.map({ $0 >= 0 && $0 <= 100000 }) == true ? full! - design! : nil
        let fullKey = ["AppleRawMaxCapacity", "NominalChargeCapacity", "FullChargeCapacity"].first { field($0) != nil } ?? "FullChargeCapacity"
        add("112", difference.map(CatalogValue.decimal), path: "capacityDifference/" + fieldPath(fullKey) + "/" + fieldPath("DesignCapacity"), provenance: .estimated, reason: "Full-charge capacity minus design capacity; negative is below design. Not a remaining-life prediction; source ages may differ.")
        let nominal = TelemetryDecoder.number(field("NominalChargeCapacity")).flatMap { qualification != .unqualified && $0 > 0 && $0 <= 100000 ? $0 : nil }
        func fieldPath(_ key: String) -> String {
            if registry[key] != nil { return key }
            if battery[key] != nil { return "BatteryData/" + key }
            return pack["BatteryData"] != nil ? "AppleSmartBatteryPack/BatteryData/" + key : "AppleSmartBatteryPack/" + key
        }
        add("113", nominal.map(CatalogValue.decimal), path: fieldPath("NominalChargeCapacity"), provenance: .reported,
            reason: "Gauge nominal charge capacity; separate from AppleRawMaxCapacity and the macOS maximum-capacity percentage.")
        let extraKeys = ["CellVoltage","Qmax","StateOfCharge","PermanentFailureStatus","ErrorCondition","BatteryCellDisconnectCount","MaximumError"]
        let extra = Dictionary(uniqueKeysWithValues: extraKeys.compactMap { key in field(key).flatMap(rawValue).map { (fieldPath(key), $0) } })
        add("114", extra.isEmpty ? nil : .object(extra), path: "selected gauge properties", provenance: .raw, reason: rawReason)
        let nominalRatio = nominal.flatMap { nominal in design.flatMap { $0 > 0 && $0 <= 100000 ? nominal / $0 * 100 : nil } }
        add("115", nominalRatio.map(CatalogValue.decimal), path: "nominalCapacityRatio/" + fieldPath("NominalChargeCapacity") + "/" + fieldPath("DesignCapacity"), provenance: .estimated,
            reason: "Gauge nominal capacity divided by design capacity; distinct from raw full-charge retention and the macOS health estimate. Values above 100% are retained.")
        let rawCells = field("CellVoltage") as? [Any]
        let cells = rawCells?.compactMap(TelemetryDecoder.number)
        let packVoltage = TelemetryDecoder.number(field("Voltage"))
        let coherentCells = profile && rawCells?.count == 3 && cells?.count == 3 && cells?.allSatisfy({ (2500...4600).contains($0) }) == true && packVoltage.map { abs((cells?.reduce(0, +) ?? 0) - $0) <= 250 } == true
        add("041", coherentCells ? cells.map { .list($0.map { .decimal($0 / 1000) }) } : nil, raw: rawCells.flatMap(rawValue),
            path: fieldPath("CellVoltage"), provenance: .inferred, reason: "Cell-voltage mV scale inferred for the observed gauge profile, gated by three plausible cells and agreement with pack voltage. Independent cell sample age is unknown.")
        let spread = coherentCells ? cells.flatMap { values in values.max().flatMap { high in values.min().map { high - $0 } } } : nil
        add("042", spread.map(CatalogValue.decimal), path: "max(CellVoltage) - min(CellVoltage)", provenance: .estimated,
            reason: "Difference between the largest and smallest reported cell voltages; no battery-fault or authenticity diagnosis is implied.")
        return result
    }
}
