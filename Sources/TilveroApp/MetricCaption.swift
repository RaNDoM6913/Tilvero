// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import PowerCore

/// Honest boundary wording shown under overview metrics. Wording follows the
/// reading's own provenance; the approximation prefix belongs to
/// `CatalogDataPresentation.value`, never to these captions.
enum MetricCaption {
    static let batteryEstimateKey = "battery · V×A estimate"
    static let adapterBoundaryKey = "Adapter input — a different boundary"
    static let adapterAbsentKey = "Adapter not connected — no reading"
    static let allKeys = [batteryEstimateKey, adapterBoundaryKey, adapterAbsentKey]

    // Combined power chart: one caption naming both boundaries, one "no adapter line" message.
    static let combinedBatteryEstimateKey = "battery: V×A estimate, sign: + into the battery"
    static let combinedBatterySignKey = "battery: sign: + into the battery"
    static let combinedAdapterKey = "adapter: input, a different boundary"
    static let combinedNoBatteryReadingKey = "no reading from macOS"
    static let combinedAdapterNoLineKey = "Adapter not connected — no adapter line"
    static let combinedKeys = [combinedBatteryEstimateKey, combinedBatterySignKey, combinedAdapterKey,
                               combinedNoBatteryReadingKey, combinedAdapterNoLineKey]

    static func boundary(for id: String, reading: CatalogReading?) -> String? {
        guard let reading else { return nil }
        switch id {
        case "038":
            return [.estimated, .inferred].contains(reading.provenance) ? L10n.text(batteryEstimateKey) : nil
        case "054":
            return L10n.text(adapterBoundaryKey)
        default:
            return nil
        }
    }

    /// Caption of the combined power chart. Without a battery reading there is nothing
    /// to name a boundary for, so only the missing-reading line is shown; otherwise
    /// both boundaries are named and the V×A estimate wording follows the provenance.
    static func combined(batteryReading: CatalogReading?) -> String {
        guard let batteryReading else { return L10n.text(combinedNoBatteryReadingKey) }
        let battery = [.estimated, .inferred].contains(batteryReading.provenance) ? combinedBatteryEstimateKey : combinedBatterySignKey
        return L10n.text(battery) + " · " + L10n.text(combinedAdapterKey)
    }

    static func absent(for id: String, adapterConnected: Bool) -> String? {
        id == "054" && !adapterConnected ? L10n.text(adapterAbsentKey) : nil
    }
}
// tlv-origin:61e8b495c82de764
