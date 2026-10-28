import Foundation
import AppKit
import Darwin

public struct ProcessApplicationIdentity: Sendable, Equatable {
    public let key: String
    public let name: String
    public let bundlePath: String
    public init(key: String, name: String, bundlePath: String) { self.key = key; self.name = name; self.bundlePath = bundlePath }
}
public struct ProcessResourceCounter: Sendable {
    public let pid: Int32
    public let start: UInt64
    public let flavor: Int32
    public let name: String
    public let application: ProcessApplicationIdentity?
    public let cpuTicks: UInt64
    public let cpuEnergyNanojoules: UInt64?
    public let performanceEnergyNanojoules: UInt64?
    public let idleWakeups: UInt64
    public let interruptWakeups: UInt64
    public let readBytes: UInt64
    public let writtenBytes: UInt64
    public init(pid: Int32, start: UInt64, flavor: Int32 = 6, name: String, application: ProcessApplicationIdentity? = nil,
                cpuTicks: UInt64, cpuEnergyNanojoules: UInt64? = nil, performanceEnergyNanojoules: UInt64? = nil,
                idleWakeups: UInt64 = 0, interruptWakeups: UInt64 = 0, readBytes: UInt64 = 0, writtenBytes: UInt64 = 0) {
        self.pid = pid; self.start = start; self.flavor = flavor; self.name = name; self.application = application
        self.cpuTicks = cpuTicks; self.cpuEnergyNanojoules = cpuEnergyNanojoules; self.performanceEnergyNanojoules = performanceEnergyNanojoules
        self.idleWakeups = idleWakeups; self.interruptWakeups = interruptWakeups; self.readBytes = readBytes; self.writtenBytes = writtenBytes
    }
    var identity: String { "\(pid):\(start):\(flavor)" }
}
public struct ProcessResourceCollection: Sendable {
    public let collectedAt: Date
    public let monotonic: Double
    public let counters: [ProcessResourceCounter]
    public let deniedCount: Int
    public let unavailableCount: Int
    public let listedCount: Int
    public let truncated: Bool
    public let collectionError: String?
    public init(collectedAt: Date, monotonic: Double, counters: [ProcessResourceCounter], deniedCount: Int = 0, unavailableCount: Int = 0,
                listedCount: Int? = nil, truncated: Bool = false, collectionError: String? = nil) {
        self.collectedAt = collectedAt; self.monotonic = monotonic; self.counters = counters; self.deniedCount = deniedCount
        self.unavailableCount = unavailableCount; self.listedCount = listedCount ?? counters.count + deniedCount + unavailableCount; self.truncated = truncated; self.collectionError = collectionError
    }
}
public struct ProcessActivityRow: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let bundlePath: String?
    public var processCount: Int
    public var cpuProcessCount: Int
    public var energyProcessCount: Int
    public var cpuPercent: Double?
    public var cpuPowerWatts: Double?
    public var cpuEnergyJoules: Double?
    public var performanceCPUShare: Double?
    public var idleWakeupsPerSecond: Double?
    public var interruptWakeupsPerSecond: Double?
    public var readBytesPerSecond: Double?
    public var writtenBytesPerSecond: Double?
}
public struct ProcessActivitySnapshot: Sendable {
    public let collectedAt: Date
    public let rows: [ProcessActivityRow]
    public let accessibleCount: Int
    public let listedCount: Int
    public let deniedCount: Int
    public let unavailableCount: Int
    public let truncated: Bool
    public let isWarmingUp: Bool
    public let intervalSeconds: Double?
    public let collectionError: String?
}

