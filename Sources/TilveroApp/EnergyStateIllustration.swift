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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) { illustration; information.frame(width: 230, alignment: .leading) }
            VStack(alignment: .leading, spacing: 10) { illustration.frame(maxWidth: .infinity); information }
        }.padding(.vertical, 8)
    }
    private var illustration: some View {
        VStack(alignment: .leading, spacing: 5) {
            EnergyStateIllustration(state: state).scaleEffect(0.85).frame(width: 280, height: 200)
            Text(L10n.text("Schematic battery illustration")).font(.caption2).foregroundStyle(.secondary)
                .help(L10n.text("The illustration does not identify this Mac's physical cell layout."))
        }
    }
    private var information: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.chargeText).font(.system(size: 44, weight: .medium, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
            if let level = state.level {
                ProgressView(value: Double(level), total: 100)
                    .tint(state.levelIsStale ? Color.secondary : Color.accentColor)
                    .frame(maxWidth: 240)
                    .accessibilityLabel(L10n.text("Charge level"))
                    .accessibilityValue(model.chargeText)
            }
            Text(model.chargingStateText).font(.subheadline).foregroundStyle(.secondary)
            if state.levelIsStale { Label(L10n.text("Stale"), systemImage: "clock").font(.caption).foregroundStyle(.orange) }
            Text(L10n.text("Source") + ": " + model.snapshot.chargePercent.source)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            KeepAwakeEnergyBadge(service: model.keepAwake)
            if model.isDemo { Text(L10n.text("Simulation only — your Mac settings are unchanged.")).font(.caption).foregroundStyle(.secondary) }
        }.fixedSize(horizontal: false, vertical: true)
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
    private func reading(_ id: String) -> PowerHeadlineReading {
        .init(model.snapshot.catalog.first(where: { $0.id == id }))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 18) {
                VStack(spacing: 8) {
                    node(symbol: state.sourceConnected == nil ? "powerplug.portrait" : "powerplug", artwork: EnergyArtwork.adapter,
                         dimmed: state.sourceConnected != true, title: "Adapter input", value: state.sourceConnected == false ? "—" : reading("054").value)
                    qualification(reading("054"))
                }.frame(maxWidth: .infinity)
                connection.frame(minWidth: 40, maxWidth: 140)
                VStack(spacing: 8) {
                    node(symbol: "laptopcomputer", artwork: EnergyArtwork.mac, title: "Mac", value: L10n.text(state.sourceConnected == true ? "Power adapter" : state.sourceConnected == false ? "On battery" : "Power source unavailable"))
                    Text(L10n.text("Reported power source")).font(.caption).foregroundStyle(.secondary)
                    if model.snapshot.isExternalPower.freshness == .unknown {
                        Text(L10n.text("Freshness unknown")).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity)
            }.frame(maxWidth: .infinity).padding(.vertical, 12)
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Label {
                    Text(L10n.text("Battery power"))
                } icon: {
                    Image(systemName: "battery.100percent").foregroundStyle(.green)
                }
                Spacer()
                Text(reading("038").value).monospacedDigit()
            }.font(.subheadline)
            qualification(reading("038"))
            Text(L10n.text("Separate battery measurement")).font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("Device illustrations are schematic.")).font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
    }
    private func qualification(_ reading: PowerHeadlineReading) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let key = reading.qualificationKey {
                Text(L10n.text(key)).foregroundStyle(key == "Stale" ? Color.orange : Color.secondary)
            }
            if let source = reading.source { Text(L10n.text("Source") + ": " + source).foregroundStyle(.secondary) }
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
    }
    private var connection: some View {
        HStack(spacing: 6) {
            Rectangle().fill(.secondary.opacity(state.sourceConnected == true ? 0.5 : 0.2)).frame(height: 1)
            Image(systemName: state.sourceConnected == true ? "link" : state.sourceConnected == nil ? "questionmark" : "minus")
                .font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            Rectangle().fill(.secondary.opacity(state.sourceConnected == true ? 0.5 : 0.2)).frame(height: 1)
        }.accessibilityHidden(true)
    }
    private func node(symbol: String, artwork: NSImage? = nil, dimmed: Bool = false, title: String, value: String) -> some View {
        VStack(spacing: 9) {
            Group {
                if let artwork {
                    Image(nsImage: artwork).resizable().interpolation(.high).scaledToFit().frame(width: 160, height: 110)
                        .opacity(dimmed ? 0.38 : 1)
                } else {
                    Image(systemName: symbol).font(.system(size: 34, weight: .ultraLight)).foregroundStyle(.secondary).frame(height: 110)
                }
            }.accessibilityHidden(true)
            Text(L10n.text(title)).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit().multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity)
    }
}
