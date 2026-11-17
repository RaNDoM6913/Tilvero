// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import Combine

struct UpdateCheckSnapshot: Equatable, Codable, Sendable {
    let checkedAt: Date
    let channel: UpdateChannel
    let result: UpdateDiscoveryResult
}

enum UpdateCheckPhase: Equatable, Sendable {
    case idle, checking, succeeded(UpdateCheckSnapshot), failed(UpdateCheckFailure), cancelled
}

/// Optional public discovery has its own consent and cancellation lifecycle. It
/// never downloads an app, invokes the installer, or participates in control recovery.
@MainActor final class UpdateCheckService: ObservableObject {
    let identity: UpdateIdentity
    @Published private(set) var phase: UpdateCheckPhase = .idle
    @Published private(set) var lastSuccess: UpdateCheckSnapshot?
    @Published private(set) var channel: UpdateChannel
    @Published private(set) var automaticallyChecks: Bool
    private let defaults: UserDefaults
    private let discovery: UpdateDiscovery
    private let now: @MainActor () -> Date
    private let sleeper: @MainActor (Double) async throws -> Void
    private let interval: Double
    private var started = false
    private var generation: UInt64 = 0
    private var checkTask: Task<UpdateDiscoveryResult, Error>?
    private var schedule: Task<Void, Never>?
    private static let preferencePrefix = "Tilvero.Updates."
    static let firstCheckDelay: Double = 120
    /// A failed automatic check (offline at launch, rate limit) is retried after an hour, not a day later.
    static let retryAfterFailureDelay: Double = 3_600

    init(identity: UpdateIdentity = .current(), defaults: UserDefaults = .standard,
         discovery: UpdateDiscovery = UpdateDiscovery(), now: @escaping @MainActor () -> Date = { Date() },
         interval: Double = 86_400,
         sleeper: @escaping @MainActor (Double) async throws -> Void = {
             try await Task.sleep(for: .seconds($0), clock: .suspending)
         }) {
        self.identity = identity; self.defaults = defaults; self.discovery = discovery; self.now = now
        self.interval = max(60, interval); self.sleeper = sleeper
        channel = defaults.string(forKey: Self.preferencePrefix + "channel").flatMap(UpdateChannel.init(rawValue:)) ?? identity.defaultChannel
        // On unless the user turned it off: one public GitHub request a day while Tilvero runs (no account, no readings sent).
        automaticallyChecks = defaults.object(forKey: Self.preferencePrefix + "automaticallyChecks") as? Bool ?? true
        if let data = defaults.data(forKey: cacheKey), data.count <= 262_144,
           let cached = try? JSONDecoder().decode(UpdateCachedCheck.self, from: data),
           cached.identity == identity, cached.snapshot.channel == channel,
           cached.snapshot.checkedAt.timeIntervalSince1970 >= 0,
           cached.snapshot.checkedAt <= now().addingTimeInterval(300),
           Self.validCachedResult(cached.snapshot.result, identity: identity, channel: channel) {
            lastSuccess = cached.snapshot
        }
    }

    func check() async {
        guard checkTask == nil else { return }
        generation &+= 1
        let token = generation, selected = channel
        phase = .checking
        let task = Task { [discovery, identity] in try await discovery.discover(identity: identity, channel: selected) }
        checkTask = task
        do {
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            guard generation == token, !Task.isCancelled else {
                if generation == token { checkTask = nil; phase = .cancelled }
                return
            }
            let snapshot = UpdateCheckSnapshot(checkedAt: now(), channel: selected, result: result)
            lastSuccess = snapshot
            phase = .succeeded(snapshot)
            checkTask = nil
            if let data = try? JSONEncoder().encode(UpdateCachedCheck(identity: identity, snapshot: snapshot)), data.count <= 262_144 {
                defaults.set(data, forKey: cacheKey)
            }
        } catch {
            guard generation == token else { return }
            checkTask = nil
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled { phase = .cancelled }
            else { phase = .failed(UpdateCheckFailure.classify(error)) }
        }
    }

    /// The release from the last successful check that is newer than this build (by machine build number), or nil.
    /// A failed or cancelled later check keeps it: the result stays dated and the Updates page shows it.
    var newerRelease: UpdateRelease? { lastSuccess.flatMap { Self.newerRelease(in: $0.result, than: identity) } }

