import AppKit
import SwiftUI
import Charts
import PowerCore
import PowerPersistence

enum InfoSection: String, CaseIterable, Identifiable {
    case overview, battery, charging, cooling, history, sleep, activity, diagnostics, settings
    var id: String { rawValue }
    var title: String { L10n.text(key) }
    private var key: String {
        switch self {
        case .overview: "Overview"
        case .battery: "Battery"
        case .charging: "Charging & adapter"
        case .cooling: "Cooling"
        case .history: "History"
        case .sleep: "Sleep & drain"
        case .activity: "Application activity"
        case .diagnostics: "Diagnostics"
        case .settings: "Settings"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: "Your Mac at a glance."
        case .battery: "Charge, condition and the readings behind them."
        case .charging: "Power sources, measured input and charging policy."
        case .cooling: "Thermal observations and system cooling."
        case .history: "Your recorded energy timeline."
        case .sleep: "Before sleep, after wake and what was observed."
        case .activity: "Accessible CPU activity, with its measurement limits."
        case .diagnostics: "Sources, control ownership and local diagnostics."
        case .settings: "Make Tilvero work the way you do."
        }
    }
    var symbol: String {
        switch self {
        case .overview: "house"
        case .battery: "battery.100percent"
        case .charging: "powerplug"
        case .cooling: "fan"
        case .history: "chart.xyaxis.line"
        case .sleep: "moon.zzz"
        case .activity: "square.stack.3d.up"
        case .diagnostics: "checkmark.shield"
        case .settings: "gearshape"
        }
    }
}

