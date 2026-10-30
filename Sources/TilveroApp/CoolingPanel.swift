import SwiftUI
import PowerCore

/// Observations only. Fan policy controls retain their existing admission gate outside this view.
@MainActor
struct CoolingPanel: View {
    @ObservedObject var model: TilveroModel
    let showUnavailable: Bool

    private func reading(_ id: String) -> CatalogReading? {
        model.snapshot.catalog.first { $0.id == id }
    }
    private var thermalReadings: [CatalogReading] {
        let rows = ["039", "040", "044", "094"].compactMap(reading)
        return CatalogDataGroup.filtered(rows, search: "", showUnavailable: showUnavailable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 10) {
                Image(systemName: model.fanless ? "leaf" : "fan")
                    .font(.system(size: 25, weight: .light)).foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(L10n.text(model.fanless ? "Fanless cooling" : "System cooling"))
                    .font(.title2.weight(.medium)).multilineTextAlignment(.center)
                Text(L10n.text(model.fanless
                               ? "This MacBook Air has no fans. macOS manages cooling automatically."
                               : "Fan control is not verified on this hardware."))
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        metric("039", title: "Battery temperature").frame(width: 140)
                        illustration.frame(width: 200)
                        metric("044", title: "System thermal state").frame(width: 160)
                    }.frame(maxWidth: .infinity)
                    VStack(spacing: 18) {
                        illustration.frame(maxWidth: .infinity)
                        HStack(alignment: .top, spacing: 24) {
                            metric("039", title: "Battery temperature")
                            metric("044", title: "System thermal state")
                        }
                    }
                }.padding(.top, 10)
                Text(L10n.text("Device illustrations are schematic."))
                    .font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)
            DataReadingSection(title: "Thermal observations", readings: thermalReadings, fahrenheit: model.fahrenheit)
            Text(L10n.text("Missing thermal and fan readings remain unavailable. Sensors are not reconstructed."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 6)
    }

    private var illustration: some View {
        Group {
            if let artwork = EnergyArtwork.overviewMac {
                Image(nsImage: artwork).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "laptopcomputer").font(.system(size: 75, weight: .ultraLight))
            }
        }.frame(height: 165).accessibilityHidden(true)
    }

    private func metric(_ id: String, title: String) -> some View {
        let observation = reading(id)
        return VStack(alignment: .leading, spacing: 7) {
            Text(observation.map { CatalogDataPresentation.value($0, reveal: false, fahrenheit: model.fahrenheit) } ?? "—")
                .font(.system(size: id == "044" ? 23 : 28, weight: .medium, design: .rounded))
                .monospacedDigit().textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(L10n.text(title)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let observation { ReadingInfoButton(reading: observation, fahrenheit: model.fahrenheit) }
            }
            if let observation {
                ForEach(CatalogDataPresentation.qualifications(observation), id: \.self) { qualification in
                    Text(qualification).font(.callout)
                        .foregroundStyle(observation.freshness == .stale ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(L10n.text("Unavailable")).font(.callout).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
