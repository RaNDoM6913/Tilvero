import Foundation
import Combine
import IOKit.pwr_mgt

struct KeepAwakeDuration: RawRepresentable, CaseIterable, Identifiable, Hashable {
    let rawValue: Int
    init?(rawValue: Int) {
        guard (1...1440).contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }
    static func load(_ value: Any?) -> Self {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return .halfHour }
        let minutes = number.doubleValue
        guard minutes.isFinite, (1...1440).contains(minutes), minutes.rounded(.towardZero) == minutes else { return .halfHour }
        return Self(rawValue: Int(minutes)) ?? .halfHour
    }
    static let quarterHour = Self(rawValue: 15)!
    static let halfHour = Self(rawValue: 30)!
    static let hour = Self(rawValue: 60)!
    static let twoHours = Self(rawValue: 120)!
    static let fourHours = Self(rawValue: 240)!
    static let eightHours = Self(rawValue: 480)!
    static let allCases = [quarterHour, halfHour, hour, twoHours, fourHours, eightHours]
    var id: Int { rawValue }
    var seconds: Int { rawValue * 60 }
}
enum KeepAwakeDraft: Equatable {
    case duration(KeepAwakeDuration), until(Date), untilStopped
}
enum KeepAwakeExpiry: Equatable {
    case duration, until(Date), untilStopped
}
enum KeepAwakeError: Error, LocalizedError {
    case invalidDuration, alreadyRunning, unavailable, creationFailed, unconfirmed, releaseFailed, foreignAssertion
    case updateFailed, noFiniteSession, clockChangeExceededLimit
    var errorDescription: String? {
        switch self {
        case .invalidDuration: "Choose a supported Keep Awake duration."
        case .alreadyRunning: "A Keep Awake session is already running."
        case .unavailable: "Keep Awake is unavailable in this build or simulation."
        case .creationFailed: "macOS could not start Keep Awake."
        case .unconfirmed: "macOS has not confirmed the Keep Awake state."
        case .releaseFailed: "Keep Awake could not be stopped. Try Stop again."
        case .foreignAssertion: "The assertion no longer matches this Tilvero session. Nothing else was released."
        case .updateFailed: "macOS could not update Keep Awake. Try again."
        case .noFiniteSession: "Start a confirmed timed Keep Awake session before extending it."
        case .clockChangeExceededLimit: "The system clock moved the end time beyond 24 hours. The Keep Awake session was stopped."
        }
    }
}
struct KeepAwakeAssertion: Sendable, Equatable {
    let name: String
    let kind: String
    let active: Bool
    /// nil is a verified absent/zero timeout, never a parsing failure.
    let seconds: Int?
    let releasesOnTimeout: Bool
}
@MainActor protocol KeepAwakeTransport: AnyObject {
    func create(seconds: Int, name: String) throws -> UInt32
    func createUntilStopped(name: String) throws -> UInt32
    func setTimeout(_ id: UInt32, seconds: Int, name: String) throws
    func read(_ id: UInt32) throws -> KeepAwakeAssertion?
    func release(_ id: UInt32, name: String) throws
}