@MainActor
struct BatteryInfoView: View {
    @ObservedObject var model: TilveroModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var search = ""
    @State private var showUnavailable = true
    @State private var reveal = false
    @State private var measurementsExpanded = false
    private var query: String { CatalogDataGroup.normalizedSearch(search) }
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 190)
            ZStack(alignment: .topLeading) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.selectedSection.title).font(.system(size: 24, weight: .semibold))
                        Spacer(minLength: 8)
                        Button { Task { await model.refresh(); if model.selectedSection == .sleep { await model.refreshSleepActivity() } } } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel(L10n.text("Refresh"))
                    }
                    if model.isDemo {
                        Label(L10n.text("Simulation only — your Mac settings are unchanged."), systemImage: "testtube.2")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if model.keepAwake.hasOwnedAssertion { KeepAwakeActivePanel(service: model.keepAwake) }
                    if !model.isDemo && (model.nativeCharge.hasOwnedSettings || model.nativeCharge.pendingTarget != nil || model.nativeCharge.recoveryRequired || model.nativeCharge.restorationPending) {
                        ProductSurface(title: "Charging state") {
                            Text(model.usesNativeCharge ? model.effectiveLimitText : L10n.text("App-owned settings require restoration"))
                                .foregroundStyle(model.nativeCharge.recoveryRequired || model.nativeCharge.restorationPending ? Color.orange : Color.primary)
                            NativeChargeStatusPanel(model: model)
                            if model.nativeCharge.pendingTarget != nil {
                                Button(L10n.text("Cancel pending target")) { model.cancelPendingDemo() }
                                    .disabled(model.isApplying || model.nativeCharge.isBusy)
                            }
                            if model.nativeCharge.hasOwnedSettings && !model.nativeCharge.recoveryRequired && !model.nativeCharge.restorationPending {
                                Button(L10n.text("Return to system control")) { model.releaseControl() }
                                    .disabled(!model.canReleaseCharge)
                            }
                        }
                    }
                    if model.liveControl.hasOwnedSettings || model.liveControl.recoveryRequired || (!model.usesNativeCharge && model.pendingTarget != nil) {
                        ProductSurface(title: "Privileged controls") {
                            if !model.usesNativeCharge { Text(model.effectiveLimitText) }
                            if model.liveControl.recoveryRequired {
                                Label(L10n.text("App-owned settings require restoration"), systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                            if let message = model.liveControl.message { Text(L10n.text(message)).font(.system(size: 12)) }
                            Button(L10n.text("Restore original settings")) { model.restoreAll() }
                        }
                    }
                    sectionContent
                    if let error = model.storeError { Label(L10n.text("Data store error") + ": " + error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    if model.selectedSection != .overview {
                        Text("\(L10n.text("Last collection")): \(model.snapshot.collectedAt.formatted(.dateTime.locale(L10n.locale)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 24).padding(.top, 25).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .topLeading)
            }.background(Color.white)
                .id(model.selectedSection).transition(.opacity)
            }.animation(ProductMotion.animation(reduceMotion: reduceMotion), value: model.selectedSection)
        }.frame(minWidth: 760, minHeight: 540)
            .background(Color.white).foregroundStyle(Color.black.opacity(0.9))
            .font(.system(size: 13))
            .tint(.green)
            .accentColor(.green)
            .environment(\.colorScheme, .light)
            .environment(\.locale, L10n.locale)
            .id(model.language)
            .sheet(isPresented: Binding(get: { model.exportPreview != nil }, set: { if !$0 { model.exportPreview = nil } })) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.text("Export preview")).font(.title2)
                    Text(L10n.text("Serials and private identifiers are excluded.")).foregroundStyle(.secondary)
                    ScrollView { Text(model.exportPreview ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack { Button(L10n.text("Cancel")) { model.exportPreview = nil }; Spacer(); Button(L10n.text("Save…")) { model.saveExport() }.buttonStyle(.borderedProminent) }
                }.padding(24).frame(width: 620, height: 470)
            }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text(AppIdentity.displayName).font(.system(size: 18, weight: .semibold))
                TilveroEnergyMark().stroke(Color.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 27, height: 15).accessibilityHidden(true)
            }.padding(.horizontal, 14).padding(.top, 27).padding(.bottom, 22)
            ForEach(InfoSection.allCases) { item in
                if item == .history {
                    Text(L10n.text("Analytics")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.top, 20).padding(.bottom, 7)
                }
                if item == .diagnostics { Color.clear.frame(height: 15) }
                sidebarItem(item)
            }
            Spacer(minLength: 16)
            if model.isDemo {
                Label(L10n.text("Simulation"), systemImage: "testtube.2")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(14)
            }
        }.frame(maxHeight: .infinity).background(Color(red: 0.95, green: 0.95, blue: 0.95))
    }
    private func sidebarItem(_ item: InfoSection) -> some View {
        let selected = model.selectedSection == item
        return Button { model.selectedSection = item } label: {
            HStack(spacing: 9) {
                Image(systemName: item.symbol).font(.system(size: 14)).frame(width: 18).accessibilityHidden(true)
                Text(item.title).font(.system(size: 12)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(selected ? 0.065 : 0), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityLabel(item.title)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityRemoveTraits(selected ? [] : [.isSelected])
            .padding(.horizontal, 7).padding(.vertical, 1)
    }
    private var measurementSearch: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(L10n.text("Search measurements"), text: $search).textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel(L10n.text("Clear search"))
            }
        }.padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.08)))
    }
    private var measurementOptions: some View {
        HStack(spacing: 16) {
            Toggle(L10n.text("Show unavailable fields"), isOn: $showUnavailable).toggleStyle(.checkbox)
            if [.battery, .charging, .diagnostics].contains(model.selectedSection) {
                Toggle(L10n.text("Reveal identifiers"), isOn: $reveal).toggleStyle(.checkbox)
            }
        }
    }
    @ViewBuilder private var sectionContent: some View {
        switch model.selectedSection {
        case .overview:
            OverviewDashboard(model: model)
            if model.isDemo { SimulationPanel(model: model) }
        case .activity:
            ProcessActivityPanel(model: model)
        case .battery:
            BatteryDataPanel(model: model, showUnavailable: showUnavailable, reveal: reveal, options: AnyView(measurementOptions))
        case .charging:
            PowerDataPanel(model: model, showUnavailable: showUnavailable, reveal: reveal, options: AnyView(measurementOptions))
        case .cooling:
            CoolingPanel(model: model, showUnavailable: showUnavailable)
            if !model.fanless {
                if model.isDemo || !model.fanDescriptors.isEmpty { FanControlPanel(model: model) }
                DataReadingSection(title: "Fan observations", readings: CatalogDataGroup.filtered(readings(["087", "088", "089", "090", "091", "092", "093"]), search: "", showUnavailable: showUnavailable), fahrenheit: model.fahrenheit)
            }
        case .history: HistoryPanel(model: model)
        case .sleep: SleepReportPanel(model: model)
        case .diagnostics:
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 29)).foregroundStyle(.green).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Local diagnostics")).font(.system(size: 16, weight: .semibold))
                    Text(L10n.text("Monitoring works without a privileged helper. Control ownership and restoration are shown separately."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if !model.isDemo {
                ProductSurface(title: "Native charging", symbol: "battery.100percent") {
                    Label(L10n.text(model.nativeCharge.hasOwnedSettings || model.nativeCharge.recoveryRequired ? "App-owned settings require restoration" : "No active native session"), systemImage: model.nativeCharge.hasOwnedSettings || model.nativeCharge.recoveryRequired ? "exclamationmark.circle" : "checkmark.circle")
                    NativeChargeStatusPanel(model: model)
                    Divider()
                    SystemChargeLimitPanel(model: model)
                    Button(L10n.text("Refresh")) { Task { await model.refreshNativeCharge(); await model.refreshSystemChargeLimit() } }
                }
            }
            ProductSurface(title: "Privileged controls", symbol: "shield") {
                Label(L10n.text(model.liveControl.hasOwnedSettings ? "App-owned settings require restoration" : "No active helper session"), systemImage: "shield")
                Text("\(L10n.text("Helper")): \(model.helperStatusText)")
                Text(L10n.text(model.liveControl.message ?? "Signing and hardware validation required")).font(.callout).foregroundStyle(.secondary)
                if model.liveControl.canRegister { Button(L10n.text("Enable supported controls")) { model.registerHelper() } }
                if model.liveControl.hasOwnedSettings || model.liveControl.recoveryRequired { Button(L10n.text("Restore original settings")) { model.restoreAll() } }
                if model.liveControl.registrationState == .enabled { Button(L10n.text("Disable helper after restoration")) { model.removeHelper() } }
            }
            ProductSurface(title: "Diagnostics", symbol: "doc.text.magnifyingglass") {
                Text(L10n.text("Running copy") + ": " + Bundle.main.bundleURL.path)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                ViewThatFits(in: .horizontal) {
                    HStack { diagnosticExport; diagnosticInventory }
                    VStack(alignment: .leading, spacing: 10) { diagnosticExport; diagnosticInventory }
                }
                Text(L10n.text("Serials and private identifiers are excluded.")).font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(isExpanded: $measurementsExpanded) {
                VStack(alignment: .leading, spacing: 18) {
                    measurementSearch
                    measurementOptions
                    if !query.isEmpty { catalogRows(model.snapshot.catalog) }
                    else {
                        ForEach(CatalogDataGroup.allData(model.snapshot.catalog)) { group in
                            DataReadingSection(title: group.title, readings: CatalogDataGroup.filtered(group.readings, search: "", showUnavailable: showUnavailable), reveal: reveal, fahrenheit: model.fahrenheit)
                        }
                    }
                }.padding(.top, 12)
            } label: {
                Text(L10n.text("Measurements & sources")).font(.system(size: 13, weight: .semibold))
            }.padding(.vertical, 5)
                .animation(ProductMotion.animation(reduceMotion: reduceMotion), value: measurementsExpanded)
        case .settings: SettingsPanel(model: model)
        }
    }
    private var diagnosticExport: some View { Button(L10n.text("Export diagnostics…")) { model.prepareExport(diagnostics: true) } }
    private var diagnosticInventory: some View { Button(L10n.text("Read property inventory")) { model.inspectRawProperties() } }
    private func readings(_ ids: [String]) -> [CatalogReading] { model.snapshot.catalog.filter { ids.contains($0.id) } }
    @ViewBuilder private func catalogRows(_ rows: [CatalogReading]) -> some View {
        let visible = CatalogDataGroup.filtered(rows, search: search, showUnavailable: showUnavailable)
        if visible.isEmpty {
            Text(L10n.text("No matching measurements")).foregroundStyle(.secondary)
        } else {
            CatalogReadingTable(readings: visible, reveal: reveal, fahrenheit: model.fahrenheit)
        }
    }
}

