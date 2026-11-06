import Foundation

/// Shared rule for "this reading is a current observation made by the app".
///
/// IOPowerSources publishes no sample time, so the provider reports its charge and
/// power rows with unknown freshness and never invents a hardware timestamp. Consumers
/// that need a current value (sleep endpoints, discharge forecast) may still use such a
/// row when the app itself collected it within `window` seconds. That is an app
/// observation, not a hardware sample whose physical age is known.
public enum CurrentObservation {
    public static let window: TimeInterval = 60
    /// Exact IOPowerSources key paths the provider writes for each admitted catalog row.
    /// Pinned to the provider by `SleepEndpointNormalizationTests`.
    public static let appObservedIOPSKeyPaths: [String: String] = [
        "011": "Current Capacity/Max Capacity", "013": "Is Charging", "015": "Power Source State",
    ]
    static let source = "IOPowerSources"

    /// `.fresh` readings pass unchanged (callers keep their own age guards). `.stale` never passes.
    /// `.unknown` passes only for the allowlisted IOPowerSources rows with no timestamps of their own.
    static func admits(id: String, source: String, keyPath: String, hasValue: Bool,
                       availability: TelemetryAvailability, freshness: TelemetryFreshness,
                       provenance: TelemetryProvenance, collectedAt: Date, sourceSampleAt: Date?,
                       monotonicAgeSeconds: TimeInterval?, at now: Date) -> Bool {
        guard hasValue, availability == .available else { return false }
        switch freshness {
        case .fresh: return true
        case .stale: return false
        case .unknown:
            guard source == Self.source, appObservedIOPSKeyPaths[id] == keyPath, provenance == .reported,
                  sourceSampleAt == nil, monotonicAgeSeconds == nil,
                  collectedAt.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite else { return false }
            let age = now.timeIntervalSince(collectedAt)
            return age >= -1 && age <= window
        }
    }
}

extension CatalogReading {
    /// Whether this row is usable as a current observation at `now` (see `CurrentObservation`).
    public func isCurrentObservation(at now: Date) -> Bool {
        CurrentObservation.admits(id: id, source: source, keyPath: keyPath, hasValue: value != nil,
            availability: availability, freshness: freshness, provenance: provenance, collectedAt: collectedAt,
            sourceSampleAt: sourceSampleAt, monotonicAgeSeconds: monotonicAgeSeconds, at: now)
    }
}

extension TelemetryReading {
    /// Typed readings carry `"<source>/<keyPath>"` in `source`; the key path may itself contain `/`.
    public func isCurrentObservation(catalogID: String, at now: Date) -> Bool {
        let parts = source.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts.first.map(String.init) ?? source
        let keyPath = parts.count > 1 ? String(parts[1]) : ""
        return CurrentObservation.admits(id: catalogID, source: name, keyPath: keyPath, hasValue: value != nil,
            availability: availability, freshness: freshness, provenance: provenance, collectedAt: collectedAt,
            sourceSampleAt: sourceSampleAt, monotonicAgeSeconds: monotonicAgeSeconds, at: now)
    }
}
