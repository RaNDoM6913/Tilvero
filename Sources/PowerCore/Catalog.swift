import Foundation

/// JSON-safe typed values. Numeric booleans are rejected by provider decoders.
public indirect enum CatalogValue: Codable, Sendable, Equatable {
    case integer(Int64), decimal(Double), boolean(Bool), text(String), date(Date)
    case list([CatalogValue]), object([String: CatalogValue])

    public var doubleValue: Double? {
        switch self { case .integer(let v): return Double(v); case .decimal(let v): return v; default: return nil }
    }
    public var stringValue: String? { if case .text(let v) = self { return v }; return nil }
    public var displayText: String {
        switch self {
        case .integer(let v): return String(v)
        case .decimal(let v): return v.formatted(.number.precision(.fractionLength(0...2)))
        case .boolean(let v): return v ? "true" : "false"
        case .text(let v): return v
        case .date(let v): return v.formatted(date: .abbreviated, time: .standard)
        case .list(let v): return v.map(\.displayText).joined(separator: ", ")
        case .object(let v): return v.keys.sorted().map { "\($0): \(v[$0]!.displayText)" }.joined(separator: "; ")
        }
    }
    public var isFinite: Bool {
        switch self { case .decimal(let v): return v.isFinite; case .list(let v): return v.allSatisfy(\.isFinite); case .object(let v): return v.values.allSatisfy(\.isFinite); default: return true }
    }
}

public enum CatalogPrivacy: String, Codable, Sendable { case operational, sensitive }

public struct CatalogDefinition: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let titleEnglish: String
    public let titleRussian: String
    public let category: String
    public let unit: String?
    public let privacy: CatalogPrivacy
}

public struct CatalogReading: Identifiable, Codable, Sendable, Equatable {
    public let definition: CatalogDefinition
    public var id: String { definition.id }
    public var titleEnglish: String { definition.titleEnglish }
    public var titleRussian: String { definition.titleRussian }
    public var category: String { definition.category }
    public var privacy: CatalogPrivacy { definition.privacy }
    public let value: CatalogValue?
    public let rawValue: CatalogValue?
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

    public init(definition: CatalogDefinition, value: CatalogValue? = nil, rawValue: CatalogValue? = nil,
                unit: String? = nil, source: String, keyPath: String = "", collectedAt: Date = Date(),
                sourceSampleAt: Date? = nil, monotonicAgeSeconds: TimeInterval? = nil,
                provenance: TelemetryProvenance = .reported,
                availability: TelemetryAvailability? = nil, freshness: TelemetryFreshness = .unknown,
                reason: String? = nil) {
        self.definition = definition
        let valid = value?.isFinite != false
        self.value = valid ? value : nil
        self.rawValue = rawValue?.isFinite == true ? rawValue : nil
        self.unit = unit ?? definition.unit
        self.source = source
        self.keyPath = keyPath
        self.collectedAt = collectedAt
        self.sourceSampleAt = sourceSampleAt
        self.monotonicAgeSeconds = monotonicAgeSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.provenance = provenance
        self.availability = !valid ? .invalid : value == nil ? (availability == .available ? .invalid : availability ?? .unavailable) : availability ?? .available
        self.freshness = value == nil || !valid ? .unknown : freshness
        self.reason = !valid ? "The source returned a nonfinite number." : value == nil ? (reason ?? "No qualified value is available from the selected provider.") : reason
    }

    public func retainingPrevious(_ previous: CatalogReading, age: TimeInterval) -> CatalogReading {
        guard value == nil, previous.value != nil, previous.id == id else { return self }
        return CatalogReading(definition: definition, value: previous.value, rawValue: previous.rawValue,
            source: previous.source, keyPath: previous.keyPath, collectedAt: previous.collectedAt,
            sourceSampleAt: previous.sourceSampleAt, monotonicAgeSeconds: age,
            provenance: previous.provenance, availability: .temporarilyUnavailable, freshness: .stale,
            reason: "The latest collection failed; this is the last valid observation. " + (reason ?? "Source sample time may be unknown."))
    }
}