@MainActor
private struct HistoryPanel: View {
    @ObservedObject var model: TilveroModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var days = 1
    @State private var metric = "Charge"
    private var points: [HistorySample] { model.history.filter { $0.collectedAt >= Date().addingTimeInterval(-Double(days) * 86400) } }
    private func value(_ sample: HistorySample) -> Double? {
        switch metric { case "Temperature": sample.temperatureCelsius; case "Power": sample.batteryPowerWatts; default: sample.chargePercent }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if model.isDemo {
                ProductIntro(title: "Recorded history", subtitle: "Simulation data is never stored in live history.", symbol: "chart.xyaxis.line")
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    ViewThatFits(in: .horizontal) {
                        HStack { period; Spacer(); metricPicker }
                        VStack(alignment: .leading, spacing: 12) { period; metricPicker }
                    }
                    if points.contains(where: { value($0) != nil }) {
                        Chart(HistoryChart.points(points.map { ChartObservation(id: $0.id, date: $0.collectedAt, value: value($0), continuityID: $0.segmentID.uuidString) })) { point in
                            LineMark(x: .value("Time", point.date), y: .value(metric, point.value), series: .value("Segment", point.series))
                                .foregroundStyle(Color.accentColor).interpolationMethod(.linear)
                            PointMark(x: .value("Time", point.date), y: .value(metric, point.value)).symbolSize(8).foregroundStyle(Color.accentColor)
                        }.frame(height: 190).chartYAxisLabel(metric == "Charge" ? "%" : metric == "Temperature" ? "°C" : "W")
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(L10n.text("Recorded samples")): \(points.count)")
                            Spacer()
                            Text(points.first?.collectedAt.formatted(.dateTime.locale(L10n.locale)) ?? "")
                        }.font(.caption).foregroundStyle(.secondary)
                    } else {
                        ContentUnavailableView(L10n.text("No recorded measurements yet"), systemImage: "chart.xyaxis.line")
                    }
                    Text(L10n.text("History starts with observations made by Tilvero. Sleep and missing readings remain gaps."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !model.historyEnabled { Label(L10n.text("Recording is off"), systemImage: "pause.circle").font(.callout).foregroundStyle(.secondary) }
                }
                if let summary = model.historySummary {
                    VStack(alignment: .leading, spacing: 18) {
                        ProductSectionHeading(title: "All recorded history")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 18) {
                            ProductMetric(title: "Charging sessions", value: String(summary.chargingSessionCount))
                            ProductMetric(title: "Recorded gaps", value: String(summary.gaps.count))
                            if let charged = summary.estimatedChargedWh, let discharged = summary.estimatedDischargedWh {
                                ProductMetric(title: "Estimated energy", value: "≈ +\(charged.formatted(.number.precision(.fractionLength(2)))) / −\(discharged.formatted(.number.precision(.fractionLength(2))))", detail: CatalogDataPresentation.unit("Wh"))
                            }
                        }
                        if let since = summary.monitoringStart { Text("\(L10n.text("Monitoring since")): \(since.formatted(.dateTime.locale(L10n.locale)))").font(.caption).foregroundStyle(.secondary) }
                        if !summary.sessions.isEmpty {
                            Divider()
                            ProductSectionHeading(title: "Observed sessions")
                            ForEach(Array(summary.sessions.suffix(5))) { session in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(session.observedFrom.formatted(.dateTime.locale(L10n.locale)))
                                    Spacer()
                                    Text(session.endedAt.map { $0.formatted(.dateTime.locale(L10n.locale)) } ?? L10n.text("Current")).foregroundStyle(.secondary)
                                }.font(.system(size: 12)).monospacedDigit().textSelection(.enabled)
                                .padding(.vertical, 8)
                                Divider()
                            }
                        }
                    }
                }
                HStack {
                    Button(L10n.text("Export JSON…")) { model.prepareExport() }
                    Button(L10n.text("Export CSV…")) { model.prepareExport(csv: true) }
                }
            }
        }
        .animation(ProductMotion.animation(reduceMotion: reduceMotion), value: days)
        .animation(ProductMotion.animation(reduceMotion: reduceMotion), value: metric)
    }
    private var period: some View {
        Picker(L10n.text("Period"), selection: $days) {
            Text(L10n.text("24 hours")).tag(1); Text(L10n.text("7 days view")).tag(7)
        }.pickerStyle(.segmented).labelsHidden().frame(width: 208)
    }
    private var metricPicker: some View {
        Picker(L10n.text("Measurement"), selection: $metric) {
            ForEach(["Charge", "Temperature", "Power"], id: \.self) { Text(L10n.text($0)).tag($0) }
        }.frame(maxWidth: 230)
    }

}

