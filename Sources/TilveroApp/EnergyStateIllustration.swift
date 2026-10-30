import SwiftUI
import PowerCore

@MainActor enum EnergyArtwork {
    private static let bundle: Bundle = {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }()
    private static func load(_ name: String) -> NSImage? {
        bundle.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }
    static let image = load("BatteryAssembly")
    static let adapter = load("AdapterIllustration")
    static let mac = load("MacIllustration")
    static let overviewMac = load("OverviewMacIllustration")
    static let rest = load("RestIllustration")
}

/// Original energy-line mark. It is branding, not an activity trace or measurement.
struct TilveroEnergyMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { .init(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        path.move(to: point(0.04, 0.66))
        path.addCurve(to: point(0.29, 0.25), control1: point(0.13, 0.66), control2: point(0.16, 0.13))
        path.addCurve(to: point(0.56, 0.74), control1: point(0.40, 0.25), control2: point(0.42, 0.74))
        path.addCurve(to: point(0.82, 0.26), control1: point(0.68, 0.74), control2: point(0.69, 0.26))
        path.addCurve(to: point(0.96, 0.40), control1: point(0.87, 0.26), control2: point(0.90, 0.40))
        return path
    }
}

/// Graphic qualification is independent of the platform's charging-status label.
/// A connected adapter alone never establishes a battery-current direction.
struct EnergyVisualSnapshot: Equatable {
    enum Direction: Equatable { case intoBattery, fromBattery, stationary, unknown }
    let level: Int?
    let levelIsStale: Bool
    let direction: Direction
    let sourceConnected: Bool?
    let canAnimateLevel: Bool

    init(_ snapshot: BatterySnapshot) {
        let charge = snapshot.chargePercent
        level = charge.availability == .available || charge.freshness == .stale ? ReadingPresentation.validLevel(charge.value) : nil
        levelIsStale = charge.freshness == .stale
        let source = snapshot.isExternalPower
        sourceConnected = source.availability == .available && source.freshness != .stale ? source.value : nil
        if let flow = snapshot.catalog.first(where: { $0.id == "017" }), flow.availability == .available, flow.freshness == .fresh {
            switch flow.value {
            case .text("intoBattery"): direction = .intoBattery
            case .text("fromBattery"): direction = .fromBattery
            case .text("nearZeroMeasuredCurrent"): direction = .stationary
            default: direction = .unknown
            }
        } else { direction = .unknown }
        // Interpolating an observed level change does not claim an independent sensor sample time.
        // Direction remains stricter: unknown/stale flow never animates or gains a direction.
        canAnimateLevel = level != nil && charge.availability == .available && charge.freshness != .stale
    }
}

/// Cached original artwork is schematic; its geometry never represents reported cells.
@MainActor struct EnergyArtworkView: View {
    let image: NSImage?
    let symbol: String
    let height: CGFloat
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: symbol).font(.system(size: 70, weight: .ultraLight)).foregroundStyle(.secondary)
            }
        }.frame(height: height).accessibilityHidden(true)
    }
}

struct EnergySchematicCaption: View {
    var body: some View {
        Text(L10n.text("Schematic illustration")).font(.caption2).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .help(L10n.text("The illustration does not identify the device model, physical cell layout or count, component manufacturer or authenticity."))
    }
}

/// An original pack illustration, not a reconstruction of the Mac's cell layout.
/// Its static shape does not imply current direction, cell count or a live sample.
@MainActor struct EnergyStateIllustration: View {
    let state: EnergyVisualSnapshot
    var body: some View {
        EnergyArtworkView(image: EnergyArtwork.image, symbol: "battery.100percent", height: 175)
            .opacity(state.level == nil ? 0.3 : state.levelIsStale ? 0.48 : 1)
    }
}