public enum BatteryCatalog {
    public static func definition(_ id: String) -> CatalogDefinition { definitions.first { $0.id == id }! }
    public static func unavailable(at: Date = Date(), reason: String = "This field has no qualified provider on this device.") -> [CatalogReading] {
        definitions.map { CatalogReading(definition: $0, source: "PowerTelemetry", collectedAt: at, reason: reason) }
    }
    public static func complete(_ readings: [CatalogReading], at: Date) -> [CatalogReading] {
        let supplied = Dictionary(readings.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return definitions.map { supplied[$0.id] ?? CatalogReading(definition: $0, source: "PowerTelemetry", collectedAt: at, reason: missingReason(for: $0.id)) }
    }
    private static func missingReason(for id: String) -> String {
        switch id {
        case "002", "028", "032", "033": return "A verified model reference or nominal-voltage mapping is not available."
        case "008", "009", "018"..."022", "100": return "Requires the independent policy/control provider and verified readback."
        case "039"..."042", "051", "054"..."056", "060"..."065": return "The property encoding, units or sensor identity have not been qualified on this device."
        case "070": return "A stable charging sample window and an observed effective target are required."
        case "072"..."074", "077"..."086": return "Requires locally recorded observations; history before monitoring is unavailable."
        case "087"..."094", "010": return "Fan/sensor inventory is unverified; probe absence must not be interpreted as a fanless device."
        case "098", "099": return "Raw inspection is opt-in and redacted; unknown keys cannot drive policy."
        default: return "The provider did not report a qualified value."
        }
    }
    public static let definitions: [CatalogDefinition] = {
        let rows: [(String, String, String?, String)] = [
            ("Model identifier", "Идентификатор модели", nil, "001"),
            ("Marketing model name", "Название модели", nil, "002"),
            ("Chip description", "Чип", nil, "003"),
            ("macOS version", "Версия macOS", nil, "004"),
            ("macOS build", "Сборка macOS", nil, "005"),
            ("Internal battery present", "Встроенная батарея", nil, "006"),
            ("Telemetry capabilities", "Возможности мониторинга", nil, "007"),
            ("Charge-control capability", "Управление зарядкой", nil, "008"),
            ("Supported energy modes", "Режимы энергопотребления", nil, "009"),
            ("Fan inventory capability", "Возможности вентиляторов", nil, "010"),
            ("macOS charge level", "Заряд по данным macOS", "%", "011"),
            ("Raw charge ratio", "Исходное отношение заряда", "%", "012"),
            ("Charging flag", "Батарея заряжается", nil, "013"),
            ("Fully charged flag", "Полностью заряжена", nil, "014"),
            ("External power connected", "Внешнее питание подключено", nil, "015"),
            ("Active power source", "Активный источник питания", nil, "016"),
            ("Observed power-flow state", "Наблюдаемый поток энергии", nil, "017"),
            ("Requested upper charge target", "Запрошенный предел заряда", "%", "018"),
            ("Requested resume threshold", "Порог возобновления", "%", "019"),
            ("Observed effective limit", "Подтверждённый предел", "%", "020"),
            ("One-time full-charge intent", "Разовая полная зарядка", nil, "021"),
            ("System charging override/reason", "Причина системного ограничения", nil, "022"),
            ("macOS health category", "Состояние батареи macOS", nil, "023"),
            ("macOS health condition", "Условие состояния macOS", nil, "024"),
            ("System maximum-capacity percentage", "Максимальная ёмкость macOS", "%", "025"),
            ("Estimated capacity retention", "Расчётное сохранение ёмкости", "%", "026"),
            ("Cycle count", "Число циклов", "cycles", "027"),
            ("Model cycle reference", "Справочный ресурс циклов", "cycles", "028"),
            ("Design charge capacity", "Проектная ёмкость", "mAh", "029"),
            ("Full-charge capacity", "Ёмкость полного заряда", "mAh", "030"),
            ("Remaining charge capacity", "Оставшаяся ёмкость", "mAh", "031"),
            ("Nominal/design battery voltage", "Номинальное напряжение", "V", "032"),
            ("Design energy", "Проектная энергия", "Wh", "033"),
            ("Estimated full-charge energy", "Расчётная энергия полного заряда", "Wh", "034"),
            ("Battery voltage", "Напряжение батареи", "V", "035"),
            ("Battery current", "Ток батареи", "A", "036"),
            ("Instantaneous battery current", "Мгновенный ток батареи", "A", "037"),
            ("Battery power", "Мощность батареи", "W", "038"),
            ("Battery temperature", "Температура батареи", "°C", "039"),
            ("Individual battery temperatures", "Температуры батарей", "°C", "040"),
            ("Individual cell voltages", "Напряжения ячеек", "V", "041"),
            ("Cell voltage spread", "Разброс напряжений", "mV", "042"),
            ("Estimated system consumption", "Расчётное потребление системы", "W", "043"),
            ("System thermal state", "Тепловое состояние системы", nil, "044"),
            ("Reported adapter name", "Название адаптера", nil, "045"),
            ("Reported adapter manufacturer", "Производитель адаптера", nil, "046"),
            ("Adapter ID/family/revision", "Идентификатор и версия адаптера", nil, "047"),
            ("Adapter serial", "Серийный номер адаптера", nil, "048"),
            ("Connection transport", "Тип подключения", nil, "049"),
            ("Reported adapter power capability", "Заявленная мощность адаптера", "W", "050"),
            ("Negotiated connection voltage", "Согласованное напряжение", "V", "051"),
            ("Negotiated current ceiling", "Предельный ток подключения", "A", "052"),
            ("Negotiated power ceiling", "Предельная мощность подключения", "W", "053"),
            ("Live input power", "Входная мощность", "W", "054"),
            ("Live input voltage", "Входное напряжение", "V", "055"),
            ("Live input current", "Входной ток", "A", "056"),
            ("Reported battery manufacturer", "Производитель батареи", nil, "057"),
            ("Battery device/model description", "Модель батареи", nil, "058"),
            ("Battery serial", "Серийный номер батареи", nil, "059"),
            ("Battery firmware revision", "Версия прошивки батареи", nil, "060"),
            ("Battery hardware revision", "Аппаратная версия батареи", nil, "061"),
            ("Reported chemistry", "Химический состав", nil, "062"),
            ("Reported manufacture date", "Дата производства батареи", nil, "063"),
            ("Reported lifetime operating time", "Время работы батареи", "h", "064"),
            ("Estimated battery age", "Расчётный возраст батареи", "s", "065"),
            ("Local battery identity token", "Локальный идентификатор батареи", nil, "066"),
            ("System aggregate remaining time", "Системный прогноз времени", "s", "067"),
            ("Battery time to empty", "Время до разряда", "s", "068"),
            ("Battery time to full", "Время до полного заряда", "s", "069"),
            ("Estimated time to active target", "Время до целевого заряда", "s", "070"),
            ("Estimate confidence/state", "Состояние прогноза", nil, "071"),
            ("Current external-power session start", "Начало внешнего питания", nil, "072"),
            ("Current on-battery session start", "Начало работы от батареи", nil, "073"),
            ("Current charging session duration", "Длительность зарядки", "s", "074"),
            ("Latest source measurement time", "Время измерения источника", nil, "075"),
            ("Latest collection time", "Время последнего сбора", nil, "076"),
            ("Monitoring start", "Начало мониторинга", nil, "077"),
            ("Recorded charge series", "История заряда", nil, "078"),
            ("Recorded temperature series", "История температуры", nil, "079"),
            ("Recorded power series", "История мощности", nil, "080"),
            ("Capacity-retention trend", "Тенденция сохранения ёмкости", nil, "081"),
            ("Observed cycle delta", "Изменение числа циклов", "cycles", "082"),
            ("Recorded charging-session count", "Число сеансов зарядки", nil, "083"),
            ("Observed external-power duration", "Время внешнего питания", "s", "084"),
            ("Estimated energy charged/discharged", "Оценка переданной энергии", "Wh", "085"),
            ("History coverage/gaps", "Покрытие истории и пропуски", nil, "086"),
            ("Fan count", "Количество вентиляторов", nil, "087"),
            ("Per-fan identifier/location", "Расположение вентиляторов", nil, "088"),
            ("Per-fan actual speed", "Скорость вентиляторов", "RPM", "089"),
            ("Per-fan reported minimum", "Минимальная скорость", "RPM", "090"),
            ("Per-fan reported maximum", "Максимальная скорость", "RPM", "091"),
            ("Per-fan observed control mode", "Наблюдаемый режим вентиляторов", nil, "092"),
            ("Per-fan requested/observed target", "Целевая скорость вентиляторов", "RPM", "093"),
            ("Named component temperatures", "Температуры компонентов", "°C", "094"),
            ("Active telemetry/control providers", "Активные провайдеры", nil, "095"),
            ("Field provenance and freshness", "Происхождение и свежесть", nil, "096"),
            ("Provider errors and missing reasons", "Ошибки и причины отсутствия", nil, "097"),
            ("Known raw properties", "Известные исходные свойства", nil, "098"),
            ("Unknown raw property inventory", "Неизвестные свойства", nil, "099"),
            ("Control request/readback journal", "Журнал управления", nil, "100"),
        ]
        return rows.map { en, ru, unit, id in
            let n = Int(id)!
            let category = n <= 10 ? "device" : n <= 22 ? "charge" : n <= 34 ? "condition" : n <= 44 ? "electrical" : n <= 56 ? "adapter" : n <= 66 ? "identity" : n <= 76 ? "timing" : n <= 86 ? "history" : n <= 94 ? "cooling" : "diagnostics"
            return CatalogDefinition(id: id, titleEnglish: en, titleRussian: ru, category: category, unit: unit,
                privacy: ["048", "059", "063", "066", "098", "099"].contains(id) ? .sensitive : .operational)
        }
    }()
}
