import Foundation
import CoreFoundation
import PowerCore

public struct RawPropertyDescriptor: Codable, Sendable, Equatable {
    public let name: String
    public let type: String
    public let byteLength: Int?
    public let value: CatalogValue?
}

extension MacBatteryProvider {
    /// Values are opt-in and limited to nonidentifying numeric/boolean monitoring
    /// properties. Unknown properties always expose names/types only.
    public static func rawInventory(properties: [String: Any], includeKnownValues: Bool = false) -> [RawPropertyDescriptor] {
        let allowed: Set<String> = ["Voltage", "Amperage", "InstantAmperage", "Temperature", "DesignCapacity", "AppleRawMaxCapacity", "AppleRawCurrentCapacity", "CycleCount", "IsCharging", "FullyCharged", "ExternalConnected", "UpdateTime"]
        return properties.keys.sorted().prefix(100).map { name in
            let raw = properties[name]!
            var type = "unknown", length: Int?, value: CatalogValue?
            if let number = raw as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    type = "boolean"; length = 1
                    if includeKnownValues && allowed.contains(name) { value = .boolean(number.boolValue) }
                } else {
                    let encoding = String(cString: number.objCType)
                    type = "number:\(encoding)"
                    length = ["c":1, "C":1, "s":2, "S":2, "i":4, "I":4, "l":4, "L":4, "q":8, "Q":8, "f":4, "d":8][encoding]
                    if includeKnownValues && allowed.contains(name) {
                        value = TelemetryDecoder.integer(number).map(CatalogValue.integer) ?? TelemetryDecoder.number(number).map(CatalogValue.decimal)
                    }
                }
            } else if let data = raw as? Data { type = "bytes"; length = data.count }
            else if let text = raw as? String { type = "string"; length = text.utf8.count }
            else if let array = raw as? [Any] { type = "array(\(array.count))" }
            else if let dictionary = raw as? [String: Any] { type = "dictionary(\(dictionary.count))" }
            return RawPropertyDescriptor(name: String(name.prefix(128)), type: type, byteLength: length, value: value)
        }
    }
}