/// A process-owned public assertion. No global power preference or helper is used.
@MainActor final class NativeKeepAwakeTransport: KeepAwakeTransport {
    private var owned: [UInt32: String] = [:]
    func create(seconds: Int, name: String) throws -> UInt32 {
        guard (1...86_400).contains(seconds) else { throw KeepAwakeError.invalidDuration }
        return try create(timeout: seconds, name: name)
    }
    func createUntilStopped(name: String) throws -> UInt32 { try create(timeout: nil, name: name) }
    private func create(timeout: Int?, name: String) throws -> UInt32 {
        guard name.hasPrefix("Tilvero Keep Awake ") else { throw KeepAwakeError.foreignAssertion }
        var properties: [String: Any] = [
            kIOPMAssertionTypeKey as String: kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionNameKey as String: name,
            kIOPMAssertionLevelKey as String: kIOPMAssertionLevelOn,
            kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionRelease
        ]
        if let timeout { properties[kIOPMAssertionTimeoutKey as String] = NSNumber(value: timeout) }
        var id: IOPMAssertionID = 0
        guard IOPMAssertionCreateWithProperties(properties as CFDictionary, &id) == kIOReturnSuccess else { throw KeepAwakeError.creationFailed }
        owned[id] = name
        return id
    }
    func read(_ id: UInt32) throws -> KeepAwakeAssertion? {
        guard let raw = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any] else { return nil }
        return try Self.decode(raw)
    }
    static func decode(_ raw: [String: Any]) throws -> KeepAwakeAssertion {
        guard let name = raw[kIOPMAssertionNameKey as String] as? String,
              let kind = raw[kIOPMAssertionTypeKey as String] as? String,
              let level = raw[kIOPMAssertionLevelKey as String] as? NSNumber,
              CFGetTypeID(level) != CFBooleanGetTypeID(),
              [0.0, 1.0, Double(kIOPMAssertionLevelOn)].contains(level.doubleValue) else { throw KeepAwakeError.unconfirmed }
        var timeout: Int?
        if let value = raw[kIOPMAssertionTimeoutKey as String] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw KeepAwakeError.unconfirmed }
            let seconds = number.doubleValue
            guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max), seconds.rounded(.towardZero) == seconds else { throw KeepAwakeError.unconfirmed }
            if seconds > 0 { timeout = Int(seconds) }
        }
        let action = raw[kIOPMAssertionTimeoutActionKey as String] as? String
        return .init(name: name, kind: kind, active: level.doubleValue != 0, seconds: timeout,
                     releasesOnTimeout: action == (kIOPMAssertionTimeoutActionRelease as String))
    }
    func setTimeout(_ id: UInt32, seconds: Int, name: String) throws {
        guard (1...86_400).contains(seconds) else { throw KeepAwakeError.invalidDuration }
        guard owned[id] == name else { throw KeepAwakeError.foreignAssertion }
        guard let actual = try read(id) else { owned.removeValue(forKey: id); throw KeepAwakeError.noFiniteSession }
        guard actual.name == name, actual.kind == "PreventUserIdleSystemSleep" else { throw KeepAwakeError.foreignAssertion }
        guard actual.active, let timeout = actual.seconds, timeout > 0, actual.releasesOnTimeout else { throw KeepAwakeError.unconfirmed }
        guard IOPMAssertionSetProperty(id, kIOPMAssertionTimeoutKey as CFString, NSNumber(value: seconds)) == kIOReturnSuccess else { throw KeepAwakeError.updateFailed }
    }
    func release(_ id: UInt32, name: String) throws {
        guard owned[id] == name else { throw KeepAwakeError.foreignAssertion }
        guard let raw = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any] else { owned.removeValue(forKey: id); return }
        guard raw[kIOPMAssertionNameKey as String] as? String == name,
              raw[kIOPMAssertionTypeKey as String] as? String == "PreventUserIdleSystemSleep" else { throw KeepAwakeError.foreignAssertion }
        guard let level = raw[kIOPMAssertionLevelKey as String] as? NSNumber, level.doubleValue != 0 else { throw KeepAwakeError.unconfirmed }
        guard IOPMAssertionRelease(id) == kIOReturnSuccess else { throw KeepAwakeError.releaseFailed }
        owned.removeValue(forKey: id)
    }
}

