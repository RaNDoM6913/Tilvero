import AppKit
import SwiftUI
import Charts
import PowerCore
import PowerPersistence

enum InfoSection: String, CaseIterable, Identifiable {
    case overview, battery, charging, cooling, history, sleep, diagnostics, settings
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
        case .diagnostics: "Diagnostics"
        case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .battery: "battery.100percent"
        case .charging: "bolt"
        case .cooling: "fan"
        case .history: "chart.xyaxis.line"
        case .sleep: "moon.zzz"
        case .diagnostics: "list.bullet.rectangle"
        case .settings: "gearshape"
        }
    }
}

@MainActor
struct BatteryInfoView: View {
    @ObservedObject var model: TilveroModel
    @State private var search = ""
    @State private var showUnavailable = false
    @State private var reveal = false
    var body: some View {
        NavigationSplitView {
            List(selection: Binding<InfoSection?>(get: { model.selectedSection }, set: { if let selected = $0 { model.selectedSection = selected } })) {
                ForEach([InfoSection.overview, .battery, .charging, .cooling]) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
                Section(L10n.text("Analytics")) {
                    ForEach([InfoSection.history, .sleep]) { item in Label(item.title, systemImage: item.symbol).tag(item) }
                }
                Section {
                    ForEach([InfoSection.diagnostics, .settings]) { item in Label(item.title, systemImage: item.symbol).tag(item) }
                }
            }.navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.selectedSection.title).font(.largeTitle.bold())
                            Text(L10n.text(model.isDemo ? "Simulation only — your Mac settings are unchanged." : "Live readings"))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { Task { await model.refresh(); if model.selectedSection == .sleep { await model.refreshSleepActivity() } } } label: { Label(L10n.text("Refresh"), systemImage: "arrow.clockwise") }
                    }
                    if model.keepAwake.hasOwnedAssertion { KeepAwakeActivePanel(service: model.keepAwake) }
                    if model.selectedSection != .settings && model.selectedSection != .history && model.selectedSection != .sleep {
                        HStack {
                            TextField(L10n.text("Search measurements"), text: $search).textFieldStyle(.roundedBorder)
                            Toggle(L10n.text("Show unavailable fields"), isOn: $showUnavailable).toggleStyle(.checkbox)
                        }
                    }
                    if !search.isEmpty && model.selectedSection != .sleep { catalogRows(model.snapshot.catalog) }
                    else { sectionContent }
                    if let error = model.storeError { Label(L10n.text("Data store error") + ": " + error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    Text("\(L10n.text("Last collection")): \(model.snapshot.collectedAt.formatted(.dateTime.locale(L10n.locale)))")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(minWidth: 760, minHeight: 540)
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
    @ViewBuilder private var sectionContent: some View {
        switch model.selectedSection {
        case .overview:
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(model.chargeText).font(.system(size: 52, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(model.chargingStateText).foregroundStyle(.secondary)
            }
            catalogRows(readings(["023", "024", "027", "026", "039", "067", "069", "044"]))
            Text(L10n.text("Capacity retention is calculated separately from the macOS health assessment.")).font(.callout).foregroundStyle(.secondary)
            if model.isDemo { SimulationPanel(model: model) }
        case .battery:
            Toggle(L10n.text("Reveal identifiers"), isOn: $reveal).toggleStyle(.checkbox)
            catalogRows(model.snapshot.catalog.filter { ("023"..."042").contains($0.id) || ("057"..."071").contains($0.id) })
            Text(L10n.text("Cell manufacturer is not inferred from the reported pack manufacturer.")).font(.callout).foregroundStyle(.secondary)
        case .charging:
            GroupBox { ChargeLimitControl(model: model).padding(12) }
            if model.canShowChargeControls {
                HStack {
                    Button(L10n.text(model.isOneShotDemo ? "Cancel one-time charge" : "Charge to 100% once")) { model.toggleOneShotDemo() }.disabled(!model.canChargeToFullOnce)
                    Button(L10n.text("Return to system control")) { model.releaseControl() }.disabled(!model.canReleaseCharge)
                }.disabled(model.isApplying)
            }
            catalogRows(model.snapshot.catalog.filter { ("013"..."022").contains($0.id) || ("045"..."056").contains($0.id) })
            Label(L10n.text("Power mode") + ": " + L10n.text(ProcessInfo.processInfo.isLowPowerModeEnabled ? "Low Power" : "Automatic"), systemImage: "bolt.circle")
            ProfilePanel(model: model)
        case .cooling:
            if model.fanless {
                Label(L10n.text("Fanless cooling"), systemImage: "leaf").font(.title2)
                Text(L10n.text("This MacBook Air has no fans. macOS manages cooling automatically.")).foregroundStyle(.secondary)
            } else if model.isDemo || !model.fanDescriptors.isEmpty { FanControlPanel(model: model) }
            else { Text(L10n.text("Fan control is not verified on this hardware.")).foregroundStyle(.secondary) }
            catalogRows(readings(["039", "040", "044", "087", "088", "089", "090", "091", "092", "093", "094"]))
        case .history: HistoryPanel(model: model)
        case .sleep: SleepReportPanel(model: model)
        case .diagnostics:
            if !model.isDemo {
                GroupBox(L10n.text("Native charging")) {
                    VStack(alignment: .leading, spacing: 9) {
                        Label(L10n.text(model.nativeCharge.hasOwnedSettings || model.nativeCharge.recoveryRequired ? "App-owned settings require restoration" : "No active native session"), systemImage: "battery.100percent")
                        NativeChargeStatusPanel(model: model)
                        SystemChargeLimitPanel(model: model)
                        Button(L10n.text("Refresh")) { Task { await model.refreshNativeCharge(); await model.refreshSystemChargeLimit() } }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
            }
            GroupBox(L10n.text("Privileged controls")) {
                VStack(alignment: .leading, spacing: 9) {
                    Label(L10n.text(model.liveControl.hasOwnedSettings ? "App-owned settings require restoration" : "No active helper session"), systemImage: "shield")
                    Text("\(L10n.text("Helper")): \(model.helperStatusText)")
                    Text(L10n.text(model.liveControl.message ?? "Signing and hardware validation required")).foregroundStyle(.secondary)
                    if model.liveControl.canRegister { Button(L10n.text("Enable supported controls")) { model.registerHelper() } }
                    if model.liveControl.hasOwnedSettings || model.liveControl.recoveryRequired { Button(L10n.text("Restore original settings")) { model.restoreAll() } }
                    if model.liveControl.registrationState == .enabled { Button(L10n.text("Disable helper after restoration")) { model.removeHelper() } }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            GroupBox(L10n.text("Diagnostics")) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(L10n.text("Running copy") + ": " + Bundle.main.bundleURL.path)
                        .font(.caption).textSelection(.enabled)
                    Button(L10n.text("Export diagnostics…")) { model.prepareExport(diagnostics: true) }
                    Button(L10n.text("Read property inventory")) { model.inspectRawProperties() }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            Toggle(L10n.text("Reveal identifiers"), isOn: $reveal).toggleStyle(.checkbox)
            catalogRows(model.snapshot.catalog)
        case .settings: SettingsPanel(model: model)
        }
    }
    private func readings(_ ids: [String]) -> [CatalogReading] { model.snapshot.catalog.filter { ids.contains($0.id) } }
    private func filtered(_ rows: [CatalogReading]) -> [CatalogReading] {
        rows.filter { reading in
            let matches = search.isEmpty || "\(reading.titleEnglish) \(reading.titleRussian) \(reading.id)".localizedCaseInsensitiveContains(search)
            return matches && (showUnavailable || !search.isEmpty || reading.value != nil)
        }
    }
    @ViewBuilder private func catalogRows(_ rows: [CatalogReading]) -> some View {
        let visible = filtered(rows)
        if visible.isEmpty {
            Text(L10n.text("No matching measurements")).foregroundStyle(.secondary)
        } else {
            GroupBox {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { reading in
                        CatalogMetricRow(reading: reading, reveal: reveal, fahrenheit: model.fahrenheit)
                        if reading.id != visible.last?.id { Divider() }
                    }
                }.padding(8)
            }
        }
    }
}

@MainActor
private struct CatalogMetricRow: View {
    let reading: CatalogReading
    let reveal: Bool
    let fahrenheit: Bool
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(L10n.text("Source")): \(reading.source) \(reading.keyPath)")
                Text("\(L10n.text("Availability")): \(reading.availability.rawValue) · \(L10n.text("Freshness")): \(reading.freshness.rawValue)")
                Text("\(L10n.text("Provenance")): \(reading.provenance.rawValue)")
                Text("\(L10n.text("Collected")): \(reading.collectedAt.formatted())")
                Text("\(L10n.text("Source sample")): \(reading.sourceSampleAt.map { $0.formatted() } ?? L10n.text("No source timestamp"))")
                if let reason = reading.reason { Text(reason) }
                if let raw = reading.rawValue, reading.privacy != .sensitive || reveal { Text("\(L10n.text("Raw value")): \(raw.displayText)") }
            }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.language == "ru" ? reading.titleRussian : reading.titleEnglish)
                Spacer(minLength: 16)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(ReadingPresentation.display(reading, reveal: reveal, fahrenheit: fahrenheit)).monospacedDigit().textSelection(.enabled)
                        .foregroundStyle(reading.value == nil ? Color.secondary : Color.primary)
                    if reading.freshness == .stale { Text(L10n.text("Stale")).font(.caption2).foregroundStyle(.orange) }
                }
            }.padding(.vertical, 8)
        }.help(L10n.text("Source details"))
    }
}