public struct ProcessActivitySampler {
    private var previous: ProcessResourceCollection?
    private let timebaseNumerator: Double
    private let timebaseDenominator: Double
    public init(timebaseNumerator: UInt32 = 1, timebaseDenominator: UInt32 = 1) {
        self.timebaseNumerator = Double(timebaseNumerator); self.timebaseDenominator = Double(timebaseDenominator)
    }
    public mutating func reset() { previous = nil }
    public mutating func accept(_ current: ProcessResourceCollection) -> ProcessActivitySnapshot {
        let before = previous; previous = current
        let elapsed = before.map { current.monotonic - $0.monotonic }
        let valid = elapsed.map { $0.isFinite && $0 >= 0.05 && $0 <= 120 } == true && timebaseDenominator > 0 && timebaseNumerator > 0 && current.collectionError == nil && before?.collectionError == nil
        var groups: [String: ProcessActivityRow] = [:]
        if valid, let before, let elapsed {
            var old: [String: ProcessResourceCounter] = [:]
            for item in before.counters where old[item.identity] == nil { old[item.identity] = item }
            var seen: Set<String> = []
            for item in current.counters where seen.insert(item.identity).inserted {
                guard let first = old[item.identity], item.start > 0 else { continue }
                func delta(_ new: UInt64, _ old: UInt64) -> Double? { new >= old ? Double(new - old) : nil }
                func rate(_ new: UInt64, _ old: UInt64) -> Double? { delta(new, old).map { $0 / elapsed } }
                let cpu = delta(item.cpuTicks, first.cpuTicks).map { $0 * timebaseNumerator / timebaseDenominator / 1e9 / elapsed * 100 }
                let energy: Double? = {
                    guard let a = first.cpuEnergyNanojoules, let b = item.cpuEnergyNanojoules, a > 0 || b > 0 else { return nil }
                    return delta(b, a).map { $0 / 1e9 }
                }()
                let performance: Double? = {
                    guard let energy, energy > 0, let a = first.performanceEnergyNanojoules, let b = item.performanceEnergyNanojoules,
                          let d = delta(b, a).map({ $0 / 1e9 }), d <= energy else { return nil }
                    return d / energy * 100
                }()
                let key = item.application.map { "app:" + $0.key } ?? item.identity
                let row = ProcessActivityRow(id: key, name: item.application?.name ?? item.name, bundlePath: item.application?.bundlePath,
                    processCount: 1, cpuProcessCount: cpu == nil ? 0 : 1, energyProcessCount: energy == nil ? 0 : 1, cpuPercent: cpu, cpuPowerWatts: energy.map { $0 / elapsed }, cpuEnergyJoules: energy,
                    performanceCPUShare: performance, idleWakeupsPerSecond: rate(item.idleWakeups, first.idleWakeups), interruptWakeupsPerSecond: rate(item.interruptWakeups, first.interruptWakeups),
                    readBytesPerSecond: rate(item.readBytes, first.readBytes), writtenBytesPerSecond: rate(item.writtenBytes, first.writtenBytes))
                if var group = groups[key] {
                    func sum(_ a: Double?, _ b: Double?) -> Double? { a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0) }
                    group.processCount += 1; group.cpuProcessCount += row.cpuProcessCount; group.energyProcessCount += row.energyProcessCount
                    group.cpuPercent = sum(group.cpuPercent, row.cpuPercent); group.cpuPowerWatts = sum(group.cpuPowerWatts, row.cpuPowerWatts)
                    group.cpuEnergyJoules = sum(group.cpuEnergyJoules, row.cpuEnergyJoules)
                    group.performanceCPUShare = nil // A simple mean would misweight different CPU-energy totals.
                    group.idleWakeupsPerSecond = sum(group.idleWakeupsPerSecond, row.idleWakeupsPerSecond)
                    group.interruptWakeupsPerSecond = sum(group.interruptWakeupsPerSecond, row.interruptWakeupsPerSecond)
                    group.readBytesPerSecond = sum(group.readBytesPerSecond, row.readBytesPerSecond)
                    group.writtenBytesPerSecond = sum(group.writtenBytesPerSecond, row.writtenBytesPerSecond)
                    groups[key] = group
                } else { groups[key] = row }
            }
        }
        var totals: [String: Int] = [:], unique: Set<String> = []
        for item in current.counters where unique.insert(item.identity).inserted {
            let key = item.application.map { "app:" + $0.key } ?? item.identity
            totals[key, default: 0] += 1
        }
        for (key, total) in totals { if var row = groups[key] { row.processCount = total; groups[key] = row } }
        let rows = groups.values.sorted {
            let a = $0.cpuPowerWatts ?? -1, b = $1.cpuPowerWatts ?? -1
            return a == b ? ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) : a > b
        }
        return .init(collectedAt: current.collectedAt, rows: rows, accessibleCount: current.counters.count, listedCount: current.listedCount,
            deniedCount: current.deniedCount, unavailableCount: current.unavailableCount, truncated: current.truncated, isWarmingUp: !valid, intervalSeconds: valid ? elapsed : nil, collectionError: current.collectionError)
    }
}

