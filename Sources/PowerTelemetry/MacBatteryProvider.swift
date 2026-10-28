import Foundation
import CoreFoundation
import CryptoKit
import PowerCore
#if os(macOS)
import IOKit
import IOKit.ps
import Darwin
#endif

/// Read-only IOKit observation. No helper, subprocess or hardware write is involved.
public struct MacBatteryProvider: Sendable {
    private let identitySalt: String
    private let qualification: RegistryQualification
    private let sampleClock = SourceSampleClock()
    public init(identitySalt: String = "", qualification: RegistryQualification = .platformDefault) {
        self.identitySalt = identitySalt; self.qualification = qualification
    }

    public func readSnapshot() -> BatterySnapshot {
        #if os(macOS)
        let now = Date()
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() else {
            return .unavailable(at: now, reason: "IOPowerSources did not return a snapshot.")
        }
        let descriptions = (list as NSArray).compactMap { handle -> [String: Any]? in
            IOPSGetPowerSourceDescription(info, handle as CFTypeRef)?.takeUnretainedValue() as? [String: Any]
        }
        let description = Self.internalBattery(in: descriptions)
        let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] ?? [:]
        return normalize(powerSource: description, registry: readBatteryRegistry(), adapter: adapter,
            aggregateTimeRemaining: IOPSGetTimeRemainingEstimate(), at: now,
            uptime: ProcessInfo.processInfo.systemUptime,
            system: ["model": sysctlString("hw.model") ?? "", "chip": sysctlString("machdep.cpu.brand_string") ?? "",
                "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "build": sysctlString("kern.osversion") ?? "", "thermal": thermalState])
        #else
        return .unavailable(reason: "Live battery telemetry requires macOS.")
        #endif
    }

    /// Injectable source dictionaries let fixtures exercise real normalization without platform writes.
    public func normalize(powerSource: [String: Any]?, registry: [String: Any] = [:], adapter: [String: Any] = [:],
                          aggregateTimeRemaining: Double = -1, at now: Date = Date(), uptime: TimeInterval? = nil,
                          system: [String: String] = [:]) -> BatterySnapshot {
        var fields: [CatalogReading] = []
        // AppleSmartBattery publishes UpdateTime after completing a polling path.
        // Values inside PowerTelemetryData have no independently qualified timestamp.
        let epoch = TelemetryDecoder.number(registry["UpdateTime"])
        let sampleAt = epoch.flatMap { seconds -> Date? in
            let date = Date(timeIntervalSince1970: seconds)
            return seconds >= 946684800 && date <= now.addingTimeInterval(5) ? date : nil
        }
        let sourceAge = sampleAt.flatMap { sampleClock.age(sample: $0, collected: now, uptime: uptime) }
        let sourceFreshness: TelemetryFreshness = sourceAge.map { $0 > 120 ? .stale : .fresh } ?? .unknown
        func timestamp(_ raw: Any?) -> Date? {
            guard let seconds = TelemetryDecoder.number(raw), seconds >= 946684800 else { return nil }
            let date = Date(timeIntervalSince1970: seconds)
            return date <= now.addingTimeInterval(5) ? date : nil
        }
        func fieldSample(_ id: String, _ key: String) -> (Date?, TimeInterval?, TelemetryFreshness) {
            let date: Date?
            if key.contains("LifetimeData") { return (nil, nil, .unknown) }
            else if key.hasPrefix("PowerTelemetryData/") { return (nil, nil, .unknown) }
            else if ["027", "060", "061"].contains(id) { date = timestamp(registry["FullPathUpdated"]) }
            else if ["029", "057", "058", "059", "062", "063"].contains(id) { date = timestamp(registry["BootPathUpdated"]) }
            else { date = sampleAt }
            // Different poll paths can have independently old snapshots.
            let age = date == sampleAt ? sourceAge : date.flatMap { d in
                let delta = now.timeIntervalSince(d)
                return delta >= 0 && uptime != nil ? delta : nil
            }
            return (date, age, age.map { $0 > 120 ? .stale : .fresh } ?? .unknown)
        }
        func put(_ id: String, _ value: CatalogValue?, source: String, key: String,
                 raw: CatalogValue? = nil, provenance: TelemetryProvenance = .reported, reason: String? = nil) {
            let timing = source == "AppleSmartBattery" ? fieldSample(id, key) : (nil, nil, TelemetryFreshness.unknown)
            fields.append(CatalogReading(definition: BatteryCatalog.definition(id), value: value, rawValue: raw,
                source: source, keyPath: key, collectedAt: now,
                sourceSampleAt: timing.0, monotonicAgeSeconds: timing.1,
                provenance: provenance,
                freshness: source == "ProcessInfo" || source == "sysctl" ? .fresh : timing.2,
                reason: reason))
        }
        func string(_ value: Any?) -> CatalogValue? { TelemetryDecoder.text(value).map(CatalogValue.text) }
        func number(_ value: Any?) -> CatalogValue? { TelemetryDecoder.number(value).map(CatalogValue.decimal) }
        func integer(_ value: Any?) -> CatalogValue? { TelemetryDecoder.integer(value).map(CatalogValue.integer) }
        func boolean(_ value: Any?) -> CatalogValue? { TelemetryDecoder.boolean(value).map(CatalogValue.boolean) }
        for (id, key) in [("001", "model"), ("003", "chip"), ("004", "osVersion"), ("005", "build")] {
            put(id, string(system[key]), source: id == "004" ? "ProcessInfo" : "sysctl", key: key)
        }
        put("006", .boolean(powerSource != nil), source: "IOPowerSources", key: "Type=InternalBattery")
        put("007", .list([.text("IOPowerSources"), .text(registry.isEmpty ? "IORegistry: unavailable" : "IORegistry: read-only")]), source: "PowerTelemetry", key: "providerProbe", provenance: .observed)
        let source = powerSource ?? [:]
        // IOPS capacity values use a common source-specific scale, not mAh.
        let percent = TelemetryDecoder.percentage(current: source["Current Capacity"], maximum: source["Max Capacity"])
        put("011", percent.map(CatalogValue.decimal), source: "IOPowerSources", key: "Current Capacity/Max Capacity")
        let charging = TelemetryDecoder.boolean(source["Is Charging"])
        let state = source["Power Source State"] as? String
        let external: Bool? = state == "AC Power" ? true : state == "Battery Power" ? false : nil
        put("013", charging.map(CatalogValue.boolean), source: "IOPowerSources", key: "Is Charging")
        put("014", boolean(source["Is Charged"]), source: "IOPowerSources", key: "Is Charged")
        put("015", external.map(CatalogValue.boolean), source: "IOPowerSources", key: "Power Source State")
        put("016", string(state), source: "IOPowerSources", key: "Power Source State")
        put("023", string(source["BatteryHealth"]), source: "IOPowerSources", key: "BatteryHealth")
        put("024", string(source["BatteryHealthCondition"]), source: "IOPowerSources", key: "BatteryHealthCondition")
        let batteryData = registry["BatteryData"] as? [String: Any] ?? [:]
        let pack = registry["AppleSmartBatteryPack"] as? [String: Any] ?? [:]
        let packData = pack["BatteryData"] as? [String: Any] ?? pack
        func registryField(_ key: String) -> (Any?, String) {
            if let value = registry[key] { return (value, key) }
            if let value = batteryData[key] { return (value, "BatteryData/\(key)") }
            return (packData[key], "AppleSmartBatteryPack/BatteryData/\(key)")
        }
        let (cycles, cyclePath) = registryField("CycleCount")
        let cycleNumber = TelemetryDecoder.integer(cycles).flatMap { $0 >= 0 ? $0 : nil }
        put("027", cycleNumber.map(CatalogValue.integer), source: "AppleSmartBattery", key: cyclePath)
        let (vendor, vendorPath) = registryField("Manufacturer")
        put("057", string(vendor), source: "AppleSmartBattery", key: vendorPath)
        for (id, key) in [("058", "DeviceName"), ("059", "Serial"), ("062", "Chemistry")] {
            let (value, path) = registryField(key)
            put(id, string(value), source: "AppleSmartBattery", key: path)
        }
        if qualification != .unqualified {
            func capacity(_ keys: [String]) -> (Double?, String) {
                for key in keys {
                    let (raw, path) = registryField(key)
                    if let value = TelemetryDecoder.number(raw), value >= 0, value <= 100000 { return (value, path) }
                }
                return (nil, keys.joined(separator: "/"))
            }
            let (design, designPath) = capacity(["DesignCapacity"])
            let (full, fullPath) = capacity(["AppleRawMaxCapacity", "NominalChargeCapacity", "FullChargeCapacity"])
            let (remaining, remainingPath) = capacity(["AppleRawCurrentCapacity", "RemainingCapacity"])
            put("029", design.map(CatalogValue.decimal), source: "AppleSmartBattery", key: designPath)
            put("030", full.map(CatalogValue.decimal), source: "AppleSmartBattery", key: fullPath)
            put("031", remaining.map(CatalogValue.decimal), source: "AppleSmartBattery", key: remainingPath)
            put("026", TelemetryDecoder.capacityRetention(full: full, design: design).map(CatalogValue.decimal), source: "AppleSmartBattery", key: "capacityRetention/\(fullPath)/\(designPath)", provenance: .estimated,
                reason: "Calculated capacity retention is independent of Apple's system maximum-capacity estimate; ratios above 100% are retained.")
            let rawRatio = remaining.flatMap { remaining in full.flatMap { full in full > 0 ? remaining / full * 100 : nil } }
            put("012", rawRatio.map(CatalogValue.decimal), source: "AppleSmartBattery", key: "raw remaining/full (mAh)", provenance: .estimated)
            let (rawTemperature, temperaturePath) = registryField("Temperature")
            put("039", qualification.temperatureCelsius(rawTemperature).map(CatalogValue.decimal), source: "AppleSmartBattery", key: temperaturePath,
                raw: number(rawTemperature), provenance: .measured,
                reason: "Provider-specific temperature profile; sensor accuracy and sleep/hot-plug behavior still require real-device validation.")
            for (id, keys) in [("060", ["GasGaugeFirmwareVersion", "FirmwareVersion"]), ("061", ["HardwareRevision", "HardwareVersion"])] {
                let selected = keys.map(registryField).first { $0.0 != nil }
                put(id, selected.flatMap { integer($0.0) ?? string($0.0) }, source: "AppleSmartBattery", key: selected?.1 ?? keys[0])
            }
            let lifetime = BatteryDetailDecoder.lifetime(in: registry)
            let life = lifetime.values
            let hours = TelemetryDecoder.number(life["TotalOperatingTime"]).flatMap { $0 >= 0 && $0 < 1000000 ? $0 : nil }
            put("064", hours.map(CatalogValue.decimal), source: "AppleSmartBattery", key: lifetime.path + "/TotalOperatingTime",
                reason: "Reported operating-hours counter; this is not a manufacture timestamp or a precise battery age.")
            let (manufactureRaw, manufacturePath) = registryField("ManufactureDate")
            let manufactureDate = TelemetryDecoder.smartBatteryManufactureDate(manufactureRaw)
            put("063", manufactureDate.map(CatalogValue.date), source: "AppleSmartBattery", key: manufacturePath,
                raw: integer(manufactureRaw), reason: manufactureDate == nil ? "Reported manufacture value is not a validated 16-bit Smart Battery date; opaque larger encodings are not decoded." : nil)
        }
        fields.append(contentsOf: BatteryDetailDecoder.readings(registry: registry, model: system["model"], qualification: qualification, at: now))
        // XNU IOPMPowerSource documents these registry units and signed int amperage.
        let voltage = TelemetryDecoder.number(registry["Voltage"]).flatMap { $0 > 0 && $0 <= 100000 ? $0 / 1000 : nil }
        let current = TelemetryDecoder.currentAmps(registry["Amperage"], encoding: .signedInteger)
        put("035", voltage.map(CatalogValue.decimal), source: "AppleSmartBattery", key: "Voltage", raw: number(registry["Voltage"]), provenance: .measured)
        put("036", current.map(CatalogValue.decimal), source: "AppleSmartBattery", key: "Amperage", raw: integer(registry["Amperage"]), provenance: .measured,
            reason: current == nil ? "Expected a bounded signed integer in mA; unknown unsigned encodings are not guessed." : nil)
        let instant = TelemetryDecoder.currentAmps(registry["InstantAmperage"], encoding: .signedInteger)
        put("037", instant.map(CatalogValue.decimal), source: "AppleSmartBattery", key: "InstantAmperage", raw: integer(registry["InstantAmperage"]), provenance: .measured)
        // The timestamp binds the values to one completed driver poll, not simultaneous physical sensors.
        let batteryPower = sampleAt != nil ? voltage.flatMap { v in current.map { v * $0 } } : nil
        put("038", batteryPower.map(CatalogValue.decimal), source: "AppleSmartBattery", key: "Voltage×Amperage", provenance: .estimated,
            reason: batteryPower == nil ? "A completed driver sample timestamp and both electrical readings are required." : "Approximate V×A from one completed driver polling batch; sensor timing and electrical boundaries can differ.")
        if let current, sampleAt != nil, sourceFreshness != .stale {
            let flow = current > 0.02 ? "intoBattery" : current < -0.02 ? "fromBattery" : "nearZeroMeasuredCurrent"
            put("017", .text(flow), source: "AppleSmartBattery", key: "signed Amperage", provenance: .inferred,
                reason: "Current direction does not establish physical battery isolation or a charge-control effect.")
        }
        if qualification == .appleSilicon, let telemetry = registry["PowerTelemetryData"] as? [String: Any] {
            for (id, key, upper) in [("043", "SystemLoad", 1000000.0), ("054", "SystemPowerIn", 1000000.0), ("055", "SystemVoltageIn", 100000.0), ("056", "SystemCurrentIn", 100000.0)] {
                let value = TelemetryDecoder.number(telemetry[key]).flatMap { $0 >= 0 && $0 <= upper ? $0 / 1000 : nil }
                put(id, value.map(CatalogValue.decimal), source: "AppleSmartBattery", key: "PowerTelemetryData/\(key)", raw: number(telemetry[key]), provenance: id == "043" ? .inferred : .measured,
                    reason: id == "043" ? "System-load channel reported by the battery subsystem; mW scale inferred for the qualified Apple-silicon source. Not CPU power or wall-outlet power; independent sensor time is unknown." : "Provider-reported live-input channel; no independent sensor timestamp is exposed, so freshness is unknown. Adapter rating is never substituted.")
            }
        }
        put("075", sampleAt.map(CatalogValue.date), source: "AppleSmartBattery", key: "UpdateTime", raw: epoch.map(CatalogValue.decimal))
        put("044", string(system["thermal"]), source: "ProcessInfo", key: "thermalState")
        put("045", string(adapter["Name"]), source: "IOPSCopyExternalPowerAdapterDetails", key: "Name")
        put("046", string(adapter["Manufacturer"]), source: "IOPSCopyExternalPowerAdapterDetails", key: "Manufacturer")
        let adapterIdentity = ["AdapterID", "FamilyCode", "AdapterRevision"].reduce(into: [String: CatalogValue]()) { result, key in
            if let v = integer(adapter[key]) { result[key] = v }
        }
        put("047", adapterIdentity.isEmpty ? nil : .object(adapterIdentity), source: "IOPSCopyExternalPowerAdapterDetails", key: "AdapterID/FamilyCode/AdapterRevision")
        put("048", integer(adapter["SerialNumber"]) ?? string(adapter["SerialNumber"]), source: "IOPSCopyExternalPowerAdapterDetails", key: "SerialNumber")
        let watts = TelemetryDecoder.number(adapter["Watts"]).flatMap { $0 >= 0 && $0 <= 1000 ? $0 : nil }
        put("050", watts.map(CatalogValue.decimal), source: "IOPSCopyExternalPowerAdapterDetails", key: "Watts")
        let ceilingCurrent = TelemetryDecoder.number(adapter["Current"]).flatMap { $0 >= 0 && $0 <= 100000 ? $0 / 1000 : nil }
        put("052", ceilingCurrent.map(CatalogValue.decimal), source: "IOPSCopyExternalPowerAdapterDetails", key: "Current")
        let aggregate = TelemetryDecoder.aggregateSeconds(aggregateTimeRemaining)
        put("067", aggregate.map(CatalogValue.decimal), source: "IOPSGetTimeRemainingEstimate", key: "system-wide seconds", provenance: .estimated,
            reason: aggregate == nil ? "System estimate is unknown or unlimited; negative sentinels are not durations." : "Aggregate estimate can include UPS power sources.")
        put("068", TelemetryDecoder.minutesToSeconds(source["Time to Empty"]).map(CatalogValue.decimal), source: "IOPowerSources", key: "Time to Empty (minutes)", provenance: .estimated)
        put("069", TelemetryDecoder.minutesToSeconds(source["Time to Full Charge"]).map(CatalogValue.decimal), source: "IOPowerSources", key: "Time to Full Charge (minutes)", provenance: .estimated)
        put("071", .text(aggregate == nil ? "unavailable" : "systemEstimate; target estimate unavailable"), source: "PowerTelemetry", key: "estimateState", provenance: .inferred)
        put("076", .date(now), source: "ProcessInfo", key: "collection", provenance: .recorded)
        put("095", .object(["monitoring": .text("IOPowerSources + read-only IORegistry"), "control": .text("separately qualified")]), source: "PowerTelemetry", key: "providers", provenance: .observed)
        put("096", .text("Each reading contains independent source, provenance, availability and freshness."), source: "PowerTelemetry", key: "envelopes", provenance: .recorded)
        let token = identityToken(registry: registry)
        put("066", token.map(CatalogValue.text), source: "PowerTelemetry", key: "local salted identity association", provenance: .inferred,
            reason: token == nil ? "Identity requires a reported battery serial and a private local salt; no model-based identity is invented." : nil)
        put("097", .list(fields.filter { $0.value == nil }.prefix(50).map { .text("\($0.id): \($0.reason ?? "unavailable")") }), source: "PowerTelemetry", key: "boundedMissingReasons", provenance: .recorded)
        let catalog = BatteryCatalog.complete(fields, at: now)
        func reading<T: Sendable & Equatable>(_ value: T?, id: String) -> TelemetryReading<T> {
            let field = catalog.first { $0.id == id }!
            return .init(value: value, source: "\(field.source)/\(field.keyPath)", unit: field.unit, collectedAt: now,
                sourceSampleAt: field.sourceSampleAt, monotonicAgeSeconds: field.monotonicAgeSeconds,
                provenance: field.provenance, availability: field.availability, freshness: field.freshness, reason: field.reason)
        }
        return BatterySnapshot(chargePercent: reading(percent.map { Int($0.rounded()) }, id: "011"),
            isCharging: reading(charging, id: "013"), isExternalPower: reading(external, id: "015"),
            cycleCount: reading(cycleNumber.flatMap(Int.init(exactly:)), id: "027"),
            manufacturer: reading(TelemetryDecoder.text(vendor), id: "057"),
            temperatureCelsius: reading(catalog.first { $0.id == "039" }?.value?.doubleValue, id: "039"),
            voltageVolts: reading(voltage, id: "035"), currentAmps: reading(current, id: "036"),
            timeRemainingSeconds: reading(external == false ? aggregate : nil, id: "067"),
            collectedAt: now, catalog: catalog, monotonicTime: uptime, batteryIdentityToken: token)
    }

    /// Explicit advanced inspection, kept out of the normal live read and ordinary exports.
    public func readRawCatalog(includeKnownValues: Bool = false, at date: Date = Date()) -> [CatalogReading] {
        #if os(macOS)
        let inventory = Self.rawInventory(properties: readBatteryRegistry(), includeKnownValues: includeKnownValues)
        let known = inventory.filter { $0.value != nil }.map { item in
            CatalogValue.object(["name": .text(item.name), "type": .text(item.type), "value": item.value!])
        }
        let names = inventory.map { item in
            CatalogValue.object(["name": .text(item.name), "type": .text(item.type), "byteLength": item.byteLength.map { .integer(Int64($0)) } ?? .text("not applicable")])
        }
        return [CatalogReading(definition: BatteryCatalog.definition("098"), value: includeKnownValues ? .list(known) : nil,
            source: "PowerTelemetry", keyPath: "allowlisted raw numeric properties", collectedAt: date, provenance: .raw,
            reason: includeKnownValues ? "Read-only opt-in numeric inventory; no identifying property values included." : "Enable known raw values explicitly to inspect them."),
            CatalogReading(definition: BatteryCatalog.definition("099"), value: .list(names), source: "PowerTelemetry",
                keyPath: "bounded property names/types", collectedAt: date, provenance: .raw,
                reason: "At most 100 names/types. Unknown values remain uninterpreted and cannot drive policy.")]
        #else
        return []
        #endif
    }
    public static func internalBattery(in sources: [[String: Any]]) -> [String: Any]? {
        sources.first { $0["Type"] as? String == "InternalBattery" }
    }
    private func identityToken(registry: [String: Any]) -> String? {
        guard !identitySalt.isEmpty, let serial = TelemetryDecoder.text(registry["Serial"]) else { return nil }
        return SHA256.hash(data: Data((identitySalt + "\u{0}" + serial).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    #if os(macOS)
    private var thermalState: String {
        switch ProcessInfo.processInfo.thermalState { case .nominal: return "nominal"; case .fair: return "fair"; case .serious: return "serious"; case .critical: return "critical"; @unknown default: return "unknown" }
    }
    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size <= 4096 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    private func readBatteryRegistry() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return [:] }
        var result = properties?.takeRetainedValue() as? [String: Any] ?? [:]
        // A bounded child lookup, with no dump of unrelated registry branches.
        var iterator: io_iterator_t = 0
        if IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            for _ in 0..<8 {
                let child = IOIteratorNext(iterator)
                if child == 0 { break }
                defer { IOObjectRelease(child) }
                if IOObjectConformsTo(child, "AppleSmartBatteryPack") != 0 {
                    var childProperties: Unmanaged<CFMutableDictionary>?
                    if IORegistryEntryCreateCFProperties(child, &childProperties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                       let pack = childProperties?.takeRetainedValue() as? [String: Any] {
                        result["AppleSmartBatteryPack"] = pack
                    }
                }
            }
        }
        return result
    }
    #endif
}
