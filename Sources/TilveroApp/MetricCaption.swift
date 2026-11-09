// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import PowerCore

extension BatterySnapshot {
    /// The one derivation of "an adapter is plugged in" for the overview charts. An unknown
    /// external-power state (nil) counts as connected: "not connected" is claimed only on evidence.
    var adapterIsConnected: Bool { isExternalPower.value != false }
}

/// Status messages of the overview charts. There are no explanatory captions any more (owner 2026-11-09: the title
/// is enough; the "≈" in front of an estimated value already says so, and the source stays in the tooltip). Only the
/// state "no adapter" is worded, inside the empty chart frame or as one line when no chart is drawn.
enum MetricCaption {
    static let adapterAbsentKey = "Adapter not connected — no reading"
    static let combinedAdapterNoLineKey = "Adapter not connected — no adapter line"
    static let allKeys = [adapterAbsentKey]
    static let combinedKeys = [combinedAdapterNoLineKey]

    static func absent(for id: String, adapterConnected: Bool) -> String? {
        id == "054" && !adapterConnected ? L10n.text(adapterAbsentKey) : nil
    }
}
// tlv-origin:61e8b495c82de764