/// Public read-only resource accounting. Process/app identity stays in memory.
public struct ProcessActivityProvider: Sendable {
    public init() {}
    public static var timebase: (numerator: UInt32, denominator: UInt32) {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        return (info.numer, info.denom)
    }
    public func read() async -> ProcessResourceCollection {
        let applications: [ProcessApplicationIdentity] = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard let url = app.bundleURL, let name = app.localizedName else { return nil }
                let path = url.resolvingSymlinksInPath().path
                return ProcessApplicationIdentity(key: path, name: name, bundlePath: path)
            }.sorted { $0.bundlePath.count < $1.bundlePath.count }
        }
        return await Task.detached(priority: .utility) { Self.collect(applications: applications) }.value
    }
    private static func collect(applications: [ProcessApplicationIdentity]) -> ProcessResourceCollection {
        let requested = max(0, Int(proc_listallpids(nil, 0)))
        var pids = [Int32](repeating: 0, count: min(4096, max(128, requested + 128)))
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var counters: [ProcessResourceCounter] = [], denied = 0, unavailable = 0
        let scanPIDs = count > 0 ? Set(pids.prefix(min(Int(count), pids.count))).filter { $0 > 0 }.sorted() : []
        if count > 0 {
            for pid in scanPIDs {
                var raw = rusage_info_v6()
                let result = withUnsafeMutableBytes(of: &raw) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self)) }
                let error = errno
                var flavor: Int32 = 6
                if result != 0 {
                    if error == EPERM || error == EACCES { denied += 1; continue }
                    guard error == EINVAL || error == ENOTSUP else { unavailable += 1; continue }
                    // V4 is a prefix of V6; CPU and I/O remain available, energy does not.
                    raw = rusage_info_v6()
                    let fallback = withUnsafeMutableBytes(of: &raw) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self)) }
                    guard fallback == 0 else {
                        if errno == EPERM || errno == EACCES { denied += 1 } else { unavailable += 1 }; continue
                    }
                    flavor = 4
                }
                let (cpu, overflow) = raw.ri_user_time.addingReportingOverflow(raw.ri_system_time)
                guard !overflow, raw.ri_proc_start_abstime > 0 else { unavailable += 1; continue }
                var pathBytes = [CChar](repeating: 0, count: 4096 /* libproc: 4 * MAXPATHLEN */)
                let pathCount = pathBytes.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
                let path = pathCount > 0 ? String(decoding: pathBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
                let app = path.flatMap { path in applications.first { path.hasPrefix($0.bundlePath + "/Contents/") } }
                var nameBytes = [CChar](repeating: 0, count: 256)
                let nameCount = nameBytes.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
                let rawName = nameCount > 0 ? String(decoding: nameBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : "Process \(pid)"
                let name = String(rawName.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(120))
                counters.append(.init(pid: pid, start: raw.ri_proc_start_abstime, flavor: flavor, name: name, application: app,
                    cpuTicks: cpu, cpuEnergyNanojoules: flavor == 6 ? raw.ri_energy_nj : nil, performanceEnergyNanojoules: flavor == 6 ? raw.ri_penergy_nj : nil,
                    idleWakeups: raw.ri_pkg_idle_wkups, interruptWakeups: raw.ri_interrupt_wkups, readBytes: raw.ri_diskio_bytesread, writtenBytes: raw.ri_diskio_byteswritten))
            }
        }
        let scale = timebase
        let time = Double(mach_continuous_time()) * Double(scale.numerator) / Double(max(1, scale.denominator)) / 1e9
        return .init(collectedAt: Date(), monotonic: time, counters: counters, deniedCount: denied, unavailableCount: unavailable,
            listedCount: scanPIDs.count, truncated: requested > pids.count || Int(count) >= pids.count,
            collectionError: count <= 0 ? "macOS process enumeration is unavailable." : nil)
    }
}