    static func newerRelease(in result: UpdateDiscoveryResult, than identity: UpdateIdentity) -> UpdateRelease? {
        guard let installed = identity.build else { return nil }
        // The same record the Updates page shows (release ?? sourceRelease): an app release when one is available,
        // the source release only when nothing else is offered; "current" never produces a notice.
        let candidate: UpdateRelease?
        switch result.availability {
        case .appAvailable: candidate = result.release
        case .sourceOnly: candidate = result.sourceRelease
        case .current, .manual, .noCompatibleRelease: candidate = nil
        }
        guard let candidate, candidate.build.flatMap({ UpdateIdentity.compareBuilds($0, installed) }) == .orderedDescending else { return nil }
        return candidate
    }

    func cancel() {
        guard let task = checkTask else { return }
        generation &+= 1
        task.cancel(); checkTask = nil
        phase = .cancelled
    }

    func setChannel(_ channel: UpdateChannel) {
        guard self.channel != channel else { return }
        cancel()
        self.channel = channel
        defaults.set(channel.rawValue, forKey: Self.preferencePrefix + "channel")
        lastSuccess = nil
        phase = .idle
        reschedule()
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        guard automaticallyChecks != enabled else { return }
        automaticallyChecks = enabled
        defaults.set(enabled, forKey: Self.preferencePrefix + "automaticallyChecks")
        reschedule()
    }

    func start() { started = true; reschedule() }
    func stop() { started = false; schedule?.cancel(); schedule = nil; cancel() }

    private func reschedule() {
        schedule?.cancel(); schedule = nil
        guard started && automaticallyChecks else { return }
        // Never checked for this build and channel: shortly after launch (not a day later, which a daily restart would
        // postpone forever); otherwise when the last success turns a day old.
        let delay = lastSuccess.map { max(60, interval - max(0, now().timeIntervalSince($0.checkedAt))) } ?? Self.firstCheckDelay
        schedule = Task { [weak self, sleeper, interval] in
            var next = delay
            while !Task.isCancelled {
                do { try await sleeper(next) } catch { return }
                guard !Task.isCancelled, let self, self.started, self.automaticallyChecks else { return }
                await self.check()
                if case .failed = self.phase { next = min(interval, Self.retryAfterFailureDelay) } else { next = interval }
            }
        }
    }

    private var cacheKey: String {
        Self.preferencePrefix + "success." + (identity.bundleIdentifier ?? "unknown") + "." + identity.profile.rawValue
            + "." + (identity.version ?? "unknown") + "." + (identity.build ?? "unknown") + "." + channel.rawValue
    }

    private static func validCachedResult(_ result: UpdateDiscoveryResult, identity: UpdateIdentity, channel: UpdateChannel) -> Bool {
        let records = [result.release, result.sourceRelease].compactMap { $0 }
        guard records.allSatisfy({ record in
            UpdateDiscovery.releaseURL(tag: record.tag) == record.releaseURL
                && record.build.map(UpdateIdentity.validBuild) == true && record.notes.utf8.count <= 262_144
                && record.name.utf8.count <= 1_024
                && record.version == String(record.tag.dropFirst()).components(separatedBy: "-beta.").first
                && (channel == .beta || !record.tag.contains("-beta."))
        }), result.sourceRelease.map({ $0.kind == .sourcePreview }) ?? true else { return false }
        if let release = result.release {
            guard identity.supportsInstallerProfile, release.kind == .macApp,
                  let build = release.build, let installed = identity.build,
                  let comparison = UpdateIdentity.compareBuilds(build, installed) else { return false }
            if result.availability == .appAvailable { return comparison == .orderedDescending }
            if result.availability == .current { return comparison == .orderedSame && release.version == identity.version }
            return false
        }
        switch result.availability {
        case .sourceOnly: return result.sourceRelease != nil
        case .manual: return !identity.supportsInstallerProfile && result.sourceRelease == nil
        case .noCompatibleRelease: return result.sourceRelease == nil
        case .appAvailable, .current: return false
        }
    }
}

private struct UpdateCachedCheck: Codable {
    let identity: UpdateIdentity
    let snapshot: UpdateCheckSnapshot
}