@MainActor
private struct SettingsPanel: View {
    @ObservedObject var model: TilveroModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmErase = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker(L10n.text("Settings section"), selection: $model.selectedSettingsPage) {
                ForEach(SettingsPage.allCases) { Text(L10n.text($0.title)).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().id(L10n.language)
            Group {
                switch model.selectedSettingsPage {
                case .general: general
                case .quickPanel: QuickPanelBuilder(model: model)
                case .history: historySettings
                }
            }.id(model.selectedSettingsPage).transition(.opacity)
                .animation(ProductMotion.animation(reduceMotion: reduceMotion), value: model.selectedSettingsPage)
        }.alert(L10n.text("Erase history"), isPresented: $confirmErase) {
            Button(L10n.text("Cancel"), role: .cancel) {}
            Button(L10n.text("Erase history"), role: .destructive) { model.eraseHistory() }
        } message: { Text(L10n.text("Delete local measurements? This does not change charging or cooling settings.")) }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 20) {
            ProductSurface(title: "Menu bar") {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.text("Menu bar"))
                    Spacer()
                    Picker(L10n.text("Menu bar"), selection: $model.displayStyle) { ForEach(MenuBarDisplayStyle.allCases) { Text($0.title).tag($0) } }
                        .labelsHidden().frame(width: 220)
                }
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.text("Percentage size"))
                    Spacer()
                    Picker(L10n.text("Percentage size"), selection: $model.menuBarTextSize) {
                        ForEach(MenuBarTextSize.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 220).disabled(model.displayStyle == .iconOnly)
                }
                HStack {
                    Text(L10n.text("Icon scale"))
                    Slider(value: Binding(get: { model.menuBarIconScale }, set: model.setMenuBarIconScale), in: 0.85...1.15, step: 0.05)
                        .frame(minWidth: 80, maxWidth: 220).accessibilityLabel(L10n.text("Icon scale"))
                    Text("\(Int((model.menuBarIconScale * 100).rounded()))%").monospacedDigit().frame(width: 42, alignment: .trailing)
                }
                Button(L10n.text("Reset size")) { model.resetMenuBarSizing() }
            }
            ProductSurface(title: "App preferences") {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.text("Language"))
                    Spacer()
                    Picker(L10n.text("Language"), selection: $model.language) { Text(L10n.text("System language")).tag("system"); Text("Русский").tag("ru"); Text("English").tag("en") }
                        .labelsHidden().frame(width: 220)
                }
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.text("Temperature units"))
                    Spacer()
                    Picker(L10n.text("Temperature units"), selection: $model.fahrenheit) { Text("°C").tag(false); Text("°F").tag(true) }
                        .labelsHidden().frame(width: 220)
                }
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.text("Launch at login"))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(L10n.text(model.loginStatus)).font(.caption).foregroundStyle(.secondary)
                        Button(L10n.text(model.loginStatus == "Enabled" ? "Disable" : "Enable")) { model.toggleLogin() }
                            .disabled(model.isDemo || model.loginStatus == "Not available from this local build")
                    }
                }
            }
            KeyboardBacklightPanel(service: model.keyboardBacklight)
            ProductSurface { KeepAwakePanel(model: model) }
            Button(L10n.text("Customize quick panel…")) { model.selectedSettingsPage = .quickPanel }
        }.frame(maxWidth: 760, alignment: .leading)
    }
    private var historySettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            ProductSurface(title: "History") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(L10n.text("Save history"), isOn: $model.historyEnabled).disabled(model.isDemo)
                    Picker(L10n.text("Detailed samples"), selection: $model.retentionDays) { ForEach([7,14,30], id: \.self) { Text(L10n.text("\($0) days")).tag($0) } }.frame(maxWidth: 350).disabled(model.isDemo)
                    Text(L10n.text("Minute samples use the selected period. Hourly aggregates are kept for 12 months.")).font(.caption).foregroundStyle(.secondary)
                    Text(L10n.text("Sleep reports use the selected detailed-history period.")).font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Button(L10n.text("Erase history…"), role: .destructive) { confirmErase = true }.disabled(model.isDemo)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            ProductSurface(title: "Recovery & uninstall", symbol: "arrow.counterclockwise") {
                Text(L10n.text("Release control before removing Tilvero. Use Native charging and Privileged controls in Diagnostics to check restoration. Quit the app normally, then move its bundle to Trash. History can be erased separately.")).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(L10n.text("Local and offline. No account or uploads.")).font(.caption).foregroundStyle(.secondary)
        }
    }

}

