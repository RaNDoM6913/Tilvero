import Foundation
import Combine
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import PowerCore
import PowerTelemetry
import PowerPersistence
import PowerDiagnostics
import PowerSimulator
import PowerPrivileged

@MainActor
final class TilveroModel: ObservableObject {
    @Published private(set) var snapshot: BatterySnapshot
    @Published private(set) var control: SimulationControlSnapshot?
    @Published var draftText = "80"
    @Published private(set) var notice: String?
    @Published private(set) var isApplying = false
    @Published private(set) var storeError: String?
    @Published private(set) var history: [HistorySample] = []
    @Published private(set) var historySummary: HistorySummary?
    @Published var selectedSection: InfoSection = .overview { didSet { preferences.set(selectedSection.rawValue, forKey: "lastSection") } }
    @Published var language: String { didSet { preferences.set(language, forKey: "language"); onPresentationChange?() } }
    @Published var fahrenheit: Bool { didSet { preferences.set(fahrenheit, forKey: "fahrenheit") } }
    @Published var historyEnabled: Bool { didSet {
        preferences.set(historyEnabled, forKey: "historyEnabled")
        do { try store?.markGap(reason: .explicitBoundary) } catch { storeError = String(describing: error) }
        lastPersisted = nil
    } }
    @Published var retentionDays: Int { didSet { preferences.set(retentionDays, forKey: "retentionDays"); configureRetention() } }
    @Published var displayStyle: MenuBarDisplayStyle {
        didSet { preferences.set(displayStyle.rawValue, forKey: "menuBarDisplayStyle"); onPresentationChange?() }
    }
    @Published var menuBarTextSize: MenuBarTextSize {
        didSet { preferences.set(menuBarTextSize.rawValue, forKey: "menuBarTextSize"); onPresentationChange?() }
    }
    @Published private(set) var menuBarIconScale: Double
    @Published var loginStatus = "Not enabled"
    @Published var demoPercent = 76.0
    @Published var demoExternal = true
    @Published var demoOverride = false
    @Published var scheduleDate = Date().addingTimeInterval(3600)
    @Published var scheduleProfileName = "At desk"
    @Published private(set) var schedule: ScheduleRule?
    @Published var exportPreview: String?
    private var exportData: Data?
    private var exportType: UTType = .json
    let liveControl: LiveControlService
    private var liveSubscription: AnyCancellable?
    let isDemo: Bool
    var isPopoverVisible = false
    var isDetailVisible = false
    var openDetails: (@MainActor () -> Void)?
    var onPresentationChange: (@MainActor () -> Void)?
    private var pollingTask: Task<Void, Never>?
    private var isReading = false
    private var sleeping = false
    private var draftDirty = false
    private var lastPersisted: BatterySnapshot?
    private var inspectedRaw: [CatalogReading] = []
    private var simulator: SimulationController?
    private var store: BatteryHistoryStore?
    private let observer = PowerSourceObserver()
    private var arbiter = ProfileArbiter()
    private let preferences: UserDefaults
    private var snapshotProvider: @Sendable () async -> BatterySnapshot

