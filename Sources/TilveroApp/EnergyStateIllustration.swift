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

/// Opaque, adaptive surfaces shared by the main application. Menu-bar content
/// keeps its own native blue/material styling and does not use this wrapper.
struct ProductSurface<Content: View>: View {
    var title: String? = nil
    var symbol: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                HStack(spacing: 8) {
                    if let symbol { Image(systemName: symbol).foregroundStyle(Color.accentColor) }
                    Text(L10n.text(title)).font(.headline)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.06)))
    }
}

struct ProductSectionHeading: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text(title)).font(.headline)
            if let subtitle { Text(L10n.text(subtitle)).font(.callout).foregroundStyle(.secondary) }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor struct ProductIntro: View {
    let title: String
    let subtitle: String
    let symbol: String
    var artwork: NSImage? = nil
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) { picture; information.frame(width: 320, alignment: .leading) }
            VStack(alignment: .leading, spacing: 16) { picture; information }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
    }
    private var picture: some View {
        Group {
            if let artwork {
                Image(nsImage: artwork).resizable().interpolation(.high).scaledToFit().frame(width: 160, height: 120)
            } else {
                Image(systemName: symbol).font(.system(size: 34, weight: .light))
                    .foregroundStyle(Color.accentColor).frame(width: 72, height: 72)
                    .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
            }
        }.accessibilityHidden(true)
    }
    private var information: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text(title)).font(.title2.weight(.medium))
            Text(L10n.text(subtitle)).font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}

struct ProductMetric: View {
    let title: String
    let value: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text(title)).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
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

/// An original pack illustration, not a reconstruction of the Mac's cell layout.
/// All motion is a finite response to changed observations; there is no render timer.
@MainActor struct EnergyStateIllustration: View {
    let state: EnergyVisualSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @State private var visible = false
    private var accent: Color { state.levelIsStale || state.level == nil ? .secondary : .accentColor }
    private var surface: Color { Color(nsColor: .controlBackgroundColor) }

    var body: some View {
        ZStack {
            if let artwork = EnergyArtwork.image {
                Image(nsImage: artwork).resizable().interpolation(.high).scaledToFit()
                    .frame(width: 320, height: 215)
                    .opacity(state.level == nil ? 0.3 : state.levelIsStale ? 0.48 : 1)
            } else {
                Ellipse().fill(.primary.opacity(colorScheme == .dark ? 0.09 : 0.05))
                    .frame(width: 190, height: 17).offset(y: 58).blur(radius: 9)
                pack
            }
            if state.direction == .intoBattery || state.direction == .fromBattery {
                Image(systemName: state.direction == .intoBattery ? "arrow.down.left" : "arrow.up.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(accent)
                    .padding(8).background(surface, in: Circle())
                    .overlay(Circle().strokeBorder(.primary.opacity(0.07)))
                    .offset(x: 137, y: -76)
                    .contentTransition(.symbolEffect(.replace))
                    .transaction { if reduceMotion || !visible || !state.canAnimateLevel { $0.animation = nil } }
            }
        }
        .frame(width: 330, height: 225)
        .accessibilityHidden(true)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }

    private var pack: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 19)
                .fill(LinearGradient(colors: [surface, Color(nsColor: .separatorColor).opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(.primary.opacity(0.16), lineWidth: 1))
            RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .underPageBackgroundColor))
                .padding(7)
            GeometryReader { geometry in
                let width = max(0, geometry.size.width - 22)
                RoundedRectangle(cornerRadius: 9)
                    .fill(LinearGradient(colors: [accent.opacity(0.6), accent.opacity(0.28)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width * CGFloat(state.level ?? 0) / 100, height: geometry.size.height - 22)
                    .padding(11)
                    .animation(visible && !reduceMotion && state.canAnimateLevel ? .easeInOut(duration: 0.45) : nil, value: state.level)
            }
            if !reduceTransparency {
                RoundedRectangle(cornerRadius: 10).fill(.white.opacity(colorScheme == .dark ? 0.05 : 0.28))
                    .frame(height: 34).padding(.horizontal, 12).offset(y: -22)
            }
            HStack {
                VStack(spacing: 47) {
                    Circle().fill(.primary.opacity(0.14)).frame(width: 3, height: 3)
                    Circle().fill(.primary.opacity(0.14)).frame(width: 3, height: 3)
                }
                Spacer()
                if state.level == nil || state.direction == .intoBattery {
                    Image(systemName: state.level == nil ? "questionmark" : "bolt.fill")
                        .font(.system(size: 21, weight: .light)).foregroundStyle(accent.opacity(0.55))
                }
            }.padding(.horizontal, 17)
        }
        .frame(width: 198, height: 112)
        .background(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.24))
                .frame(width: 9, height: 34).offset(x: 6)
        }
        .opacity(state.levelIsStale ? 0.48 : 1)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.15 : 0.08), radius: 11, x: 3, y: 9)
    }
}