@MainActor
struct ProfilePanel: View {
    @ObservedObject var model: TilveroModel
    var body: some View {
        GroupBox(L10n.text("Profiles & schedules")) {
            VStack(alignment: .leading, spacing: 14) {
                ModeEditorPanel(model: model)
                Divider()
                Picker(L10n.text("Scheduled profile"), selection: $model.scheduleProfileName) {
                    ForEach(["At desk", "On battery profile", "Before leaving", "Sustained work"], id: \.self) { Text(L10n.text($0)).tag($0) }
                }
                DatePicker(L10n.text("Scheduled preparation"), selection: $model.scheduleDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                Text(L10n.text("A schedule does not wake the Mac. Missed actions are skipped; a newer manual action takes precedence.")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L10n.text("Save schedule")) { model.saveSchedule() }
                    if let schedule = model.schedule {
                        Text("\(L10n.text("Scheduled")): \(schedule.fireDate.formatted())").font(.caption)
                        Button(L10n.text("Remove schedule")) { model.removeSchedule() }
                    }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
private struct SimulationPanel: View {
    @ObservedObject var model: TilveroModel
    var body: some View {
        GroupBox(L10n.text("Simulation controls")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text(L10n.text("Battery level")); Slider(value: $model.demoPercent, in: 0...100, step: 1); Text("\(Int(model.demoPercent))%") }
                Toggle(L10n.text("Adapter connected"), isOn: $model.demoExternal)
                Toggle(L10n.text("System charging override"), isOn: $model.demoOverride)
                Button(L10n.text("Refresh")) { Task { await model.refresh() } }
            }.padding(12)
        }
    }
}

@MainActor
private struct FanControlPanel: View {
    @ObservedObject var model: TilveroModel
    @State private var rpm = 2400.0
    private var minimum: Double { Double(model.fanDescriptors.map(\.minimumRPM).max() ?? 1200) }
    private var maximum: Double { max(minimum + 1, Double(model.fanDescriptors.map(\.maximumRPM).min() ?? 6000)) }
    var body: some View {
        GroupBox(L10n.text(model.isDemo ? "Simulation controls" : "Cooling")) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text(model.isDemo ? "Simulation only — your Mac settings are unchanged." : "Fan control is not verified on this hardware.")).foregroundStyle(.secondary)
                if !model.fanDescriptors.isEmpty {
                    ForEach(model.fanDescriptors, id: \.id) { fan in
                        HStack { Text("Fan \(fan.id)"); Spacer(); Text("\(L10n.text("Observed RPM")): \(model.fanRPM[fan.id].map(String.init) ?? "—")") }
                    }
                    Text(model.fanPhase == .systemAuto ? L10n.text("System Auto") : model.fanPhase.rawValue)
                }
                Slider(value: $rpm, in: minimum...maximum, step: 1).accessibilityLabel(L10n.text("Manual RPM"))
                HStack {
                    Text("\(Int(rpm)) RPM").monospacedDigit()
                    Button(L10n.text("Manual RPM")) { model.setFanPolicy(.manual(Dictionary(uniqueKeysWithValues: model.fanDescriptors.map { ($0.id, Int(rpm)) }))) }
                    Button(L10n.text("Timed boost")) { model.setFanPolicy(.boost(rpm: Int(rpm), seconds: 60)) }
                    Button(L10n.text("System Auto")) { model.setFanPolicy(.systemAuto) }
                }.disabled(model.isApplying || !model.canControlFans)
                HStack {
                    Button(L10n.text("Temperature curve")) {
                        if let curve = try? FanCurve(points: [.init(celsius: 35, rpm: Int(minimum)), .init(celsius: 65, rpm: Int((minimum + maximum) / 2)), .init(celsius: 90, rpm: Int(maximum))]) { model.setFanPolicy(.curve(curve)) }
                    }.disabled(!model.canControlFans || (!model.isDemo && model.fanObservation?.sensorFresh != true))
                    if model.isDemo { Button(L10n.text("Advance 60 seconds")) { model.advanceSimulation() } }
                }
            }.padding(12)
        }
    }
}
