import Foundation
import PowerCore

enum ReadingPresentation {
    static func isCurrentlyCharging(_ snapshot: BatterySnapshot) -> Bool {
        let source = snapshot.isExternalPower
        if source.availability == .available, source.freshness != .stale, source.value == false { return false }
        return snapshot.isCharging.availability == .available && snapshot.isCharging.freshness != .stale && snapshot.isCharging.value == true
    }
    static func chargingStateKey(_ snapshot: BatterySnapshot) -> String {
        let source = snapshot.isExternalPower
        let usableSource = source.availability == .available && source.freshness != .stale
        if usableSource && source.value == false { return "On battery" }
        if isCurrentlyCharging(snapshot) { return "Charging" }
        if usableSource && source.value == true {
            let charge = snapshot.isCharging
            return charge.availability == .available && charge.freshness != .stale && charge.value == false ? "Connected, not charging" : "Connected, charging state unavailable"
        }
        return "Power source unavailable"
    }
    static func validLevel(_ level: Int?) -> Int? { level.flatMap { (0...100).contains($0) ? $0 : nil } }
    static func number(_ reading: TelemetryReading<Double>) -> String? {
        guard reading.availability == .available, let value = reading.value, value.isFinite else { return nil }
        return value.formatted(.number.locale(L10n.locale).precision(.fractionLength(0...1)))
    }
    static func percentInput(_ text: String, acceptedTargets: [Int]) -> Int? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 3 else { return nil }
        var value = 0
        for character in clean {
            guard let digit = character.wholeNumberValue, (0...9).contains(digit) else { return nil }
            value = value * 10 + digit
        }
        return acceptedTargets.contains(value) ? value : nil
    }
    static func ageLabel(collectedAt: Date, now: Date = Date(), language: String = L10n.language) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(collectedAt)))
        return language == "ru" ? "\(seconds) секунд назад" : "\(seconds) seconds ago"
    }
    static func display(_ reading: CatalogReading, reveal: Bool, fahrenheit: Bool) -> String {
        if reading.privacy == .sensitive && !reveal { return reading.value == nil ? "—" : "••••••" }
        guard reading.availability == .available || reading.freshness == .stale,
              let value = reading.value else { return "—" }
        if reading.unit == "°C", fahrenheit, let number = value.doubleValue {
            return "\((number * 9 / 5 + 32).formatted(.number.locale(L10n.locale).precision(.fractionLength(1)))) °F"
        }
        if case .boolean(let flag) = value { return L10n.language == "ru" ? (flag ? "Да" : "Нет") : (flag ? "Yes" : "No") }
        if case .date(let date) = value { return date.formatted(.dateTime.locale(L10n.locale)) }
        if let number = value.doubleValue {
            let formatted = number.formatted(.number.locale(L10n.locale).precision(.fractionLength(0...2)))
            if reading.unit == "cycles" {
                let n = Int(number), tail = n % 100
                let key = L10n.language == "ru" ? ((11...14).contains(tail) ? "cycles.many" : n % 10 == 1 ? "cycles.one" : (2...4).contains(n % 10) ? "cycles.few" : "cycles.many") : n == 1 ? "cycles.one" : "cycles.many"
                return formatted + " " + L10n.text(key)
            }
            return formatted + (reading.unit.map { " " + ($0 == "s" && L10n.language == "ru" ? "с" : $0) } ?? "")
        }
        let known = ["Good": "Good", "nominal": "Nominal", "fair": "Fair", "serious": "Serious", "critical": "Critical", "AC Power": "Power adapter", "Battery Power": "On battery", "intoBattery": "Power entering the battery", "fromBattery": "Power leaving the battery", "nearZeroMeasuredCurrent": "Battery current near zero"]
        let stateFields = ["016", "017", "023", "024", "044"]
        let text: String
        if reading.id == "021", value.displayText == "none" { text = L10n.text("No one-time charge") }
        else if reading.id == "021", value.displayText == "requested" { text = L10n.text("Requested") }
        else { text = stateFields.contains(reading.id) ? (known[value.displayText].map(L10n.text) ?? value.displayText) : value.displayText }
        return text + (reading.unit.map { " \($0)" } ?? "")
    }
}