    init(isDemo: Bool, preferences: UserDefaults = .standard,
         historyURL: URL? = nil,
         snapshotProvider: (@Sendable () async -> BatterySnapshot)? = nil) {
        self.isDemo = isDemo
        self.preferences = preferences
        liveControl = LiveControlService(preferences: preferences)
        let identitySalt = preferences.string(forKey: "identitySalt") ?? UUID().uuidString
        preferences.set(identitySalt, forKey: "identitySalt")
        let provider = MacBatteryProvider(identitySalt: identitySalt)
        self.snapshotProvider = snapshotProvider ?? { await Task.detached(priority: .utility) { provider.readSnapshot() }.value }
        snapshot = isDemo ? .demo() : .unavailable(reason: "Waiting for first reading")
        language = preferences.string(forKey: "language") ?? "system"
        fahrenheit = preferences.bool(forKey: "fahrenheit")
        historyEnabled = preferences.object(forKey: "historyEnabled") as? Bool ?? true
        retentionDays = preferences.object(forKey: "retentionDays") as? Int ?? 30
        menuBarTextSize = MenuBarTextSize(rawValue: preferences.string(forKey: "menuBarTextSize") ?? "") ?? .system
        menuBarIconScale = MenuBarSizing.validatedIconScale(preferences.object(forKey: "menuBarIconScale") as? Double ?? 1)
        displayStyle = MenuBarDisplayStyle(rawValue: preferences.string(forKey: "menuBarDisplayStyle") ?? "") ?? .beside
        if let data = preferences.data(forKey: isDemo ? "demoSchedule" : "schedule") { schedule = try? JSONDecoder().decode(ScheduleRule.self, from: data) }
        if let data = preferences.data(forKey: isDemo ? "demoArbiter" : "arbiter"), let saved = try? JSONDecoder().decode(ProfileArbiter.self, from: data) { arbiter = saved }
        if isDemo {
            do { simulator = try SimulationController(savedState: preferences.data(forKey: "simulationState")) }
            catch { notice = L10n.text("Operation failed"); simulator = try? SimulationController() }
        } else {
            do {
                let url = historyURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Tilvero/History.sqlite")
                store = try BatteryHistoryStore(url: url)
                try store?.configureRetention(retentionDays)
                reloadHistory()
            }
            catch { storeError = String(describing: error) }
        }
        selectedSection = InfoSection(rawValue: preferences.string(forKey: "lastSection") ?? "") ?? .overview
        updateLoginStatus()
        liveSubscription = liveControl.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
            self?.onPresentationChange?()
        }
    }

    var chargeText: String {
        guard snapshot.chargePercent.availability == .available || snapshot.chargePercent.freshness == .stale else { return "—" }
        return ReadingPresentation.validLevel(snapshot.chargePercent.value).map { "\($0)%" } ?? "—"
    }
    var chargingStateText: String { L10n.text(ReadingPresentation.chargingStateKey(snapshot)) }
    var chargeState: ChargePolicyState? { isDemo ? control?.charge : liveControl.chargeState }
    var acceptedTargets: [Int] { isDemo ? control?.acceptedTargets ?? [] : liveControl.acceptedTargets }
    var canShowChargeControls: Bool { isDemo || !acceptedTargets.isEmpty }
    var canApplyProfiles: Bool { isDemo || liveControl.capabilities.contains { $0.readiness == .available } }
    var fanObservation: FanObservation? { liveControl.fanObservation }
    var fanDescriptors: [FanDescriptor] { isDemo ? control?.fanDescriptors ?? [] : fanObservation?.descriptors ?? [] }
    var fanRPM: [String: Int] { isDemo ? control?.fans.observedRPM ?? [:] : fanObservation?.actualRPM ?? [:] }
    var fanPhase: FanPhase { isDemo ? control?.fans.phase ?? .systemAuto : liveControl.fanState.phase }
    var canControlFans: Bool { isDemo || liveControl.canFans }
    var helperStatusText: String {
        switch liveControl.registrationState {
        case .notRegistered: L10n.text("Not enrolled")
        case .enabled: L10n.text("Enabled")
        case .requiresApproval: L10n.text("Requires approval in System Settings")
        case .notFound, .unavailable: L10n.text("Signing and hardware validation required")
        }
    }
    var draftTarget: Int? { ReadingPresentation.percentInput(draftText, acceptedTargets: acceptedTargets) }
    var isOneShotDemo: Bool { chargeState?.requested == .fullOnce }
    var canEdit: Bool { (isDemo ? control != nil : liveControl.canCharge) && !isApplying && !liveControl.isBusy && !isOneShotDemo }
    var canApply: Bool {
        guard canEdit, let target = draftTarget else { return false }
        return (!isDemo && liveControl.needsExplicitReapply) || chargeState?.requested != .ceiling(target) || chargeState?.phase == .fault || chargeState?.phase == .externalChange
    }
    var sliderIndex: Double { Double(acceptedTargets.firstIndex(of: draftTarget ?? 80) ?? 0) }
    var pendingTarget: Int? { chargeState?.pendingTarget }
    var effectiveLimitText: String {
        guard let state = chargeState else { return L10n.text("Control unavailable") }
        let effective = state.appliedTarget.map { "\($0)%" } ?? L10n.text("Unknown")
        if let pending = state.pendingTarget { return "\(L10n.text("Pending")) \(pending)% · \(L10n.text("Effective")) \(effective)" }
        if state.requested == nil || state.requested == .system { return L10n.text("System managed") }
        if state.phase == .systemOverride { return L10n.text("System charging override") }
        return "\(L10n.text("Effective")) \(effective)"
    }
    var fanless: Bool { snapshot.catalog.first { $0.id == "001" }?.value?.stringValue == "Mac17,3" && !isDemo }
    func start() {
        guard pollingTask == nil else { return }
        if !isDemo { Task { await liveControl.start() }; observer.start { [weak self] in Task { await self?.refresh() } } }
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.sleeping { await self.refresh() }
                try? await Task.sleep(for: .seconds(self.isPopoverVisible || self.isDetailVisible ? 5 : 30))
            }
        }
    }
    func stop() { pollingTask?.cancel(); pollingTask = nil; observer.stop(); try? store?.close() }
    func setSleeping(_ value: Bool) {
        sleeping = value
        if value {
            if !isDemo { Task { if !(await liveControl.prepareForSleep()) { notice = L10n.text("Recovery required") } } }
            do { try store?.markGap(reason: .sleep) } catch { storeError = String(describing: error) }
        } else { Task { await refresh() } }
    }
    func refresh() async {
        guard !isReading, !sleeping else { return }
        isReading = true
        defer { isReading = false }
        if isDemo { await refreshSimulation() }
        else {
            snapshot = (await snapshotProvider()).retainingPreviousReadings(snapshot)
            await liveControl.observe(snapshot)
            if historyEnabled {
                do {
                    let changed = lastPersisted.map { $0.isCharging.value != snapshot.isCharging.value || $0.isExternalPower.value != snapshot.isExternalPower.value || $0.batteryIdentityToken != snapshot.batteryIdentityToken || $0.chargePercent.availability != snapshot.chargePercent.availability } ?? true
                    if changed || lastPersisted.map({ previous in
                        let age = snapshot.monotonicTime.flatMap { current in previous.monotonicTime.map { current - $0 } } ?? snapshot.collectedAt.timeIntervalSince(previous.collectedAt)
                        return age >= 60 || age < 0
                    }) ?? true {
                        try store?.record(snapshot); lastPersisted = snapshot; reloadHistory()
                    }
                    if let rows = try store?.catalogReadings(at: snapshot.collectedAt) { snapshot = snapshot.replacingCatalog(rows) }
                    storeError = nil
                }
                catch { storeError = String(describing: error) }
            }
        }
        snapshot = snapshot.replacingCatalog(ControlCatalog.readings(state: chargeState, capabilities: liveControl.capabilities, fans: isDemo ? nil : liveControl.fanObservation, isDemo: isDemo, connected: liveControl.connected, at: snapshot.collectedAt))
        if !inspectedRaw.isEmpty { snapshot = snapshot.replacingCatalog(inspectedRaw) }
        await evaluateSchedule()
        onPresentationChange?()
    }
    func setSliderIndex(_ value: Double) {
        guard canEdit, value.isFinite, !acceptedTargets.isEmpty else { return }
        setDraft(acceptedTargets[min(acceptedTargets.count - 1, max(0, Int(value.rounded())))])
    }
    func setDraft(_ target: Int) {
        guard canEdit, acceptedTargets.contains(target) else { return }
        draftText = String(target); draftDirty = true; notice = nil
    }
    func typedDraftChanged() { draftDirty = true }
    @discardableResult func validateTypedDraft() -> Bool {
        guard let value = draftTarget else { notice = L10n.text("Unsupported percentage. Choose an available step."); return false }
        draftText = String(value); return true
    }
    func setMenuBarIconScale(_ value: Double) {
        menuBarIconScale = MenuBarSizing.validatedIconScale(value)
        preferences.set(menuBarIconScale, forKey: "menuBarIconScale")
        onPresentationChange?()
    }
    func resetMenuBarSizing() { menuBarTextSize = .system; setMenuBarIconScale(1) }
    func quickPanelDidClose() {
        isPopoverVisible = false
        if !isDetailVisible || selectedSection != .charging { discardDraft() }
    }
    func discardDraft() {
        if !isDemo, case let .ceiling(target) = liveControl.requestedIntent { draftText = String(target) }
        else if case let .ceiling(target) = chargeState?.requested { draftText = String(target) }
        else if let value = chargeState?.appliedTarget, acceptedTargets.contains(value) { draftText = String(value) }
        else { draftText = acceptedTargets.first.map(String.init) ?? "" }
        draftDirty = false
    }
    func applyDemoTarget() { guard canApply, validateTypedDraft(), let target = draftTarget else { return }; perform(.setCeiling(percent: target)) }
    func toggleOneShotDemo() { perform(isOneShotDemo ? .cancelOneShot : .chargeToFullOnce) }
    func releaseControl() { perform(.returnToSystemControl) }
    func cancelPendingDemo() {
        if isDemo { runSimulation { simulator in try await simulator.cancelPendingCharge() } }
        else { runLive { try await $0.cancelPending() } }
    }
    private func perform(_ request: ChargeControlRequest) {
        if isDemo { runSimulation { simulator in try await simulator.submit(request) } }
        else { runLive { try await $0.submit(request) } }
    }
    private func runSimulation(_ action: @escaping @Sendable (SimulationController) async throws -> Void) {
        guard isDemo, !isApplying, let simulator else { return }
        isApplying = true; arbiter.recordManualAction(at: Date()); persistArbiter()
        Task {
            defer { isApplying = false }
            do { try await action(simulator); draftDirty = false; await refreshSimulation(); notice = L10n.text("Simulation only — your Mac settings are unchanged.") }
            catch { notice = L10n.text("Operation failed") + ": " + String(describing: error) }
        }
    }
    private func runLive(_ action: @escaping @MainActor (LiveControlService) async throws -> Void) {
        guard !isDemo, !isApplying else { return }
        isApplying = true; arbiter.recordManualAction(at: Date()); persistArbiter()
        Task {
            defer { isApplying = false }
            do { try await action(liveControl); draftDirty = false; discardDraft(); notice = liveControl.message }
            catch { notice = L10n.text("Operation failed") + ": " + error.localizedDescription }
        }
    }
    func setFanPolicy(_ policy: FanPolicy) {
        if isDemo { runSimulation { try await $0.setFanPolicy(policy) } }
        else { runLive { try await $0.setFanPolicy(policy) } }
    }
    func registerHelper() { runLive { try await $0.registerHelper() } }
    func removeHelper() { runLive { try await $0.unregisterHelper() } }
    func restoreAll() { runLive { guard try await $0.restoreAll() else { throw PrivilegeError.recoveryRequired } } }
    func prepareForTermination() async -> Bool {
        if isDemo { return true }
        return await liveControl.prepareForTermination()
    }
    func advanceSimulation() { runSimulation { try await $0.advance(seconds: 60) } }
    func applyProfile(_ name: String) {
        let profile = PowerProfile(name: name, chargeTarget: name == "At desk" ? 80 : nil, mode: name == "On battery profile" ? .low : .automatic)
        if name == "Before leaving" { perform(.chargeToFullOnce); return }
        if !isDemo {
            guard let external = snapshot.isExternalPower.value, snapshot.isExternalPower.freshness != .stale else { notice = L10n.text("Power source unavailable"); return }
            runLive { service in
                let result = await service.applyProfile(profile, source: external ? .adapter : .battery)
                if !result.isComplete { throw ControlUnavailableError(reason: String(describing: result)) }
            }
            return
        }
        runSimulation { simulator in
            let result = await simulator.applyProfile(profile)
            if !result.isComplete { throw ControlUnavailableError(reason: String(describing: result)) }
        }
    }
    private func refreshSimulation() async {
        guard let simulator else { return }
        do {
            try await simulator.observeCharge(percent: Int(demoPercent), externalPower: demoExternal, systemOverride: demoOverride, isCharging: demoExternal && demoPercent < 100)
            control = await simulator.snapshot()
            let savedState: Data = try await simulator.exportState()
            preferences.set(savedState, forKey: "simulationState")
            let now = Date(); let demo = BatterySnapshot.demo(at: now)
            snapshot = BatterySnapshot(chargePercent: .init(value: Int(demoPercent), source: "Simulation", unit: "%"),
                isCharging: .init(value: demoExternal && demoPercent < 100, source: "Simulation"),
                isExternalPower: .init(value: demoExternal, source: "Simulation"), cycleCount: demo.cycleCount,
                manufacturer: demo.manufacturer, temperatureCelsius: demo.temperatureCelsius,
                voltageVolts: demo.voltageVolts, currentAmps: demo.currentAmps,
                timeRemainingSeconds: demo.timeRemainingSeconds, collectedAt: now, isDemo: true,
                catalog: demo.catalog)
            let replacements: [(String, CatalogValue)] = [("011", .integer(Int64(demoPercent))), ("013", .boolean(demoExternal && demoPercent < 100)), ("015", .boolean(demoExternal))]
            snapshot = snapshot.replacingCatalog(replacements.map { CatalogReading(definition: BatteryCatalog.definition($0.0), value: $0.1, source: "Simulation", provenance: .reported, freshness: .fresh) })
            if !draftDirty { discardDraft() }
        } catch { notice = L10n.text("Operation failed") + ": " + String(describing: error) }
        onPresentationChange?()
    }
    func saveSchedule() {
        do {
            schedule = try ScheduleRule(fireDate: scheduleDate, profile: PowerProfile(name: scheduleProfileName, chargeTarget: scheduleProfileName == "At desk" ? 80 : nil, mode: scheduleProfileName == "On battery profile" ? .low : .automatic, oneShotFullCharge: scheduleProfileName == "Before leaving"), missedPolicy: .skip)
            preferences.set(try JSONEncoder().encode(schedule), forKey: isDemo ? "demoSchedule" : "schedule")
        } catch { notice = String(describing: error) }
    }
    func removeSchedule() { schedule = nil; preferences.removeObject(forKey: isDemo ? "demoSchedule" : "schedule") }
    private func evaluateSchedule() async {
        guard let schedule, let profile = arbiter.evaluate(schedule, now: Date()) else { return }
        persistArbiter()
        if !isDemo {
            guard let external = snapshot.isExternalPower.value, snapshot.isExternalPower.freshness != .stale else { notice = L10n.text("Power source unavailable"); return }
            let result = await liveControl.applyProfile(profile, source: external ? .adapter : .battery)
            notice = result.isComplete ? liveControl.message : L10n.text("Operation failed")
            return
        }
        guard let simulator else { return }
        let result = await simulator.applyProfile(profile)
        notice = result.isComplete ? L10n.text("Simulation only — your Mac settings are unchanged.") : L10n.text("Operation failed")
        await refreshSimulation()
    }
    private func persistArbiter() { if let data = try? JSONEncoder().encode(arbiter) { preferences.set(data, forKey: isDemo ? "demoArbiter" : "arbiter") } }
    func reloadHistory() {
        do { history = try store?.samples(since: Date().addingTimeInterval(-7 * 86400)) ?? []; historySummary = try store?.summary() }
        catch { storeError = String(describing: error) }
    }
    private func configureRetention() {
        do { try store?.configureRetention(retentionDays); reloadHistory() } catch { storeError = String(describing: error) }
    }
    func eraseHistory() { do { try store?.erase(); lastPersisted = nil; reloadHistory() } catch { storeError = String(describing: error) } }
    func inspectRawProperties() {
        guard !isDemo else { return }
        Task {
            inspectedRaw = await Task.detached(priority: .utility) { MacBatteryProvider().readRawCatalog() }.value
            snapshot = snapshot.replacingCatalog(inspectedRaw)
        }
    }
    func prepareExport(diagnostics: Bool = false, csv: Bool = false) {
        do {
            let data: Data
            if diagnostics { data = try DoctorReport(snapshot: snapshot).encodedJSON() }
            else { guard let store else { return }; data = try csv ? store.exportCSV() : store.exportJSON() }
            exportData = data; exportType = csv ? .commaSeparatedText : .json
            exportPreview = String(data: data.prefix(6000), encoding: .utf8) ?? ""
        } catch { notice = String(describing: error) }
    }
    func saveExport() {
        guard let data = exportData else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [exportType]
        panel.nameFieldStringValue = "Tilvero-\(isDemo ? "SIMULATION-" : "")\(Date().formatted(.iso8601.year().month().day()))" + (exportType == .json ? ".json" : ".csv")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic); exportPreview = nil; notice = L10n.text("Export saved") }
        catch { notice = String(describing: error) }
    }
    func updateLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled: loginStatus = "Enabled"
        case .requiresApproval: loginStatus = "Requires approval in System Settings"
        case .notRegistered: loginStatus = "Not enabled"
        case .notFound: loginStatus = "Not available from this local build"
        @unknown default: loginStatus = "Unknown"
        }
    }
    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            updateLoginStatus()
        } catch { notice = String(describing: error); updateLoginStatus() }
    }
    func openBatterySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.battery")!) }
}

private extension BatterySnapshot {
    func replacingCatalog(_ readings: [CatalogReading]) -> BatterySnapshot {
        let replacements = Dictionary(readings.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return BatterySnapshot(chargePercent: chargePercent, isCharging: isCharging, isExternalPower: isExternalPower,
            cycleCount: cycleCount, manufacturer: manufacturer, temperatureCelsius: temperatureCelsius,
            voltageVolts: voltageVolts, currentAmps: currentAmps, timeRemainingSeconds: timeRemainingSeconds,
            collectedAt: collectedAt, isDemo: isDemo, catalog: catalog.map { replacements[$0.id] ?? $0 },
            monotonicTime: monotonicTime, batteryIdentityToken: batteryIdentityToken)
    }
}
