import Foundation
import Combine
import IOKit.pwr_mgt

enum KeepAwakeDuration: Int, CaseIterable, Identifiable {
    case quarterHour = 15, halfHour = 30, hour = 60, twoHours = 120
    var id: Int { rawValue }
    var seconds: Int { rawValue * 60 }
}

enum KeepAwakeError: Error, LocalizedError {
    case invalidDuration, alreadyRunning, unavailable, creationFailed, unconfirmed, releaseFailed, foreignAssertion
    var errorDescription: String? {
        switch self {
        case .invalidDuration: "Choose a supported Keep Awake duration."
        case .alreadyRunning: "A Keep Awake session is already running."
        case .unavailable: "Keep Awake is unavailable in this build or simulation."
        case .creationFailed: "macOS could not start Keep Awake."
        case .unconfirmed: "macOS has not confirmed the Keep Awake state."
        case .releaseFailed: "Keep Awake could not be stopped. Try Stop again."
        case .foreignAssertion: "The assertion no longer matches this Tilvero session. Nothing else was released."
        }
    }
}
struct KeepAwakeAssertion: Sendable, Equatable {
    let name: String
    let kind: String
    let active: Bool
    let seconds: Int
    let releasesOnTimeout: Bool
}
@MainActor protocol KeepAwakeTransport: AnyObject {
    func create(seconds: Int, name: String) throws -> UInt32
    func read(_ id: UInt32) throws -> KeepAwakeAssertion?
    func release(_ id: UInt32, name: String) throws
}

/// A process-owned public assertion. No global power preference or helper is used.
@MainActor final class NativeKeepAwakeTransport: KeepAwakeTransport {
    private var owned: [UInt32: String] = [:]
    func create(seconds: Int, name: String) throws -> UInt32 {
        guard (1...7200).contains(seconds), name.hasPrefix("Tilvero Keep Awake ") else { throw KeepAwakeError.invalidDuration }
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey as String: kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionNameKey as String: name,
            kIOPMAssertionLevelKey as String: kIOPMAssertionLevelOn,
            kIOPMAssertionTimeoutKey as String: Double(seconds),
            kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionRelease
        ]
        var id: IOPMAssertionID = 0
        guard IOPMAssertionCreateWithProperties(properties as CFDictionary, &id) == kIOReturnSuccess else { throw KeepAwakeError.creationFailed }
        owned[id] = name
        return id
    }
    func read(_ id: UInt32) throws -> KeepAwakeAssertion? {
        guard let raw = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any] else { return nil }
        guard let name = raw[kIOPMAssertionNameKey as String] as? String,
              let kind = raw[kIOPMAssertionTypeKey as String] as? String,
              let level = raw[kIOPMAssertionLevelKey as String] as? NSNumber,
              let seconds = raw[kIOPMAssertionTimeoutKey as String] as? NSNumber,
              let action = raw[kIOPMAssertionTimeoutActionKey as String] as? String else { throw KeepAwakeError.unconfirmed }
        return .init(name: name, kind: kind, active: level.intValue == 1 || level.uint32Value == kIOPMAssertionLevelOn,
                     seconds: seconds.intValue, releasesOnTimeout: action == (kIOPMAssertionTimeoutActionRelease as String))
    }
    func release(_ id: UInt32, name: String) throws {
        guard owned[id] == name else { throw KeepAwakeError.foreignAssertion }
        guard let raw = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any] else { owned.removeValue(forKey: id); return }
        guard raw[kIOPMAssertionNameKey as String] as? String == name else { throw KeepAwakeError.foreignAssertion }
        guard IOPMAssertionRelease(id) == kIOReturnSuccess else { throw KeepAwakeError.releaseFailed }
        owned.removeValue(forKey: id)
    }
}

@MainActor final class KeepAwakeService: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var message: String?
    @Published private(set) var ownedAssertionID: UInt32?
    private var name: String?
    private var timer: Task<Void, Never>?
    private var started: ContinuousClock.Instant?
    private var duration = 0
    private let driver: any KeepAwakeTransport
    private let allowed: Bool
    private let sleeper: @Sendable (Duration) async throws -> Void
    var isAvailable: Bool { allowed }
    var hasOwnedAssertion: Bool { ownedAssertionID != nil }
    var remainingSeconds: Int {
        guard let started, hasOwnedAssertion else { return 0 }
        return max(0, duration - Int(started.duration(to: .now).components.seconds))
    }
    init(driver: any KeepAwakeTransport = NativeKeepAwakeTransport(), allowed: Bool = true,
         sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.driver = driver; self.allowed = allowed; self.sleeper = sleeper
    }
    func start(seconds: Int) throws {
        guard allowed else { throw KeepAwakeError.unavailable }
        guard !hasOwnedAssertion else { throw KeepAwakeError.alreadyRunning }
        guard (1...7200).contains(seconds) else { throw KeepAwakeError.invalidDuration }
        message = nil
        let token = "Tilvero Keep Awake \(UUID().uuidString)"
        do {
            let id = try driver.create(seconds: seconds, name: token)
            ownedAssertionID = id; name = token
            guard let actual = try driver.read(id), actual.name == token,
                  actual.kind == "PreventUserIdleSystemSleep", actual.active,
                  actual.seconds == seconds, actual.releasesOnTimeout else { throw KeepAwakeError.unconfirmed }
            duration = seconds; started = .now; isActive = true
            let wait = sleeper
            timer = Task { [weak self] in
                do { try await wait(.seconds(seconds)) } catch { return }
                guard let self, self.name == token else { return }
                try? self.stop()
            }
        } catch {
            let original = error
            if hasOwnedAssertion {
                do { try stop(); message = original.localizedDescription }
                catch { message = error.localizedDescription }
            } else { message = original.localizedDescription }
            throw original
        }
    }
    func stop() throws {
        guard let id = ownedAssertionID, let name else { return }
        timer?.cancel(); timer = nil
        do {
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
            guard let actual = try driver.read(id) else { clear(); return }
            guard actual.name == name, actual.kind == "PreventUserIdleSystemSleep" else { throw KeepAwakeError.foreignAssertion }
            guard actual.seconds == duration, actual.releasesOnTimeout else { throw KeepAwakeError.unconfirmed }
            if !actual.active || remainingSeconds == 0 { try stop() } else { isActive = true }
        } catch { isActive = false; message = error.localizedDescription; throw error }
    }
    private func clear() {
        timer?.cancel(); timer = nil; ownedAssertionID = nil; name = nil
        started = nil; duration = 0; isActive = false; message = nil
    }
}