@MainActor struct BatteryEnergyHeading: View {
    @ObservedObject var model: TilveroModel
    private var state: EnergyVisualSnapshot { .init(model.snapshot) }
    var body: some View {
        VStack(spacing: 16) {
            charge
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 18) {
                    leftRail.frame(width: 136)
                    illustration.frame(width: 280)
                    rightRail.frame(width: 136)
                }.frame(maxWidth: .infinity)
                VStack(spacing: 22) {
                    illustration.frame(maxWidth: .infinity)
                    HStack(alignment: .top, spacing: 24) { leftRail; rightRail }
                }
            }
            if let level = state.level {
                ProgressView(value: Double(level), total: 100)
                    .tint(state.levelIsStale ? Color.secondary : Color.green)
                    .frame(maxWidth: 340).frame(maxWidth: .infinity)
                    .accessibilityLabel(L10n.text("Charge level")).accessibilityValue(model.chargeText)
            }
            Text(L10n.text("Schematic battery illustration")).font(.caption2).foregroundStyle(.secondary)
                .help(L10n.text("The illustration does not identify this Mac's physical cell layout."))
            KeepAwakeEnergyBadge(service: model.keepAwake)
            if model.isDemo {
                Text(L10n.text("Simulation only — your Mac settings are unchanged."))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }.padding(.vertical, 8)
    }
    private var leftRail: some View {
        VStack(alignment: .leading, spacing: 28) {
            CatalogSummaryMetric(model: model, id: "039", title: "Temperature")
            CatalogSummaryMetric(model: model, id: "035", title: "Battery voltage")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var rightRail: some View {
        VStack(alignment: .leading, spacing: 28) {
            CatalogSummaryMetric(model: model, id: "026", title: "Capacity retention")
            CatalogSummaryMetric(model: model, id: "027", title: "Cycle count")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var illustration: some View {
        EnergyStateIllustration(state: state).scaleEffect(0.85).frame(width: 280, height: 192)
    }
    private var charge: some View {
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(model.chargeText).font(.system(size: 46, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(state.levelIsStale || state.level == nil ? Color.secondary : Color.green)
                    .contentTransition(.numericText())
                if let reading = model.snapshot.catalog.first(where: { $0.id == "011" }) {
                    ReadingInfoButton(reading: reading, fahrenheit: model.fahrenheit)
                }
            }
            Text(model.chargingStateText).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if state.levelIsStale {
                Text(L10n.text("Stale")).font(.callout).foregroundStyle(.orange)
            } else if state.level != nil, model.snapshot.chargePercent.freshness == .unknown {
                Text(L10n.text("Freshness unknown")).font(.callout).foregroundStyle(.secondary)
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
        VStack(spacing: 22) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    adapter.frame(width: 180)
                    connection.frame(minWidth: 24, maxWidth: 90)
                    mac.frame(width: 220)
                }.frame(maxWidth: .infinity)
                VStack(spacing: 18) {
                    adapter
                    connection.frame(width: 70)
                    mac
                }.frame(maxWidth: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                CatalogSummaryMetric(model: model, id: "038", title: "Battery power")
                Text(L10n.text("Separate battery measurement")).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: 280)
            Text(L10n.text("Device illustrations are schematic.")).font(.caption2).foregroundStyle(.secondary)
            if let limitText {
                HStack(spacing: 7) {
                    Image(systemName: "battery.100percent").foregroundStyle(.green).accessibilityHidden(true)
                    Text(L10n.text("macOS charge limit"))
                    Text(limitText).monospacedDigit()
                }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    .help(L10n.text("macOS manages this setting independently of Tilvero."))
            }
        }.padding(.vertical, 12)
    }
    private var limitText: String? {
        if let setting = model.nativeCharge.nativeSetting, setting.isFresh {
            return setting.configuration.enabled ? "\(setting.configuration.target)%" : L10n.text("System managed")
        }
        if let observation = model.systemChargeLimit, observation.isFresh(), let limits = observation.limits,
           !limits.manualLimitIsConflicting, let limit = limits.manualLimit { return "\(limit)%" }
        return nil
    }
    private var adapter: some View {
        VStack(alignment: .leading, spacing: 12) {
            CatalogSummaryMetric(model: model, id: "054", title: "Adapter input")
            artwork(EnergyArtwork.adapter, symbol: "powerplug", width: 170, dimmed: state.sourceConnected != true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var mac: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text(state.sourceConnected == true ? "Power adapter" : state.sourceConnected == false ? "On battery" : "Power source unavailable"))
                    .font(.title3.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(L10n.text("Reported power source")).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reading = model.snapshot.catalog.first(where: { $0.id == "015" }) {
                        ReadingInfoButton(reading: reading, fahrenheit: model.fahrenheit)
                    }
                }
                if let reading = model.snapshot.catalog.first(where: { $0.id == "015" }) {
                    ForEach(CatalogDataPresentation.qualifications(reading), id: \.self) { qualification in
                        Text(qualification).font(.callout)
                            .foregroundStyle(reading.freshness == .stale ? Color.orange : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if model.snapshot.isExternalPower.freshness != .fresh {
                    Text(L10n.text(model.snapshot.isExternalPower.freshness == .stale ? "Stale" : "Freshness unknown"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            artwork(EnergyArtwork.overviewMac ?? EnergyArtwork.mac, symbol: "laptopcomputer", width: 220)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var connection: some View {
        HStack(spacing: 6) {
            Rectangle().fill(.secondary.opacity(state.sourceConnected == true ? 0.5 : 0.2)).frame(height: 1)
            Image(systemName: state.sourceConnected == true ? "link" : state.sourceConnected == nil ? "questionmark" : "minus")
                .font(.caption).foregroundStyle(.secondary)
            Rectangle().fill(.secondary.opacity(state.sourceConnected == true ? 0.5 : 0.2)).frame(height: 1)
        }.accessibilityHidden(true)
    }
    private func artwork(_ image: NSImage?, symbol: String, width: CGFloat, dimmed: Bool = false) -> some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(width: width, height: 140)
            } else {
                Image(systemName: symbol).font(.system(size: 54, weight: .ultraLight)).foregroundStyle(.secondary)
                    .frame(width: width, height: 140)
            }
        }.opacity(dimmed ? 0.38 : 1).accessibilityHidden(true)
    }
}
