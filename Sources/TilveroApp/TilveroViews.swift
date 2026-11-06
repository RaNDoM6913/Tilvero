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
    @Environment(\.studioPresentation) private var studioPresentation
    @ObservedObject var model: TilveroModel
    #if TILVERO_LAB_STUDIO
    @Environment(\.studioCaptureRoute) private var studioCaptureRoute
    #endif
    private var presentedSection: InfoSection {
        #if TILVERO_LAB_STUDIO
        studioCaptureRoute?.section ?? model.selectedSection
        #else
        model.selectedSection
        #endif
    }
    private var presentedSleepPage: SleepPage {
        #if TILVERO_LAB_STUDIO
        studioCaptureRoute?.sleepPage ?? model.selectedSleepPage
        #else
        model.selectedSleepPage
        #endif
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var showingSetup: Bool {
        presentedSection == .settings && model.canShowSetup && model.selectedSettingsPage == .setup
    }
    @State private var search = ""
    @State private var showUnavailable = true
    @State private var reveal = false
    @State private var measurementsExpanded = false
    private var query: String { CatalogDataGroup.normalizedSearch(search) }
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 182)
            ZStack(alignment: .topLeading) {
            ScrollView {
                VStack(alignment: .leading, spacing: studioPresentation.spacing(presentedSection == .sleep ? 18 : 22)) {
                    HStack(alignment: .firstTextBaseline) {
                        StudioText(presentedSection.title, id: "page.title").font(.system(size: 24, weight: .semibold))
                        Spacer(minLength: 8)
                        if !showingSetup && (presentedSection != .sleep || presentedSleepPage == .reports) {
                        Button { Task { await model.refresh(); if presentedSection == .sleep { await model.refreshSleepActivity() } } } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel(L10n.text("Refresh"))
                            .studioElement("page.refresh", label: "Refresh readings")
                        }
                    }
                    if model.isDemo {
                        Label(L10n.text("Simulation only — your Mac settings are unchanged."), systemImage: "testtube.2")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if presentedSection == .overview && model.keepAwake.hasOwnedAssertion { KeepAwakeActivePanel(service: model.keepAwake) }
                    if presentedSection == .overview && model.sleepTimer.isActive { SleepTimerActiveRow(model: model) }
                    if !model.isDemo { nativeChargingAttention }
                    if model.liveControl.hasOwnedSettings || model.liveControl.recoveryRequired || (!model.usesNativeCharge && model.pendingTarget != nil) {
                        ProductSurface(title: "Privileged controls", studioID: "global.privilegedControls") {
                            if !model.usesNativeCharge { Text(model.effectiveLimitText) }
                            if model.liveControl.recoveryRequired {
                                Label(L10n.text("App-owned settings require restoration"), systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                            if let message = model.liveControl.message { Text(L10n.text(message)).font(.system(size: 12)) }
                            StudioActionButton(L10n.text("Restore original settings"), id: "recovery-banner.restore-original-settings") { model.restoreAll() }
                        }
                    }
                    sectionContent
                    if let error = model.storeError { Label(L10n.text("Data store error") + ": " + error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    if presentedSection != .overview && (presentedSection != .sleep || presentedSleepPage == .reports) {
                        Text("\(L10n.text("Last collection")): \(model.snapshot.collectedAt.formatted(.dateTime.locale(L10n.locale)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 24).padding(.top, 25).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .topLeading)
            }.background(studioPresentation.canvas)
                .id(presentedSection).transition(.opacity)
            }.animation(ProductMotion.animation(reduceMotion: reduceMotion), value: presentedSection)
        }.frame(minWidth: 760, minHeight: 540)
            .background(studioPresentation.canvas).foregroundStyle(studioPresentation.foreground)
            .font(.system(size: 13))
            .tint(studioPresentation.accent)
            .accentColor(studioPresentation.accent)
            .disclosureGroupStyle(ProductDisclosureStyle())
            .studioMainScheme()
            .environment(\.locale, L10n.locale)
            .id(model.language)
            .studioElement("application", kind: "container", label: "Application canvas")
            .studioScope("page." + presentedSection.rawValue)
            .sheet(isPresented: Binding(get: { model.exportPreview != nil }, set: { if !$0 { model.exportPreview = nil } })) {
                VStack(alignment: .leading, spacing: 14) {
                    StudioText(L10n.text("Export preview"), id: "export.title").font(.title2)
                    StudioText(L10n.text("Serials and private identifiers are excluded."), id: "export.privacy").foregroundStyle(.secondary)
                    ScrollView { Text(model.exportPreview ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack { StudioActionButton(L10n.text("Cancel"), id: "action.cancel") { model.exportPreview = nil }; Spacer(); StudioActionButton(L10n.text("Save…"), id: "action.save") { model.saveExport() }.buttonStyle(.borderedProminent) }
                }.padding(24).frame(width: 620, height: 470)
                    .studioSubpresentation("export")
            }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                StudioText(AppIdentity.displayName, id: "sidebar.brand").font(.system(size: 24, weight: .semibold))
                TilveroEnergyMark().stroke(studioPresentation.accent, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    .frame(width: 36, height: 20).accessibilityHidden(true)
            }.padding(.horizontal, 14).padding(.top, 22).padding(.bottom, 6)
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
        }.frame(maxHeight: .infinity).background(studioPresentation.sidebar)
        .studioElement("sidebar", kind: "container", label: "Navigation sidebar")
    }
    private func sidebarItem(_ item: InfoSection) -> some View {
        let selected = presentedSection == item
        let needsAttention = item == .diagnostics && !model.isDemo
            && model.nativeCharge.presentation().requiresGlobalAttention
        return Button { model.selectedSection = item } label: {
            HStack(spacing: 9) {
                Image(systemName: item.symbol).font(.system(size: 14)).frame(width: 18).accessibilityHidden(true)
                StudioText(item.title, id: "sidebar.title." + item.rawValue).font(.system(size: 12)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if needsAttention {
                    Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
            }.padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(selected ? 0.065 : 0), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityLabel(item.title)
            .accessibilityValue(needsAttention ? L10n.text("Charging session needs review") : "")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityRemoveTraits(selected ? [] : [.isSelected])
            .padding(.horizontal, 7).padding(.vertical, 1)
            .studioElement("sidebar.destination." + item.rawValue, label: item.title)
    }
    @ViewBuilder private var nativeChargingAttention: some View {
        let state = model.nativeCharge.presentation()
        if state.showsAttentionBanner && presentedSection != .diagnostics {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(nativeAttentionColor(state.attention)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text(nativeAttentionTitle(state.attention))).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(nativeAttentionColor(state.attention))
                    if let preference = state.currentPreference {
                        Text(L10n.text("Native macOS setting") + ": " + (preference.enabled ? "\(preference.target)%" : L10n.text("System managed")))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if let target = state.pendingTarget {
                        Text(L10n.text("Pending") + " \(target)%").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                StudioActionButton(L10n.text("Details"), id: "native-attention.details") { model.selectedSection = .diagnostics }
            }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        }
    }
    private func nativeAttentionColor(_ attention: NativeChargePresentation.Attention) -> Color {
        switch attention {
        case .sessionReview, .mutationUnresolved, .journalIntegrity: .orange
        default: .secondary
        }
    }
    private func nativeAttentionTitle(_ attention: NativeChargePresentation.Attention) -> String {
        switch attention {
        case .sessionReview, .mutationUnresolved: "Charging session needs review"
        case .journalIntegrity: "Native journal needs review"
        case .operationPending: "Waiting for native operation"
        case .restorationPending: "Restoration pending"
        case .lowerTargetPending: "Pending charging target"
        case .policyUnconfirmed: "Waiting for policy confirmation"
        case .none: "Native charging"
        }
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
            Toggle(L10n.text("Show unavailable fields"), isOn: $showUnavailable).toggleStyle(.checkbox).studioElement("catalog.showUnavailable", label: "Show unavailable fields")
            if [.battery, .charging, .diagnostics].contains(presentedSection) {
                Toggle(L10n.text("Reveal identifiers"), isOn: $reveal).toggleStyle(.checkbox).studioElement("catalog.revealIdentifiers", label: "Reveal identifiers")
            }
        }
    }
    @ViewBuilder private var sectionContent: some View {
        switch presentedSection {
        case .overview:
            OverviewDashboard(model: model)
                .id(ObjectIdentifier(model))
            if model.isDemo { SimulationPanel(model: model) }
        case .activity:
            ProcessActivityPanel(model: model)
        case .battery:
            #if TILVERO_LAB_STUDIO
            BatteryDataPanel(model: model, showUnavailable: showUnavailable, reveal: reveal, options: AnyView(measurementOptions), tab: studioCaptureRoute?.batteryTab ?? .overview)
            #else
            BatteryDataPanel(model: model, showUnavailable: showUnavailable, reveal: reveal, options: AnyView(measurementOptions))
            #endif
        case .charging:
            #if TILVERO_LAB_STUDIO
            PowerDataPanel(model: model, showUnavailable: showUnavailable, reveal: reveal, options: AnyView(measurementOptions), tab: studioCaptureRoute?.powerTab ?? .flow)
            #else
            PowerDataPanel(model: model, showUnavailable: showUnavailable, reveal: reveal, options: AnyView(measurementOptions))
            #endif
        case .cooling:
            CoolingPanel(model: model, showUnavailable: showUnavailable)
            if !model.fanless {
                if model.isDemo || !model.fanDescriptors.isEmpty { FanControlPanel(model: model) }
                DataReadingSection(title: "Fan observations", readings: CatalogDataGroup.filtered(readings(["087", "088", "089", "090", "091", "092", "093"]), search: "", showUnavailable: showUnavailable), fahrenheit: model.fahrenheit)
            }
        case .history: HistoryPanel(model: model)
        case .sleep: SleepControlsPanel(model: model)
        case .diagnostics:
            if let reason = model.launchPolicy.monitoringReasonKey {
                Text(L10n.text(reason)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                    NativeChargeStatusPanel(model: model)
                    Divider()
                    SystemChargeLimitPanel(model: model)
                }
            }
            ProductSurface(title: "Privileged controls", symbol: "shield") {
                Label(L10n.text(model.liveControl.hasOwnedSettings ? "App-owned settings require restoration" : "No active helper session"), systemImage: "shield")
                Text("\(L10n.text("Helper")): \(model.helperStatusText)")
                if !model.launchPolicy.monitoringOnly {
                    Text(L10n.text(model.liveControl.message ?? "Signing and hardware validation required")).font(.callout).foregroundStyle(.secondary)
                }
                if model.liveControl.canRegister { StudioActionButton(L10n.text("Enable supported controls"), id: "action.enable-supported-controls") { model.registerHelper() } }
                if model.liveControl.hasOwnedSettings || model.liveControl.recoveryRequired { StudioActionButton(L10n.text("Restore original settings"), id: "diagnostics.helper.restore-original-settings") { model.restoreAll() } }
                if model.liveControl.registrationState == .enabled { StudioActionButton(L10n.text("Disable helper after restoration"), id: "action.disable-helper-after-restoration") { model.removeHelper() } }
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
    private var diagnosticExport: some View { StudioActionButton(L10n.text("Export diagnostics…"), id: "action.export-diagnostics") { model.prepareExport(diagnostics: true) } }
    private var diagnosticInventory: some View { StudioActionButton(L10n.text("Read property inventory"), id: "action.read-property-inventory") { model.inspectRawProperties() } }
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
                    StudioActionButton(L10n.text("Export JSON…"), id: "action.export-json") { model.prepareExport() }
                    StudioActionButton(L10n.text("Export CSV…"), id: "action.export-csv") { model.prepareExport(csv: true) }
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
    #if TILVERO_LAB_STUDIO
    @Environment(\.studioCaptureRoute) private var studioCaptureRoute
    #endif
    private var settingsPages: [SettingsPage] {
        SettingsPage.allCases.filter { $0 != .setup || model.canShowSetup }
    }
    private var presentedSettingsPage: SettingsPage {
        #if TILVERO_LAB_STUDIO
        let requested = studioCaptureRoute?.settingsPage ?? model.selectedSettingsPage
        #else
        let requested = model.selectedSettingsPage
        #endif
        return settingsPages.contains(requested) ? requested : .general
    }
    private var pageSelection: Binding<SettingsPage> {
        #if TILVERO_LAB_STUDIO
        if studioCaptureRoute != nil { return .constant(presentedSettingsPage) }
        #endif
        return Binding(get: { presentedSettingsPage }, set: { model.selectedSettingsPage = $0 })
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmErase = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker(L10n.text("Settings section"), selection: pageSelection) {
                ForEach(settingsPages) { StudioText(L10n.text($0.title), id: "settings.tab." + $0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().id(L10n.language).studioElement("settings.tabs", label: "Settings subpages")
            Group {
                switch presentedSettingsPage {
                case .general: general
                case .quickPanel: QuickPanelBuilder(model: model)
                case .history: historySettings
                case .updates: UpdatesPanel(service: model.updates, installer: model.updateInstaller,
                                           diagnostics: model.openUpdateDiagnostics)
                case .setup: FirstSetupPanel(model: model)
                }
            }.id(presentedSettingsPage).transition(.opacity).studioScope("tab." + presentedSettingsPage.rawValue)
                .animation(ProductMotion.animation(reduceMotion: reduceMotion), value: presentedSettingsPage)
        }.alert(L10n.text("Erase history"), isPresented: $confirmErase) {
            StudioActionButton(L10n.text("Cancel"), id: "action.cancel", role: .cancel) {}
            StudioActionButton(L10n.text("Erase history"), id: "action.erase-history", role: .destructive) { model.eraseHistory() }
        } message: { Text(L10n.text("Delete local measurements? This does not change charging or cooling settings.")) }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 20) {
            ProductSurface(title: "Menu bar") {
                HStack(alignment: .firstTextBaseline) {
                    StudioText(L10n.text("Battery appearance"), id: "settings.batteryAppearance.title")
                    Spacer()
                    Picker(L10n.text("Battery appearance"), selection: $model.menuBarBatteryAppearance) {
                        ForEach(MenuBarBatteryAppearance.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 220).studioElement("settings.batteryAppearance", label: "Battery appearance")
                }
                Divider()
                HStack(alignment: .center) {
                    StudioText(L10n.text("Keep Awake color"), id: "settings.awakeColor.title")
                    Spacer()
                    HStack(spacing: 8) {
                        ForEach(AwakeIndicatorColor.allCases) { option in
                            Button { model.awakeIndicatorColor = option } label: {
                                Circle().fill(Color(nsColor: option.nsColor)).frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(model.awakeIndicatorColor == option ? 0.9 : 0.12), lineWidth: model.awakeIndicatorColor == option ? 2 : 1))
                                    .padding(2)
                            }
                            .buttonStyle(.plain).focusEffectDisabled()
                            .accessibilityLabel(option.title).accessibilityAddTraits(model.awakeIndicatorColor == option ? [.isSelected] : [])
                            .help(option.title)
                        }
                    }.studioElement("settings.awakeColor", label: "Keep Awake indicator color")
                }
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    StudioText(L10n.text("Menu bar"), id: "settings.menuBar.title")
                    Spacer()
                    Picker(L10n.text("Menu bar"), selection: $model.displayStyle) { ForEach(MenuBarDisplayStyle.allCases) { Text($0.title).tag($0) } }.studioElement("settings.displayStyle", label: "Menu bar display style")
                        .labelsHidden().frame(width: 220)
                }
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    StudioText(L10n.text("Percentage size"), id: "settings.percentageSize.title")
                    Spacer()
                    Picker(L10n.text("Percentage size"), selection: $model.menuBarTextSize) {
                        ForEach(MenuBarTextSize.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 220).disabled(model.displayStyle == .iconOnly)
                }
                HStack {
                    StudioText(L10n.text("Icon scale"), id: "settings.iconScale.title")
                    Slider(value: Binding(get: { model.menuBarIconScale }, set: model.setMenuBarIconScale), in: 0.85...1.15, step: 0.05)
                        .frame(minWidth: 80, maxWidth: 220).accessibilityLabel(L10n.text("Icon scale")).studioElement("settings.iconScale", label: "Menu bar icon scale")
                    Text("\(Int((model.menuBarIconScale * 100).rounded()))%").monospacedDigit().frame(width: 42, alignment: .trailing)
                }
                StudioActionButton(L10n.text("Reset size"), id: "action.reset-size") { model.resetMenuBarSizing() }
            }
            ProductSurface(title: "App preferences") {
                HStack(alignment: .firstTextBaseline) {
                    StudioText(L10n.text("Language"), id: "settings.language.title")
                    Spacer()
                    Picker(L10n.text("Language"), selection: $model.language) { Text(L10n.text("System language")).tag("system"); Text("Русский").tag("ru"); Text("English").tag("en") }.studioElement("settings.language", label: "Language")
                        .labelsHidden().frame(width: 220)
                }
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    StudioText(L10n.text("Temperature units"), id: "settings.temperatureUnits.title")
                    Spacer()
                    Picker(L10n.text("Temperature units"), selection: $model.fahrenheit) { Text("°C").tag(false); Text("°F").tag(true) }.studioElement("settings.temperature", label: "Temperature units")
                        .labelsHidden().frame(width: 220)
                }
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    StudioText(L10n.text("Launch at login"), id: "settings.login.title")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(L10n.text(model.loginStatus)).font(.caption).foregroundStyle(.secondary)
                        StudioActionButton(L10n.text(model.loginStatus == "Enabled" ? "Disable" : "Enable"), id: "settings.login") { model.toggleLogin() }
                            .disabled(model.isDemo || model.loginStatus == "Not available from this local build")
                    }
                }
            }
            KeyboardBacklightPanel(service: model.keyboardBacklight)
            StudioActionButton(L10n.text("Sleep timer & Keep Awake…"), id: "action.sleep-timer-keep-awake") { model.selectedSleepPage = .awake; model.selectedSection = .sleep }
            StudioActionButton(L10n.text("Customize quick panel…"), id: "action.customize-quick-panel") { model.selectedSettingsPage = .quickPanel }
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
                    StudioActionButton(L10n.text("Erase history…"), id: "action.erase-history", role: .destructive) { confirmErase = true }.disabled(model.isDemo)
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
                    StudioActionButton(L10n.text("Save schedule"), id: "action.save-schedule") { model.saveSchedule() }
                    if let schedule = model.schedule {
                        Text("\(L10n.text("Scheduled")): \(schedule.fireDate.formatted())").font(.caption)
                        StudioActionButton(L10n.text("Remove schedule"), id: "action.remove-schedule") { model.removeSchedule() }
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
                StudioActionButton(L10n.text("Refresh"), id: "action.refresh") { Task { await model.refresh() } }
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
                Slider(value: $rpm, in: minimum...maximum, step: 1).accessibilityLabel(L10n.text("Manual RPM")).studioElement("fan.rpm", label: "Manual fan RPM")
                HStack {
                    Text("\(Int(rpm)) RPM").monospacedDigit()
                    StudioActionButton(L10n.text("Manual RPM"), id: "action.manual-rpm") { model.setFanPolicy(.manual(Dictionary(uniqueKeysWithValues: model.fanDescriptors.map { ($0.id, Int(rpm)) }))) }
                    StudioActionButton(L10n.text("Timed boost"), id: "action.timed-boost") { model.setFanPolicy(.boost(rpm: Int(rpm), seconds: 60)) }
                    StudioActionButton(L10n.text("System Auto"), id: "action.system-auto") { model.setFanPolicy(.systemAuto) }
                }.disabled(model.isApplying || !model.canControlFans)
                HStack {
                    StudioActionButton(L10n.text("Temperature curve"), id: "action.temperature-curve") {
                        if let curve = try? FanCurve(points: [.init(celsius: 35, rpm: Int(minimum)), .init(celsius: 65, rpm: Int((minimum + maximum) / 2)), .init(celsius: 90, rpm: Int(maximum))]) { model.setFanPolicy(.curve(curve)) }
                    }.disabled(!model.canControlFans || (!model.isDemo && model.fanObservation?.sensorFresh != true))
                    if model.isDemo { StudioActionButton(L10n.text("Advance 60 seconds"), id: "action.advance-60-seconds") { model.advanceSimulation() } }
                }
            }.padding(12)
        }
    }
}
