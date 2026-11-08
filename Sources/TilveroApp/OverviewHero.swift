// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import PowerCore
import ChargeBackends

/// What the capsule under the battery icon says about the macOS charge limit. It is a display only: the limit is
/// changed on the Charge page, which the capsule opens.
enum OverviewHeroLimit: Equatable {
    /// This Mac has no native charge limit control: no capsule at all.
    case hidden
    /// The limit is not confirmed by a fresh macOS readback: a dash, never a plausible number.
    case unconfirmed
    case percent(Int)

    /// A confirmed readback (fresh, policy matches) shows its target while the limit is on and 100 % while it is
    /// off. Anything else is unconfirmed.
    static func resolve(usesNativeCharge: Bool, observed: NativeChargeSnapshot?) -> OverviewHeroLimit {
        guard usesNativeCharge else { return .hidden }
        guard let observed, observed.isFresh, observed.policyMatches else { return .unconfirmed }
        return .percent(observed.configuration.enabled ? observed.configuration.target : 100)
    }

    var text: String? {
        switch self {
        case .hidden: nil
        case .unconfirmed: "—"
        case .percent(let value): "\(value)%"
        }
    }
}

/// The battery block of the Overview page: charge, state, icon and the limit capsule, as wide as the icon.
@MainActor struct OverviewHero: View {
    nonisolated static let iconWidth: CGFloat = 54
    @ObservedObject var model: TilveroModel
    /// Opens the Charge page. `nil` in the passive builder preview.
    var openCharge: (@MainActor () -> Void)?

    private var limit: OverviewHeroLimit {
        .resolve(usesNativeCharge: model.usesNativeCharge, observed: model.nativeCharge.observed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    StudioText(model.chargeText, id: "quick.charge.value").font(.system(size: 42, weight: .semibold, design: .rounded)).monospacedDigit()
                    StudioText(model.chargingStateText, id: "quick.charge.status").font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(spacing: 6) {
                    Image(nsImage: NativeBatteryStatusImage.make(
                        level: model.snapshot.chargePercent.availability == .available || model.snapshot.chargePercent.freshness == .stale ? ReadingPresentation.validLevel(model.snapshot.chargePercent.value) : nil,
                        style: .iconOnly,
                        externalPower: model.snapshot.isExternalPower.availability == .available && model.snapshot.isExternalPower.freshness != .stale && model.snapshot.isExternalPower.value == true))
                        .resizable().interpolation(.high).frame(width: Self.iconWidth, height: 36)
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                    if let text = limit.text { capsule(text) }
                }
            }
            if model.snapshot.chargePercent.freshness == .stale {
                Text(L10n.text("Stale")).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private func capsule(_ text: String) -> some View {
        let label = Text(text).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(Color.accentColor)
            .frame(width: Self.iconWidth, height: 20)
            .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: 1))
            .contentShape(Capsule())
        if let openCharge {
            Button(action: openCharge) { label }.buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Charge limit"))
                .accessibilityValue(limit == .unconfirmed ? L10n.text("Unavailable") : text)
                .accessibilityHint(L10n.text("Charge"))
                .studioElement("quick.charge.limit", label: "Charge limit")
        } else {
            label.accessibilityLabel(L10n.text("Charge limit")).accessibilityValue(limit == .unconfirmed ? L10n.text("Unavailable") : text)
        }
    }
}