@MainActor
private struct HistoryPanel: View {
    @ObservedObject var model: TilveroModel
    @State private var days = 1
    @State private var metric = "Charge"
    private var points: [HistorySample] { model.history.filter { $0.collectedAt >= Date().addingTimeInterval(-Double(days) * 86400) } }
    private func value(_ sample: HistorySample) -> Double? {
        switch metric { case "Temperature": sample.temperatureCelsius; case "Power": sample.batteryPowerWatts; default: sample.chargePercent }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("History starts with observations made by Tilvero. Sleep and missing readings remain gaps.")).foregroundStyle(.secondary)
            if model.isDemo { Text(L10n.text("Simulation data is never stored in live history.")) }
            else {
                HStack {
                    Picker("", selection: $days) { Text(L10n.text("24 hours")).tag(1); Text(L10n.text("7 days view")).tag(7) }.pickerStyle(.segmented).frame(width: 220)
                    Spacer()
                    Picker("", selection: $metric) { ForEach(["Charge", "Temperature", "Power"], id: \.self) { Text(L10n.text($0)).tag($0) } }.frame(width: 180)
                }
                if points.contains(where: { value($0) != nil }) {
                    Chart(HistoryChart.points(points.map { ChartObservation(id: $0.id, date: $0.collectedAt, value: value($0), continuityID: $0.segmentID.uuidString) })) { point in
                            LineMark(x: .value("Time", point.date), y: .value(metric, point.value), series: .value("Segment", point.series))
                                .foregroundStyle(Color.accentColor).interpolationMethod(.linear)
                            PointMark(x: .value("Time", point.date), y: .value(metric, point.value)).symbolSize(12).foregroundStyle(Color.accentColor)
                    }.frame(height: 250).chartYAxisLabel(metric == "Charge" ? "%" : metric == "Temperature" ? "°C" : "W")
                    HStack { Text("\(L10n.text("Recorded samples")): \(points.count)"); Spacer(); Text(points.first?.collectedAt.formatted() ?? "") }.font(.caption).foregroundStyle(.secondary)
                } else { ContentUnavailableView(L10n.text("No recorded measurements yet"), systemImage: "chart.xyaxis.line") }
                HStack {
                    Button(L10n.text("Export JSON…")) { model.prepareExport() }
                    Button(L10n.text("Export CSV…")) { model.prepareExport(csv: true) }
                }
                if let summary = model.historySummary {
                    if let since = summary.monitoringStart { Text("\(L10n.text("Monitoring since")): \(since.formatted(.dateTime.locale(L10n.locale)))").font(.caption) }
                    Text("\(L10n.text("Charging sessions")): \(summary.chargingSessionCount) · \(L10n.text("Recorded gaps")): \(summary.gaps.count)").font(.caption)
                    if let charged = summary.estimatedChargedWh, let discharged = summary.estimatedDischargedWh {
                        Text("\(L10n.text("Estimated energy")): +\(charged.formatted(.number.precision(.fractionLength(2)))) / −\(discharged.formatted(.number.precision(.fractionLength(2)))) Wh").font(.caption)
                    }
                    ForEach(Array(summary.sessions.suffix(5))) { session in
                        Text("\(L10n.text("Observed session")): \(session.observedFrom.formatted(.dateTime.locale(L10n.locale))) — \(session.endedAt.map { $0.formatted(.dateTime.locale(L10n.locale)) } ?? L10n.text("Current"))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !model.historyEnabled { Text(L10n.text("Recording is off")).foregroundStyle(.secondary) }
            }
        }
    }
}

@MainActor
private struct SettingsPanel: View {
    @ObservedObject var model: TilveroModel
    @State private var confirmErase = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker(L10n.text("Settings section"), selection: $model.selectedSettingsPage) {
                ForEach(SettingsPage.allCases) { Text(L10n.text($0.title)).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().id(L10n.language)
            switch model.selectedSettingsPage {
            case .general: general
            case .quickPanel: QuickPanelBuilder(model: model)
            case .history: historySettings
            }
        }.alert(L10n.text("Erase history"), isPresented: $confirmErase) {
            Button(L10n.text("Cancel"), role: .cancel) {}
            Button(L10n.text("Erase history"), role: .destructive) { model.eraseHistory() }
        } message: { Text(L10n.text("Delete local measurements? This does not change charging or cooling settings.")) }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                Form {
                    Picker(L10n.text("Menu bar"), selection: $model.displayStyle) { ForEach(MenuBarDisplayStyle.allCases) { Text($0.title).tag($0) } }
                    Picker(L10n.text("Percentage size"), selection: $model.menuBarTextSize) {
                        ForEach(MenuBarTextSize.allCases) { Text($0.title).tag($0) }
                    }.disabled(model.displayStyle == .iconOnly)
                    HStack {
                        Text(L10n.text("Icon scale"))
                        Slider(value: Binding(get: { model.menuBarIconScale }, set: model.setMenuBarIconScale), in: 0.85...1.15, step: 0.05)
                            .frame(maxWidth: 180).accessibilityLabel(L10n.text("Icon scale"))
                        Text("\(Int((model.menuBarIconScale * 100).rounded()))%").monospacedDigit().frame(width: 42, alignment: .trailing)
                        Button(L10n.text("Reset size")) { model.resetMenuBarSizing() }
                    }
                    Picker(L10n.text("Language"), selection: $model.language) { Text(L10n.text("System language")).tag("system"); Text("Русский").tag("ru"); Text("English").tag("en") }
                    Picker(L10n.text("Temperature units"), selection: $model.fahrenheit) { Text("°C").tag(false); Text("°F").tag(true) }
                    HStack {
                        Text(L10n.text("Launch at login")); Spacer()
                        Text(L10n.text(model.loginStatus)).foregroundStyle(.secondary)
                        Button(L10n.text(model.loginStatus == "Enabled" ? "Disable" : "Enable")) { model.toggleLogin() }.disabled(model.isDemo || model.loginStatus == "Not available from this local build")
                    }
                }.padding(12)
            }
            GroupBox {
                KeepAwakePanel(model: model).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(L10n.text("Customize quick panel…")) { model.selectedSettingsPage = .quickPanel }
        }
    }
    private var historySettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox(L10n.text("History")) {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(L10n.text("Save history"), isOn: $model.historyEnabled).disabled(model.isDemo)
                    Picker(L10n.text("Detailed samples"), selection: $model.retentionDays) { ForEach([7,14,30], id: \.self) { Text(L10n.text("\($0) days")).tag($0) } }.frame(maxWidth: 350).disabled(model.isDemo)
                    Text(L10n.text("Minute samples use the selected period. Hourly aggregates are kept for 12 months.")).font(.caption).foregroundStyle(.secondary)
                    Text(L10n.text("Sleep reports use the selected detailed-history period.")).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.text("Erase history…"), role: .destructive) { confirmErase = true }.disabled(model.isDemo)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            GroupBox(L10n.text("Recovery & uninstall")) {
                Text(L10n.text("Release control before removing Tilvero. Use Native charging and Privileged controls in Diagnostics to check restoration. Quit the app normally, then move its bundle to Trash. History can be erased separately.")).frame(maxWidth: .infinity, alignment: .leading).padding(12)
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