@MainActor final class KeepAwakeService: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var message: String?
    @Published private(set) var ownedAssertionID: UInt32?
    @Published private(set) var expiry: KeepAwakeExpiry?
    private var name: String?
    private var timer: Task<Void, Never>?
    private var deadline: ContinuousClock.Instant?
    private var expectedTimeoutSeconds: Int?
    private var scheduleGeneration: UInt64 = 0
    private let driver: any KeepAwakeTransport
    private let allowed: Bool
    private let sleeper: @Sendable (Duration) async throws -> Void
    private let wallNow: () -> Date
    private let continuousNow: () -> ContinuousClock.Instant
    var isAvailable: Bool { allowed }
    var hasOwnedAssertion: Bool { ownedAssertionID != nil }
    var remainingSeconds: Int {
        guard hasOwnedAssertion else { return 0 }
        switch expiry {
        case .duration: return Self.ceiling(remainingMonotonic)
        case .until(let target): return Self.ceiling(target.timeIntervalSince(wallNow()))
        default: return 0
        }
    }
    var endDate: Date? {
        switch expiry {
        case .duration: wallNow().addingTimeInterval(max(0, remainingMonotonic))
        case .until(let target): target
        default: nil
        }
    }
    private var remainingMonotonic: Double {
        guard let deadline else { return 0 }
        let value = continuousNow().duration(to: deadline).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
    private static func ceiling(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return seconds >= Double(Int.max) ? Int.max : Int(seconds.rounded(.up))
    }
    init(driver: any KeepAwakeTransport = NativeKeepAwakeTransport(), allowed: Bool = true,
         sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         wallNow: @escaping () -> Date = { Date() },
         continuousNow: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.driver = driver; self.allowed = allowed; self.sleeper = sleeper
        self.wallNow = wallNow; self.continuousNow = continuousNow
    }
    func start(seconds: Int) throws {
        try validateStart()
        guard (1...86_400).contains(seconds) else { throw KeepAwakeError.invalidDuration }
        try begin(seconds: seconds, expiry: .duration)
    }
    func startUntilStopped() throws {
        try validateStart()
        try begin(seconds: nil, expiry: .untilStopped)
    }
    func start(until target: Date) throws {
        try validateStart()
        let interval = target.timeIntervalSince(wallNow())
        guard interval.isFinite, interval > 0, interval <= 86_400 else { throw KeepAwakeError.invalidDuration }
        try begin(seconds: Self.ceiling(interval), expiry: .until(target))
    }
    private func validateStart() throws {
        guard allowed else { throw KeepAwakeError.unavailable }
        guard !hasOwnedAssertion else { throw KeepAwakeError.alreadyRunning }
    }
    private func begin(seconds: Int?, expiry requested: KeepAwakeExpiry) throws {
        message = nil
        let token = "Tilvero Keep Awake \(UUID().uuidString)"
        let beforeCreate = continuousNow()
        do {
            let id: UInt32
            if let seconds { id = try driver.create(seconds: seconds, name: token) }
            else { id = try driver.createUntilStopped(name: token) }
            ownedAssertionID = id; name = token
            guard let actual = try driver.read(id), matches(actual, name: token, seconds: seconds) else { throw KeepAwakeError.unconfirmed }
            expectedTimeoutSeconds = seconds; expiry = requested
            deadline = seconds.map { beforeCreate.advanced(by: .seconds($0)) }
            isActive = true
            schedule()
        } catch {
            let original = error
            if hasOwnedAssertion {
                do { try stop(); message = original.localizedDescription }
                catch { isActive = false; message = error.localizedDescription }
            } else { message = original.localizedDescription }
            throw original
        }
    }
    func extend(by seconds: Int) throws {
        guard allowed else { throw KeepAwakeError.unavailable }
        guard [900, 1800, 3600].contains(seconds) else { throw KeepAwakeError.invalidDuration }
        guard isActive, let expiry, expiry != .untilStopped, let id = ownedAssertionID, let name else { throw KeepAwakeError.noFiniteSession }
        try preflight(id, name: name)
        let remaining = remainingSeconds
        guard remaining > 0 else { try stop(); throw KeepAwakeError.noFiniteSession }
        guard remaining <= 86_400 - seconds else { throw KeepAwakeError.invalidDuration }
        let requested: KeepAwakeExpiry
        if case .until(let target) = expiry { requested = .until(target.addingTimeInterval(Double(seconds))) }
        else { requested = .duration }
        try update(id, name: name, seconds: remaining + seconds, expiry: requested)
    }
    private func matches(_ actual: KeepAwakeAssertion, name: String, seconds: Int?) -> Bool {
        actual.name == name && actual.kind == "PreventUserIdleSystemSleep" && actual.active &&
        actual.seconds == seconds && (seconds == nil || actual.releasesOnTimeout)
    }
    private func preflight(_ id: UInt32, name: String) throws {
        do {
            guard let actual = try driver.read(id) else { clear(); throw KeepAwakeError.noFiniteSession }
            guard actual.name == name, actual.kind == "PreventUserIdleSystemSleep" else { throw KeepAwakeError.foreignAssertion }
            guard actual.active else { clear(); throw KeepAwakeError.noFiniteSession }
            guard matches(actual, name: name, seconds: expectedTimeoutSeconds) else { throw KeepAwakeError.unconfirmed }
        } catch {
            failUnconfirmed(error)
            throw error
        }
    }
    /// Stop uses the transport's independent ownership/type guard if readback is malformed.
    /// A failed release retains the ID and visible Stop retry; no second session can start.
    private func failUnconfirmed(_ error: Error) {
        isActive = false
        invalidateSchedule()
        if hasOwnedAssertion {
            do { try stop() }
            catch { message = error.localizedDescription; return }
        }
        message = error.localizedDescription
    }
    private func update(_ id: UInt32, name: String, seconds: Int, expiry requested: KeepAwakeExpiry,
                        releaseOnFailure: Bool = false) throws {
        let beforeUpdate = continuousNow()
        do {
            try driver.setTimeout(id, seconds: seconds, name: name)
            guard let actual = try driver.read(id), matches(actual, name: name, seconds: seconds) else { throw KeepAwakeError.unconfirmed }
            expectedTimeoutSeconds = seconds; expiry = requested
            deadline = beforeUpdate.advanced(by: .seconds(seconds))
            isActive = true; message = nil
            schedule()
        } catch {
            let original = error
            let actual: KeepAwakeAssertion?
            do { actual = try driver.read(id) }
            catch { failUnconfirmed(original); throw original }
            guard let actual else { clear(); message = original.localizedDescription; throw original }
            guard actual.name == name, actual.kind == "PreventUserIdleSystemSleep" else {
                isActive = false; invalidateSchedule()
                message = KeepAwakeError.foreignAssertion.localizedDescription
                throw KeepAwakeError.foreignAssertion
            }
            guard actual.active else { clear(); message = original.localizedDescription; throw original }
            if !releaseOnFailure, matches(actual, name: name, seconds: expectedTimeoutSeconds) {
                // A conclusive unchanged readback permits an explicit retry, never a replay.
                message = original.localizedDescription
                throw original
            }
            failUnconfirmed(original)
            throw original
        }
    }

    func stop() throws {
        guard let id = ownedAssertionID, let name else { return }
        invalidateSchedule()
        do {
            // Never release a reused foreign ID or an already inactive assertion.
            do {
                guard let actual = try driver.read(id) else { clear(); return }
                guard actual.name == name, actual.kind == "PreventUserIdleSystemSleep" else { throw KeepAwakeError.foreignAssertion }
                if !actual.active { clear(); return }
            } catch {
                if case KeepAwakeError.foreignAssertion = error { throw error }
                // Malformed readback is not proof of absence. The transport still checks
                // its ownership map plus raw name/type before it can release anything.
            }
            try driver.release(id, name: name)
            guard try driver.read(id) == nil else { throw KeepAwakeError.releaseFailed }
            clear()
        } catch {
            if case KeepAwakeError.foreignAssertion = error { isActive = false }
            message = error.localizedDescription
            throw error
        }
    }
    func reconcile() throws {
        guard let id = ownedAssertionID, let name else { return }
        do {
            try preflight(id, name: name)
            switch expiry {
            case .untilStopped: isActive = true
            case .duration:
                if remainingSeconds == 0 { try stop() } else { isActive = true }
            case .until(let target):
                let remaining = target.timeIntervalSince(wallNow())
                if remaining <= 0 { try stop() }
                else if !remaining.isFinite || remaining > 86_400 {
                    try stop()
                    throw KeepAwakeError.clockChangeExceededLimit
                } else if remainingMonotonic <= 0 || abs(remaining - remainingMonotonic) > 1 {
                    try update(id, name: name, seconds: Self.ceiling(remaining), expiry: .until(target), releaseOnFailure: true)
                } else { isActive = true }
            case nil: throw KeepAwakeError.unconfirmed
            }
        } catch {
            if case KeepAwakeError.noFiniteSession = error, !hasOwnedAssertion { message = nil; return }
            isActive = false
            if message == nil { message = error.localizedDescription }
            throw error
        }
    }
    private func invalidateSchedule() {
        scheduleGeneration &+= 1
        timer?.cancel(); timer = nil
    }
    private func schedule() {
        invalidateSchedule()
        guard expiry != .untilStopped, let token = name, let deadline else { return }
        let generation = scheduleGeneration, wait = sleeper
        let delay = continuousNow().duration(to: deadline)
        timer = Task { [weak self] in
            do { try await wait(delay) } catch { return }
            guard !Task.isCancelled, let self, self.name == token, self.scheduleGeneration == generation else { return }
            if case .until = self.expiry {
                try? self.reconcile()
                if self.isActive, self.scheduleGeneration == generation { self.schedule() }
            } else { try? self.stop() }
        }
    }
    private func clear() {
        invalidateSchedule()
        ownedAssertionID = nil; name = nil; deadline = nil
        expectedTimeoutSeconds = nil; expiry = nil; isActive = false; message = nil
    }
}