@MainActor struct BatteryEnergyHeading: View {
    @ObservedObject var model: TilveroModel
    private var state: EnergyVisualSnapshot { .init(model.snapshot) }
    var body: some View {
        VStack(spacing: 18) {
            charge
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 22) {
                    leftRail.frame(width: 145)
                    EnergyStateIllustration(state: state).frame(width: 250)
                    rightRail.frame(width: 150)
                }.frame(maxWidth: .infinity)
                VStack(spacing: 18) {
                    EnergyArtworkView(image: EnergyArtwork.image, symbol: "battery.100percent", height: 165)
                        .opacity(state.level == nil ? 0.3 : state.levelIsStale ? 0.48 : 1)
                    HStack(alignment: .top, spacing: 28) { leftRail; rightRail }
                }
            }
            VStack(spacing: 6) {
                ProductChargeTrack(level: state.level, stale: state.levelIsStale, animate: state.canAnimateLevel)
                    .frame(maxWidth: 220)
                Text(state.level == nil ? L10n.text("Unavailable") : model.chargeText + " " + L10n.text("charge"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            EnergySchematicCaption()
            KeepAwakeEnergyBadge(service: model.keepAwake)
            if model.isDemo {
                Text(L10n.text("Simulation only — your Mac settings are unchanged."))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }
    private var leftRail: some View {
        VStack(alignment: .leading, spacing: 26) {
            CatalogSummaryMetric(model: model, id: "039", title: "Battery temperature")
            CatalogSummaryMetric(model: model, id: "035", title: "Battery voltage")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var rightRail: some View {
        VStack(alignment: .leading, spacing: 26) {
            CatalogSummaryMetric(model: model, id: "026", title: "Capacity retention")
            CatalogSummaryMetric(model: model, id: "027", title: "Charge cycles")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var charge: some View {
        VStack(spacing: 5) {
            Text(model.chargeText).font(.system(size: 44, weight: .semibold)).monospacedDigit()
                .foregroundStyle(state.levelIsStale || state.level == nil ? Color.secondary : Color.green)
            HStack(spacing: 5) {
                Text(model.chargingStateText).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if let reading = model.snapshot.catalog.first(where: { $0.id == "011" }) {
                    ReadingInfoButton(reading: reading, fahrenheit: model.fahrenheit)
                }
            }
            if let reading = model.snapshot.catalog.first(where: { $0.id == "011" }) {
                let quality = CatalogDataPresentation.qualifications(reading)
                if !quality.isEmpty {
                    Text(quality.joined(separator: " · ")).font(.caption)
                        .foregroundStyle(state.levelIsStale ? Color.orange : Color.secondary)
                }
            }
        }.frame(maxWidth: .infinity)
    }
}

@MainActor private struct KeepAwakeEnergyBadge: View {
    @ObservedObject var service: KeepAwakeService
    var body: some View {
        switch KeepAwakeStatusIndicator(service: service) {
        case .off: EmptyView()
        case .active:
            Label(L10n.text("Keep Awake active"), systemImage: "cup.and.saucer.fill")
                .font(.caption).foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.1), in: Capsule())
        case .unconfirmed:
            Label(L10n.text("Keep Awake state unconfirmed"), systemImage: "questionmark.circle")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

struct PowerHeadlineReading {
    let value: String
    let source: String?
    let qualificationKey: String?
    init(_ reading: CatalogReading?) {
        guard let reading else { value = "—"; source = nil; qualificationKey = "Unavailable"; return }
        value = CatalogDataPresentation.value(reading, reveal: false, fahrenheit: false)
        source = reading.source
        if reading.value == nil || (reading.availability != .available && reading.freshness != .stale) {
            qualificationKey = "Unavailable"
        } else {
            switch reading.freshness {
            case .stale: qualificationKey = "Stale"
            case .unknown: qualificationKey = "Freshness unknown"
            case .fresh: qualificationKey = nil
            }
        }
    }
}

@MainActor struct PowerConnectionHeading: View {
    @ObservedObject var model: TilveroModel
    private var state: EnergyVisualSnapshot { .init(model.snapshot) }
    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .top, spacing: 28) {
                CatalogSummaryMetric(model: model, id: "054", title: "Input power")
                source
            }
            GeometryReader { geometry in
                HStack(alignment: .center, spacing: 0) {
                    EnergyArtworkView(image: EnergyArtwork.adapter, symbol: "powerplug", height: 185)
                        .frame(width: geometry.size.width * 0.30)
                        .opacity(state.sourceConnected == false ? 0.38 : 1)
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 0))
                        path.addCurve(to: CGPoint(x: geometry.size.width * 0.10, y: 32),
                                      control1: CGPoint(x: geometry.size.width * 0.04, y: 0),
                                      control2: CGPoint(x: geometry.size.width * 0.04, y: 32))
                    }
                    .stroke(Color.secondary.opacity(state.sourceConnected == true ? 0.35 : 0.15), lineWidth: 1.5)
                    .frame(width: geometry.size.width * 0.10, height: 32).offset(y: 42)
                    EnergyArtworkView(image: EnergyArtwork.overviewMac ?? EnergyArtwork.mac, symbol: "laptopcomputer", height: 205)
                        .frame(width: geometry.size.width * 0.60)
                }
            }.frame(height: 205).accessibilityHidden(true)
                .help(L10n.text("The line shows a schematic connection, not power direction or magnitude. Exact device model is not identified by the illustration or power capability."))
            CatalogSummaryMetric(model: model, id: "038", title: "Battery power")
                .frame(maxWidth: 260)
            Divider()
            nativeLimit
        }
    }
    private var source: some View {
        let reading = model.snapshot.catalog.first { $0.id == "016" }
        return VStack(alignment: .leading, spacing: 7) {
            Text(reading.map { CatalogDataPresentation.value($0, reveal: false, fahrenheit: model.fahrenheit) } ?? "—")
                .font(.system(size: 23, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                Text(L10n.text("Reported power source")).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reading { ReadingInfoButton(reading: reading, fahrenheit: model.fahrenheit) }
            }
            if let reading {
                let quality = CatalogDataPresentation.qualifications(reading)
                if !quality.isEmpty {
                    Text(quality.joined(separator: " · ")).font(.system(size: 11))
                        .foregroundStyle(reading.freshness == .stale ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var nativeLimit: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(L10n.text("macOS charge limit")).font(.headline)
                Text(limitText ?? L10n.text("Unavailable")).font(.headline)
                    .foregroundStyle(limitText == nil ? Color.secondary : Color.green)
            }
            if let setting = model.nativeCharge.nativeSetting, setting.isFresh {
                Text(L10n.text(setting.configuration.optimizedCharging ? "Optimized charging enabled" : "Optimized charging disabled"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .help(L10n.text("macOS manages this setting independently of Tilvero."))
    }
    private var limitText: String? {
        if let setting = model.nativeCharge.nativeSetting, setting.isFresh {
            return setting.configuration.enabled ? "\(setting.configuration.target)%" : L10n.text("System managed")
        }
        if let observation = model.systemChargeLimit, observation.isFresh(), let limits = observation.limits,
           !limits.manualLimitIsConflicting, let limit = limits.manualLimit { return "\(limit)%" }
        return nil
    }
}
