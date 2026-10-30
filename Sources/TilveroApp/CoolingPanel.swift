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
    private func readings(_ ids: [String]) -> [CatalogReading] {
        CatalogDataGroup.filtered(ids.compactMap(reading), search: "", showUnavailable: showUnavailable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 9) {
                Image(systemName: model.fanless ? "leaf.fill" : "fan")
                    .font(.system(size: 29, weight: .light)).foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(L10n.text(model.fanless ? "Fanless cooling" : "System cooling"))
                    .font(.title2.weight(.medium)).multilineTextAlignment(.center)
                Text(L10n.text(model.fanless
                               ? "This MacBook Air has no fans. macOS manages cooling automatically."
                               : "Fan control is not verified on this hardware."))
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 22) {
                    metric("039", title: "Battery temperature").frame(width: 145)
                    illustration(height: 175).frame(width: 250)
                    metric("044", title: "System thermal state").frame(width: 150)
                }.frame(maxWidth: .infinity)
                VStack(spacing: 18) {
                    illustration(height: 165)
                    HStack(alignment: .top, spacing: 28) {
                        metric("039", title: "Battery temperature")
                        metric("044", title: "System thermal state")
                    }
                }
            }
            Text(L10n.text("Device illustrations are schematic."))
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            HStack(alignment: .top, spacing: 20) {
                DataReadingSection(title: "Thermal observations", readings: readings(["039", "044", "040"]), fahrenheit: model.fahrenheit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DataReadingSection(title: "Other sensors", readings: readings(["094"]), fahrenheit: model.fahrenheit)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(L10n.text("Missing thermal and fan readings remain unavailable. Sensors are not reconstructed."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func illustration(height: CGFloat) -> some View {
        Group {
            if let artwork = EnergyArtwork.overviewMac {
                Image(nsImage: artwork).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "laptopcomputer").font(.system(size: 70, weight: .ultraLight))
            }
        }.frame(height: height).accessibilityHidden(true)
            .help(L10n.text("Device illustrations are schematic."))
    }

    private func metric(_ id: String, title: String) -> some View {
        let observation = reading(id)
        let value = observation.map { CatalogDataPresentation.value($0, reveal: false, fahrenheit: model.fahrenheit) } ?? "—"
        return VStack(alignment: .leading, spacing: 7) {
            Text(value)
                .font(.system(size: value.rangeOfCharacter(from: .decimalDigits) == nil ? 22 : 28, weight: .medium, design: .rounded))
                .monospacedDigit().textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(L10n.text(title)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let observation { ReadingInfoButton(reading: observation, fahrenheit: model.fahrenheit) }
            }
            if let observation {
                ForEach(CatalogDataPresentation.qualifications(observation), id: \.self) { qualification in
                    Text(qualification).font(.system(size: 11))
                        .foregroundStyle(observation.freshness == .stale ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(L10n.text("Unavailable")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
