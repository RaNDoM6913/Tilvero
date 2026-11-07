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

    static func absent(for id: String, adapterConnected: Bool) -> String? {
        id == "054" && !adapterConnected ? L10n.text(adapterAbsentKey) : nil
    }
}
// tlv-origin:61e8b495c82de764
