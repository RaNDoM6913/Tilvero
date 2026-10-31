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
import ChargeBackends

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
    @Published private(set) var sleepSessions: [SleepSessionRecord] = []
    @Published private(set) var processActivity: ProcessActivitySnapshot?
    @Published private(set) var highCPUApplications: [ProcessActivityRow] = []
    private let processActivityProvider: @Sendable () async -> ProcessResourceCollection
    private var processSampler = ProcessActivitySampler(timebaseNumerator: ProcessActivityProvider.timebase.numerator, timebaseDenominator: ProcessActivityProvider.timebase.denominator)
    private var processHighlights = SustainedCPUActivity()
    private var isReadingProcesses = false
    private var processMonitorStopped = false
    private var processRevision: UInt64 = 0
    private var lastProcessRefreshUptime: Double?
    @Published private(set) var sleepActivity: SleepAssertionSnapshot?
    @Published private(set) var systemChargeLimit: SystemChargeLimitObservation?
    @Published private(set) var isReadingSystemChargeLimit = false
    private let systemChargeLimitProvider: @Sendable () async -> SystemChargeLimitObservation
    @Published private(set) var sleepReportError: String?
    @Published private(set) var isReadingSleepActivity = false
    @Published var selectedSettingsPage: SettingsPage = .general
    @Published var selectedSection: InfoSection = .overview { didSet {
        preferences.set(selectedSection.rawValue, forKey: "lastSection")
    } }
    @Published var overviewPreferences: OverviewPreferences { didSet {
        if let data = try? JSONEncoder().encode(overviewPreferences) { preferences.set(data, forKey: "overviewPreferences.v1") }
    } }
    @Published private(set) var modeLibrary: ModeLibrary
    @Published private(set) var modeReport: ModeApplicationReport?
    @Published var selectedMode: WorkMode = .economy
    @Published var language: String { didSet { preferences.set(language, forKey: "language"); onPresentationChange?() } }
    @Published var fahrenheit: Bool { didSet { preferences.set(fahrenheit, forKey: "fahrenheit") } }
    @Published var historyEnabled: Bool { didSet {
        preferences.set(historyEnabled, forKey: "historyEnabled")
        do { try store?.markGap(reason: .explicitBoundary) } catch { storeError = String(describing: error) }
        lastPersisted = nil
        resetSleepObservation(reason: .historyDisabled, persist: !historyEnabled)
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
    let keepAwake: KeepAwakeService
    private var awakeSubscription: AnyCancellable?
    private var awakeMessageSubscription: AnyCancellable?
    private var lastAwakeFailureNotice: String?
    @Published var keepAwakeDraft: KeepAwakeDraft { didSet {
        if case .duration(let duration) = keepAwakeDraft {
            preferences.set(duration.rawValue, forKey: "keepAwakeMinutes")
        }
    } }
    @Published var keepAwakeUsesCustomDuration = false
    @Published var keepAwakeCustomMinutes: String { didSet {
        if keepAwakeUsesCustomDuration, let minutes = Int(keepAwakeCustomMinutes),
           let duration = KeepAwakeDuration(rawValue: minutes) { keepAwakeDraft = .duration(duration) }
    } }
    var keepAwakeDuration: KeepAwakeDuration {
        get {
            if case .duration(let duration) = keepAwakeDraft { return duration }
            return KeepAwakeDuration.load(preferences.object(forKey: "keepAwakeMinutes"))
        }
        set {
            keepAwakeUsesCustomDuration = !KeepAwakeDuration.allCases.contains(newValue)
            keepAwakeCustomMinutes = String(newValue.rawValue)
            keepAwakeDraft = .duration(newValue)
        }
    }
    /// Positive values are finite presets, -1 custom, -2 a concrete Date, 0 explicit infinity.
    var keepAwakeSelectedOption: Int {
        switch keepAwakeDraft {
        case .duration(let duration): keepAwakeUsesCustomDuration ? -1 : duration.rawValue
        case .until: -2
        case .untilStopped: 0
        }
    }
    func selectKeepAwakeOption(_ value: Int) {
        switch value {
        case -1:
            let duration = keepAwakeDuration
            keepAwakeCustomMinutes = String(duration.rawValue)
            keepAwakeUsesCustomDuration = true
            keepAwakeDraft = .duration(duration)
        case -2:
            if case .until = keepAwakeDraft { return }
            keepAwakeDraft = .until(Date().addingTimeInterval(1800))
        case 0: keepAwakeDraft = .untilStopped
        default:
            guard let duration = KeepAwakeDuration(rawValue: value) else { return }
            keepAwakeDuration = duration
        }
    }
    var canStartKeepAwakeDraft: Bool {
        guard keepAwake.isAvailable, !keepAwake.hasOwnedAssertion else { return false }
        switch keepAwakeDraft {
        case .duration:
            return !keepAwakeUsesCustomDuration || Int(keepAwakeCustomMinutes).flatMap(KeepAwakeDuration.init(rawValue:)) != nil
        case .until(let date): return date.timeIntervalSinceNow > 0 && date.timeIntervalSinceNow <= 86_400
        case .untilStopped: return true
        }
    }
    func startKeepAwakeDraft() throws {
        switch keepAwakeDraft {
        case .duration(let duration):
            if keepAwakeUsesCustomDuration {
                guard let minutes = Int(keepAwakeCustomMinutes), let custom = KeepAwakeDuration(rawValue: minutes) else { throw KeepAwakeError.invalidDuration }
                try keepAwake.start(seconds: custom.seconds)
            } else { try keepAwake.start(seconds: duration.seconds) }
        case .until(let date): try keepAwake.start(until: date)
        case .untilStopped: try keepAwake.startUntilStopped()
        }
    }
    let nativeCharge: NativeChargeService
    let keyboardBacklight: KeyboardBacklightService
    private var nativeSubscription: AnyCancellable?
    let liveControl: LiveControlService
    private var liveSubscription: AnyCancellable?
    let isDemo: Bool
    var isPopoverVisible = false
    var isDetailVisible = false
    var openDetails: (@MainActor () -> Void)?
    var onPresentationChange: (@MainActor () -> Void)?
    private var pollingTask: Task<Void, Never>?
    private var isReading = false
    private var lifecycleEpoch: UInt64 = 0
    private var queuedWakeRefresh = false
    private var observedWake = false
    private let sleepRunID = UUID()
    private var sleepTracker = SleepSessionTracker()
    private var lastRawSleepEndpoint: SleepBatteryEndpoint?
    private let sleepActivityProvider: @Sendable () async -> SleepAssertionSnapshot
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
         snapshotProvider: (@Sendable () async -> BatterySnapshot)? = nil,
         sleepActivityProvider: (@Sendable () async -> SleepAssertionSnapshot)? = nil,
         systemChargeLimitProvider: (@Sendable () async -> SystemChargeLimitObservation)? = nil,
         liveControl: LiveControlService? = nil,
         keepAwakeTransport: (any KeepAwakeTransport)? = nil,
         processActivityProvider: (@Sendable () async -> ProcessResourceCollection)? = nil,
         keyboardBacklight: KeyboardBacklightService? = nil) {
        self.systemChargeLimitProvider = systemChargeLimitProvider ?? {
            await Task.detached(priority: .utility) { SystemChargeLimitObservation.read() }.value
        }
        self.isDemo = isDemo
        self.processActivityProvider = processActivityProvider ?? { await ProcessActivityProvider().read() }
        self.preferences = preferences
        let savedAwakeDuration = KeepAwakeDuration.load(preferences.object(forKey: "keepAwakeMinutes"))
        keepAwakeDraft = .duration(savedAwakeDuration)
        keepAwakeCustomMinutes = String(savedAwakeDuration.rawValue)
        keepAwakeUsesCustomDuration = !KeepAwakeDuration.allCases.contains(savedAwakeDuration)
        let monitoring = Bundle.main.object(forInfoDictionaryKey: "TilveroReleaseMode") as? String == "monitoring"
        self.keyboardBacklight = keyboardBacklight ?? KeyboardBacklightService(
            storage: UserDefaultsKeyboardBacklightStorage(defaults: preferences), allowed: !isDemo && !monitoring)
        keepAwake = KeepAwakeService(driver: keepAwakeTransport ?? NativeKeepAwakeTransport(), allowed: !isDemo && !monitoring)
        modeLibrary = ModeLibrary.load(preferences.data(forKey: isDemo ? "demoModePlans.v1" : "modePlans.v1"))
        overviewPreferences = OverviewPreferences.load(preferences.data(forKey: "overviewPreferences.v1"))
        self.sleepActivityProvider = sleepActivityProvider ?? {
            await SleepActivityProvider().readSnapshot()
        }
        self.liveControl = liveControl ?? LiveControlService(preferences: preferences)
        if isDemo {
            nativeCharge = NativeChargeService(client: PowerUIChargeClient(),
                journalURL: FileManager.default.temporaryDirectory.appendingPathComponent("TilveroDemo-\(UUID().uuidString)/native-session.json"), monitoringOnly: true)
        } else {
            let storage = historyURL ?? (try? ReleaseIdentity.current().historyURL()) ?? FileManager.default.temporaryDirectory.appendingPathComponent("TilveroUnavailable/History.sqlite")
            nativeCharge = NativeChargeService(historyURL: storage)
        }
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
                let url = try historyURL ?? ReleaseIdentity.current().historyURL()
                store = try BatteryHistoryStore(url: url)
                // Independent history readers must still run if sleep-codec validation
                // rejects retention. Never turn a preserved corrupt record into empty success.
                do { try store?.configureRetention(retentionDays) }
                catch { storeError = String(describing: error) }
                reloadHistory()
                reloadSleepSessions()
            }
            catch { storeError = String(describing: error) }
        }
        selectedSection = InfoSection(rawValue: preferences.string(forKey: "lastSection") ?? "") ?? .overview
        updateLoginStatus()
        awakeSubscription = keepAwake.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        awakeMessageSubscription = keepAwake.$message.sink { [weak self] message in
            guard let self else { return }
            // Safe cleanup removes the pinned session. Keep its failure visible on every tab.
            let endedFailure = self.keepAwake.hasOwnedAssertion ? nil : message.map(L10n.text)
            if let endedFailure { self.notice = endedFailure }
            else if self.notice == self.lastAwakeFailureNotice { self.notice = nil }
            self.lastAwakeFailureNotice = endedFailure
        }
        nativeSubscription = nativeCharge.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        liveSubscription = self.liveControl.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
            self?.onPresentationChange?()
        }
    }

    var visibleOverviewMetrics: [OverviewMetric] {
        overviewPreferences.order.filter {
            !overviewPreferences.hidden.contains($0) && !($0 == .forecast && snapshot.isExternalPower.availability == .available && snapshot.isExternalPower.freshness != .stale && snapshot.isExternalPower.value == true)
        }
    }
    var quickHistoryPoints: [HistoryChartPoint] {
        HistoryChart.points(history.filter { !$0.isAggregate && $0.collectedAt >= snapshot.collectedAt.addingTimeInterval(-3600) && $0.collectedAt <= snapshot.collectedAt }.map {
            ChartObservation(id: $0.id, date: $0.collectedAt, value: $0.chargePercent, continuityID: $0.segmentID.uuidString)
        })
    }
    var dischargeForecast: DischargeForecast.Estimate? {
        guard !isDemo else { return nil }
        return DischargeForecast.estimate(history.map {
            .init(date: $0.collectedAt, percent: $0.chargePercent, segment: $0.segmentID.uuidString,
                  externalPower: $0.isExternalPower, charging: $0.isCharging, monotonic: $0.monotonicTime, aggregate: $0.isAggregate)
        }, currentPercent: snapshot.chargePercent.value,
        currentFresh: snapshot.chargePercent.availability == .available && snapshot.chargePercent.freshness == .fresh,
        onBattery: snapshot.isExternalPower.availability == .available && snapshot.isExternalPower.freshness == .fresh && snapshot.isExternalPower.value == false,
        now: snapshot.collectedAt)
    }
    var chargeText: String {
        guard snapshot.chargePercent.availability == .available || snapshot.chargePercent.freshness == .stale else { return "—" }
        return ReadingPresentation.validLevel(snapshot.chargePercent.value).map { "\($0)%" } ?? "—"
    }
    var chargingStateText: String { L10n.text(ReadingPresentation.chargingStateKey(snapshot)) }
    var usesNativeCharge: Bool { !isDemo && !nativeCharge.isMonitoringOnly && nativeCharge.interfaceWasDiscovered }
    var chargeState: ChargePolicyState? {
        if isDemo { return control?.charge }
        guard usesNativeCharge else { return liveControl.chargeState }
        var state = ChargePolicyState()
        let observed = nativeCharge.observed
        state.requested = nativeCharge.requestedIntent
        state.appliedTarget = !nativeCharge.recoveryRequired && observed?.isFresh == true && observed?.policyMatches == true && observed?.configuration.enabled == true ? observed?.configuration.target : nil
        state.pendingTarget = nativeCharge.pendingTarget
        state.phase = nativeCharge.recoveryRequired ? .fault : nativeCharge.restorationPending ? .restoring : nativeCharge.pendingTarget != nil ? .pendingLowerLimit : nativeCharge.hasOwnedSettings ? .managed : .observing
        state.reason = nativeCharge.message
        return state
    }
    var acceptedTargets: [Int] { isDemo ? control?.acceptedTargets ?? [] : nativeCharge.isMonitoringOnly ? [] : usesNativeCharge ? nativeCharge.acceptedTargets : liveControl.acceptedTargets }
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
    var canEdit: Bool { (isDemo ? control != nil : usesNativeCharge || liveControl.canCharge) && !isApplying && !nativeCharge.isBusy && !nativeCharge.isQualifying && !liveControl.isBusy && !isOneShotDemo }
    var canPerformChargeActions: Bool { isDemo || (usesNativeCharge ? nativeCharge.canApply : liveControl.canCharge) }
    var canChargeToFullOnce: Bool { isDemo || (usesNativeCharge ? nativeCharge.canChargeToFullOnce : liveControl.canCharge) }
    var canReleaseCharge: Bool { isDemo || nativeCharge.hasOwnedSettings || nativeCharge.pendingTarget != nil || nativeCharge.recoveryRequired || liveControl.hasOwnedSettings }
    var terminationRecoveryMessage: String? { keepAwake.message.map(L10n.text) ?? nativeCharge.message.map(L10n.text) ?? liveControl.message.map(L10n.text) }
    var canApply: Bool {
        guard canEdit, let target = draftTarget else { return false }
        if !isDemo && usesNativeCharge && !nativeCharge.needsApply(target: target) { return false }
        return (!isDemo && liveControl.needsExplicitReapply) || chargeState?.requested != .ceiling(target) || chargeState?.phase == .fault || chargeState?.phase == .externalChange
    }
    var sliderIndex: Double { Double(acceptedTargets.firstIndex(of: draftTarget ?? 80) ?? 0) }
    var pendingTarget: Int? { chargeState?.pendingTarget }
    var effectiveLimitText: String {
        guard let state = chargeState else { return L10n.text("Control unavailable") }
        if !isDemo && nativeCharge.recoveryRequired { return L10n.text("Charging session needs review") }
        let effective = state.appliedTarget.map { "\($0)%" } ?? L10n.text("Unknown")
        if !isDemo && nativeCharge.restorationPending {
            return L10n.text("Restoration waiting for natural discharge") + " · " + L10n.text("Effective") + " " + effective
        }
        if let pending = state.pendingTarget { return "\(L10n.text("Pending")) \(pending)% · \(L10n.text("Effective")) \(effective)" }
        if state.requested == nil || state.requested == .system { return L10n.text("System managed") }
        if state.phase == .systemOverride { return L10n.text("System charging override") }
        return "\(L10n.text("Effective")) \(effective)"
    }
    var fanless: Bool { snapshot.catalog.first { $0.id == "001" }?.value?.stringValue == "Mac17,3" && !isDemo }
    func start() {
        processMonitorStopped = false
        guard pollingTask == nil else { return }
        if !isDemo { Task { await liveControl.start() }; observer.start { [weak self] in Task { await self?.refresh() } } }
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.sleeping {
                    await self.refresh()
                    await self.refreshNativeCharge()
                    await self.refreshProcessActivity()
                    if self.systemChargeLimit.map({ Date().timeIntervalSince($0.collectedAt) >= 30 }) ?? true {
                        await self.refreshSystemChargeLimit()
                    }
                }
                try? await Task.sleep(for: .seconds(self.isPopoverVisible || self.isDetailVisible ? 5 : 30))
            }
        }
    }
    func stop() {
        processMonitorStopped = true; processRevision &+= 1; processSampler.reset(); processActivity = nil
        processHighlights.reset(); highCPUApplications = []
        try? keepAwake.stop()
        resetSleepObservation(reason: .applicationStopped, persist: true)
        pollingTask?.cancel(); pollingTask = nil; observer.stop(); try? store?.close()
    }
    func setSleeping(_ value: Bool) {
        if value && sleeping { return }
        if !value && !sleeping && observedWake { return }
        lifecycleEpoch &+= 1
        processRevision &+= 1; processSampler.reset(); processActivity = nil; lastProcessRefreshUptime = nil
        processHighlights.reset(); highCPUApplications = []
        sleeping = value
        systemChargeLimit = nil
        if value {
            observedWake = false
            if !isDemo && historyEnabled {
                saveSleepChanges(sleepTracker.accept(.willSleep(stamp: sleepStamp(), latestEndpoint: lastRawSleepEndpoint)))
            }
            if !isDemo { Task { if !(await liveControl.prepareForSleep()) { notice = L10n.text("Recovery required") } } }
            do { try store?.markGap(reason: .sleep) } catch { storeError = String(describing: error) }
        } else {
            observedWake = true
            try? keepAwake.reconcile()
            if !isDemo && historyEnabled { saveSleepChanges(sleepTracker.accept(.didWake(stamp: sleepStamp(), epoch: lifecycleEpoch))) }
            queuedWakeRefresh = true
            Task { await refresh() }
        }
    }
    func refreshProcessActivity(force: Bool = false) async {
        guard !isDemo, !sleeping, !processMonitorStopped, !isReadingProcesses else { return }
        if !force, let lastProcessRefreshUptime, ProcessInfo.processInfo.systemUptime - lastProcessRefreshUptime < 2 { return }
        isReadingProcesses = true
        let revision = processRevision
        defer { isReadingProcesses = false }
        let observed = await processActivityProvider()
        guard revision == processRevision, !sleeping, !processMonitorStopped else { return }
        let activity = processSampler.accept(observed)
        processActivity = activity
        highCPUApplications = processHighlights.accept(activity, monotonic: observed.monotonic)
        lastProcessRefreshUptime = ProcessInfo.processInfo.systemUptime
    }
    func refresh() async {
        try? keepAwake.reconcile()
        guard !isReading, !sleeping else { return }
        isReading = true
        let readEpoch = lifecycleEpoch
        defer {
            isReading = false
            if queuedWakeRefresh && !sleeping {
                queuedWakeRefresh = false
                Task { await refresh() }
            }
        }
        if isDemo { await refreshSimulation() }
        else {
            let raw = await snapshotProvider()
            // Display-retained values are not new measurements. A read begun before
            // a sleep/wake/erase boundary cannot become the post-wake endpoint.
            guard readEpoch == lifecycleEpoch, !sleeping else { return }
            queuedWakeRefresh = false
            let previousPower = snapshot.isExternalPower.value
            if historyEnabled {
                lastRawSleepEndpoint = SleepBatteryEndpoint(snapshot: raw, stamp: sleepStamp())
                if let endpoint = lastRawSleepEndpoint {
                    saveSleepChanges(sleepTracker.accept(.freshReading(endpoint: endpoint, epoch: readEpoch)))
                }
                saveSleepChanges(sleepTracker.accept(.expire(stamp: sleepStamp())))
            } else { lastRawSleepEndpoint = nil }
            snapshot = raw.retainingPreviousReadings(snapshot)
            await liveControl.observe(snapshot)
            await nativeCharge.observeBattery(percent: raw.chargePercent.value,
                fresh: raw.chargePercent.availability == .available && raw.chargePercent.freshness == .fresh)
            guard readEpoch == lifecycleEpoch, !sleeping else { return }
            if selectedSection == .sleep && previousPower != raw.isExternalPower.value {
                Task { await refreshSleepActivity() }
            }
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
        if !isDemo, case let .ceiling(target) = nativeCharge.requestedIntent { draftText = String(target) }
        else if !isDemo, let observed = nativeCharge.observed { draftText = String(observed.configuration.target) }
        else if !isDemo, case let .ceiling(target) = liveControl.requestedIntent { draftText = String(target) }
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
        else if usesNativeCharge { runNative { try $0.cancelPending() } }
        else { runLive { try await $0.cancelPending() } }
    }
    private func perform(_ request: ChargeControlRequest) {
        if isDemo { runSimulation { simulator in try await simulator.submit(request) } }
        else if usesNativeCharge {
            let percent = snapshot.chargePercent.value
            let fresh = snapshot.chargePercent.availability == .available && snapshot.chargePercent.freshness == .fresh
            runNative { service in
                switch request {
                case .setCeiling(let target): try await service.apply(target, batteryPercent: percent, batteryFresh: fresh)
                case .chargeToFullOnce: try await service.chargeToFullOnce(batteryPercent: percent, batteryFresh: fresh)
                case .cancelOneShot: try await service.cancelOneShot(batteryPercent: percent, batteryFresh: fresh)
                case .returnToSystemControl: _ = try await service.restore(batteryPercent: percent, batteryFresh: fresh)
                }
            }
        } else { runLive { try await $0.submit(request) } }
    }
    func refreshNativeCharge() async {
        guard !isDemo, !sleeping else { return }
        await nativeCharge.refresh()
        if !draftDirty { discardDraft() }
    }
    func qualifyNativeCharge() { runNative { try await $0.qualify() } }
    private func runNative(_ action: @escaping @MainActor (NativeChargeService) async throws -> Void) {
        guard !isDemo, !isApplying else { return }
        isApplying = true; arbiter.recordManualAction(at: Date()); persistArbiter()
        Task {
            defer { isApplying = false }
            do {
                try await action(nativeCharge); draftDirty = false
                if !nativeCharge.isBusy { await nativeCharge.refresh() }
                discardDraft(); notice = nativeCharge.message.map(L10n.text)
            } catch { notice = L10n.text(error.localizedDescription) }
        }
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
        do { try keepAwake.stop() } catch { return false }
        if isDemo { return true }
        guard !isApplying else { return false }
        let helperRestored = await liveControl.prepareForTermination()
        if nativeCharge.hasOwnedSettings || nativeCharge.recoveryRequired || nativeCharge.pendingTarget != nil {
            do {
                let restored = try await nativeCharge.restore(batteryPercent: snapshot.chargePercent.value,
                    batteryFresh: snapshot.chargePercent.availability == .available && snapshot.chargePercent.freshness == .fresh)
                return helperRestored && restored
            } catch { notice = L10n.text(error.localizedDescription); return false }
        }
        return helperRestored
    }
    func advanceSimulation() { runSimulation { try await $0.advance(seconds: 60) } }
    func saveMode(_ plan: ModePlan) throws {
        var updated = modeLibrary
        try updated.save(plan)
        let data = try JSONEncoder().encode(updated)
        preferences.set(data, forKey: isDemo ? "demoModePlans.v1" : "modePlans.v1")
        modeLibrary = updated
    }
    func modePreview(_ plan: ModePlan) -> [ModeActionRow] {
        plan.preview(chargeTargets: acceptedTargets, chargeAvailable: isDemo || (usesNativeCharge && nativeCharge.canApply),
                     restoreAvailable: isDemo || canReleaseCharge || liveControl.hasOwnedSettings || liveControl.recoveryRequired)
    }
    func applyMode(_ mode: WorkMode) async {
        guard !isApplying, !nativeCharge.isBusy, !nativeCharge.isQualifying, !liveControl.isBusy else { return }
        notice = nil
        let plan = modeLibrary.plan(mode)
        var rows = modePreview(plan)
        guard rows.contains(where: { $0.status == .available }) else {
            modeReport = .init(plan: plan, rows: rows)
            return
        }
        isApplying = true
        arbiter.recordManualAction(at: Date()); persistArbiter()
        defer { isApplying = false }
        for index in rows.indices where rows[index].status == .available {
            do {
                switch rows[index].action {
                case .charge:
                    guard let target = plan.chargeTarget else { throw PolicyError.invalidPolicy }
                    if isDemo, let simulator {
                        try await simulator.submit(.setCeiling(percent: target))
                        await refreshSimulation()
                    } else {
                        try await nativeCharge.apply(target, batteryPercent: snapshot.chargePercent.value,
                            batteryFresh: snapshot.chargePercent.availability == .available && snapshot.chargePercent.freshness == .fresh)
                    }
                    let pending = isDemo ? control?.charge.pendingTarget != nil : nativeCharge.pendingTarget != nil
                    rows[index].status = pending ? .pending : .applied
                    rows[index].detail = pending ? "Waiting for natural discharge; the requested limit is not active." : "Charge setting confirmed."
                case .restore:
                    if isDemo, let simulator {
                        try await simulator.submit(.returnToSystemControl)
                        await refreshSimulation()
                        rows[index].status = .applied
                        rows[index].detail = "Owned settings restored."
                    } else {
                        // Existing services restore journaled baselines only; no guessed Normal values.
                        let helper = try await liveControl.restoreAll()
                        let native = try await nativeCharge.restore(batteryPercent: snapshot.chargePercent.value,
                            batteryFresh: snapshot.chargePercent.availability == .available && snapshot.chargePercent.freshness == .fresh)
                        rows[index].status = helper && native ? .applied : .pending
                        rows[index].detail = helper && native ? "Owned settings restored." : "Restoration is incomplete. Keep Tilvero open for recovery."
                    }
                default: throw PolicyError.unavailable
                }
            } catch {
                rows[index].status = .failed
                rows[index].detail = error.localizedDescription
            }
        }
        modeReport = .init(plan: plan, rows: rows)
        discardDraft()
    }
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
        do { try store?.configureRetention(retentionDays) } catch { storeError = String(describing: error) }
        reloadHistory(); reloadSleepSessions()
    }
    func eraseHistory() {
        resetSleepObservation(reason: .historyErased, persist: false)
        do { try store?.erase(); lastPersisted = nil; reloadHistory(); reloadSleepSessions() }
        catch { storeError = String(describing: error) }
    }
    private func sleepStamp() -> SleepObservationStamp {
        SleepObservationStamp(wallDate: Date(), continuousSeconds: HelperClock.continuousSeconds(), runID: sleepRunID)
    }
    private func saveSleepChanges(_ records: [SleepSessionRecord]) {
        guard !isDemo, !records.isEmpty else { return }
        do {
            guard let store else { throw HistoryStoreError.unavailable }
            for record in records { try store.upsertSleepSession(record) }
            reloadSleepSessions()
        } catch { sleepReportError = L10n.text("Sleep report storage is unavailable. Existing data was preserved.") }
    }
    private func reloadSleepSessions() {
        guard !isDemo else { sleepSessions = []; return }
        do {
            guard let store else { throw HistoryStoreError.unavailable }
            var records = try store.sleepSessions(limit: 2000)
            // Older-run pending observations can never resume, even when history
            // is off and we deliberately avoid writing recovery metadata to disk.
            let staleIDs = Set(records.filter { row in
                row.isPending && (row.sleepBoundary?.runID ?? row.wakeBoundary?.runID) != sleepRunID
            }.map(\.id))
            if !staleIDs.isEmpty {
                let stamp = sleepStamp()
                records = records.map { staleIDs.contains($0.id) ? $0.interrupted(reason: .applicationRestarted, at: stamp) : $0 }
                if historyEnabled { for record in records where staleIDs.contains(record.id) { try store.upsertSleepSession(record) } }
            }
            sleepSessions = records; sleepReportError = nil
        } catch { sleepReportError = L10n.text("Sleep report storage is unavailable. Existing data was preserved.") }
    }
    private func resetSleepObservation(reason: SleepInterruptionReason, persist: Bool) {
        lifecycleEpoch &+= 1
        if persist && !isDemo { saveSleepChanges(sleepTracker.accept(.interrupted(reason: reason, stamp: sleepStamp()))) }
        sleepTracker = SleepSessionTracker(); lastRawSleepEndpoint = nil; queuedWakeRefresh = false; observedWake = false
    }
    func refreshSystemChargeLimit() async {
        guard !isDemo, !sleeping, !isReadingSystemChargeLimit else { return }
        isReadingSystemChargeLimit = true
        defer { isReadingSystemChargeLimit = false }
        let epoch = lifecycleEpoch
        let value = await systemChargeLimitProvider()
        guard epoch == lifecycleEpoch, !sleeping else { return }
        systemChargeLimit = value
    }
    func refreshSleepActivity() async {
        guard !isDemo, !sleeping, !isReadingSleepActivity else { return }
        isReadingSleepActivity = true
        defer { isReadingSleepActivity = false }
        let epoch = lifecycleEpoch
        let value = await sleepActivityProvider()
        guard epoch == lifecycleEpoch, !sleeping else { return }
        sleepActivity = value
    }
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
