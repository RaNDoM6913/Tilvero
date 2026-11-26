// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import Foundation
import Combine
import Observation
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

/// Explicit ports for application actions that are not telemetry or owned control.
/// Production retains the normal macOS implementation; isolated hosts supply all
/// operations together. Setup login actions are a separate, explicit opt-in.
@MainActor struct TilveroModelSideEffects {
    var loginStatus: () -> String
    var toggleLogin: () throws -> Void
    var openBatterySettings: () -> Void
    var rawCatalog: @Sendable () async -> [CatalogReading]
    var setupLogin: SetupLoginPort? = nil

    static var native: Self {
        .init(loginStatus: {
            switch SMAppService.mainApp.status {
            case .enabled: "Enabled"
            case .requiresApproval: "Requires approval in System Settings"
            case .notRegistered: "Not enabled"
            case .notFound: "Not available from this local build"
            @unknown default: "Unknown"
            }
        }, toggleLogin: {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        }, openBatterySettings: {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.battery")!)
        }, rawCatalog: {
            await Task.detached(priority: .utility) { MacBatteryProvider().readRawCatalog() }.value
        })
    }
}

/// The application's state and actions. Observation (`@Observable`): a view re-renders only when a property it read
/// changes, so a process sample, a history record or a navigation change no longer re-renders every observing view.
///
/// The services stay `ObservableObject`s (their Combine publishers wire them to each other and to tests). Each bridged
/// service has a change counter here: reading the service through the model (`model.keepAwake`, or a derived property
/// such as `canEdit`) registers the reading view for that service's changes only. A leaf view that holds the service
/// with `@ObservedObject` observes it directly.
///
/// Stored state that views never read directly is `@ObservationIgnored` (caches, tasks, epochs), so updating it during a
/// body evaluation never schedules another one.
@MainActor @Observable
final class TilveroModel {
    let updates: UpdateCheckService
    private(set) var updatePreparationActive = false
    @ObservationIgnored private var updateExclusion: ControllerSessionLease?
    private let updateLeaseDirectory: URL?
    private let updateEvidence: () -> [UpdateEvidenceProbe.Result]
    @ObservationIgnored lazy var updateInstaller = SparkleUpdateInstaller(
        readOnlyReadiness: { [weak self] in self?.updateReadiness.blockers ?? ["Update recovery status is unavailable."] },
        prepareAfterExplicitConsent: { [weak self] in await self?.prepareForUpdateInstallation() ?? false },
        releaseInstallationExclusion: { [weak self] in self?.releaseUpdateInstallation() },
        diagnostics: { [weak self] in self?.openUpdateDiagnostics() })

    func openUpdateDiagnostics() { navigation.open(.section(.diagnostics)) }

    var updateReadiness: UpdateRecoverySnapshot {
        var result = UpdateRecoverySnapshot()
        result.nativeOwnership = nativeCharge.hasOwnedSettings || nativeCharge.pendingTarget != nil   // fixture sessions only
        // A write whose outcome macOS has not confirmed yet (it closes itself at the first settled clear read).
        result.nativeRecovery = nativeCharge.hasUnresolvedSession || nativeCharge.recoveryRequired || nativeCharge.restorationPending
        result.helperOwnership = liveControl.hasOwnedSettings || liveControl.connected
        result.helperRecovery = liveControl.recoveryRequired
        result.lidOwnership = closedLid.isOn || closedLid.isLiveTrial || lidSleep.isOn
        result.lidRecovery = closedLid.needsRecovery || lidSleep.needsRecovery
        result.operationInFlight = isApplying || isReading || nativeCharge.isBusy || nativeCharge.isQualifying
            || liveControl.isBusy || closedLid.busy || lidSleep.busy || keyboardBacklight.isBusy
        result.sleepTransition = sleeping || sleepTimerBlocksControls || sleepTimer.needsHoldRelease
        result.awakeActive = keepAwake.hasOwnedAssertion
        result.timerActive = sleepTimer.isActive
        let evidence = updateEvidence()
        result.persistentEvidence = evidence.contains(.present)
        result.environmentUnknown = evidence.contains(.unknown)
        if updateExclusion == nil {
            switch ControllerSessionLease.inspect(directory: updateLeaseDirectory) {
            case .available: break
            case .occupied: result.externalController = true
            case .unknown: result.environmentUnknown = true
            }
        }
        return result
    }

    /// Only the installer's explicit per-update choice invokes this. The first
    /// supported profile has no hardware recovery authority: ownership defers it.
    func prepareForUpdateInstallation() async -> Bool {
        guard updates.identity.supportsInstallerProfile, launchPolicy.monitoringOnly,
              !isDemo, updateReadiness.blockers.isEmpty else { return false }
        do { if updateExclusion == nil { updateExclusion = try ControllerSessionLease.acquire(directory: updateLeaseDirectory) } }
        catch { return false }
        updatePreparationActive = true
        guard updateReadiness.blockers.isEmpty else { releaseUpdateInstallation(); return false }
        let restored = await prepareForTermination()
        guard restored, updateReadiness.blockers.isEmpty else { releaseUpdateInstallation(); return false }
        return true
    }

    func releaseUpdateInstallation() { updatePreparationActive = false; updateExclusion = nil }
    private(set) var snapshot: BatterySnapshot
    private(set) var control: SimulationControlSnapshot?
    var draftText = ""
    /// Every feature's notices, one slot per source (`NoticeCenter`).
    let notices = NoticeCenter()
    /// The newest notice of any source (tests and simple checks); surfaces filter with `notices.current(excluding:)`.
    var notice: String? { notices.current()?.text }
    private(set) var isApplying = false
    private(set) var storeError: String?
    private(set) var history: [HistorySample] = [] { didSet { seriesCacheKey = nil } }
    private(set) var historySummary: HistorySummary?
    /// What History.sqlite and its WAL occupy against the store's ceiling; nil until the store has been read.
    private(set) var historyStorage: HistoryStorageUsage?
    /// True from launch until the store is open and the first week, summary and sleep reports are loaded.
    private(set) var historyLoading = false
    @ObservationIgnored private var lastFullHistoryReload: Date?
    private(set) var sleepSessions: [SleepSessionRecord] = []
    private(set) var processActivity: ProcessActivitySnapshot?
    private(set) var highCPUApplications: [ProcessActivityRow] = []
    private let processActivityProvider: @Sendable () async -> ProcessResourceCollection
    @ObservationIgnored private var processSampler = ProcessActivitySampler(timebaseNumerator: ProcessActivityProvider.timebase.numerator, timebaseDenominator: ProcessActivityProvider.timebase.denominator,
                                                        maximumInterval: ProcessScanCadence.longestInterval)
    @ObservationIgnored private var processHighlights = SustainedCPUActivity()
    @ObservationIgnored private var isReadingProcesses = false
    @ObservationIgnored private var processMonitorStopped = false
    @ObservationIgnored private var processRevision: UInt64 = 0
    @ObservationIgnored private var lastProcessRefreshUptime: Double?
    /// The last scan was made at the poll cadence, and nothing has switched scans to the slow cadence since.
    @ObservationIgnored private var lastScanFollowedPoll = false
    private(set) var sleepActivity: SleepAssertionSnapshot?
    /// macOS Low Power Mode, kept current from `NSProcessInfoPowerStateDidChange` (read-only; Tilvero never sets it here).
    private(set) var isLowPowerModeEnabled = false
    private let lowPowerModeReader: @Sendable () -> Bool
    @ObservationIgnored private var powerStateSubscription: AnyCancellable?
    private(set) var systemChargeLimit: SystemChargeLimitObservation?
    private(set) var isReadingSystemChargeLimit = false
    /// Reads the macOS limit, reusing a native read's answer at most `maximumAge` seconds old (0: always a fresh run).
    private let systemChargeLimitProvider: @Sendable (_ maximumAge: TimeInterval) async -> SystemChargeLimitObservation
    private(set) var sleepReportError: String?
    private(set) var isReadingSleepActivity = false
    /// The details window's page and the router every surface navigates with.
    let navigation: AppNavigation
    /// Conveniences over `navigation` (tests and the model's own checks); views and actions use `navigation` directly.
    var selectedSection: InfoSection {
        get { navigation.section }
        set { navigation.navigate(to: .section(newValue)) }
    }
    var selectedSettingsPage: SettingsPage {
        get { navigation.settingsPage }
        set { navigation.settingsPage = newValue }
    }
    var selectedSleepPage: SleepPage {
        get { navigation.sleepPage }
        set { navigation.sleepPage = newValue }
    }
    var openDetails: (@MainActor () -> Void)? {
        get { navigation.presentDetails }
        set { navigation.presentDetails = newValue }
    }

    // MARK: Model-wide change signal
    /// Fires just before any tracked model state, a bridged service, a notice or the navigation changes: what
    /// `objectWillChange` used to deliver. Only the popover host's safety-net fit and Setup's readiness refresh listen;
    /// views never do (they track exactly what they read).
    var changes: AnyPublisher<Void, Never> { changeSignal.eraseToAnyPublisher() }
    /// Something outside the model changed what Setup or the quick panel derive from it (an installed permission): the
    /// change signal fires as if the model itself had changed.
    func notifyExternalChange() { externalChanges &+= 1 }
    /// The time zone or the system clock changed: every absolute time on screen (Keep Awake and sleep timer end, the
    /// charge-by deadline, sleep reports, "Last collection") is formatted again. Views showing localized text depend on
    /// `PresentationRevision`; leaf views that hold Keep Awake directly hear its change.
    func clockDidChange() {
        try? keepAwake.reconcile()
        PresentationRevision.shared.bump()
        keepAwake.objectWillChange.send()
    }
    private var externalChanges: UInt64 = 0
    @ObservationIgnored private let changeSignal = PassthroughSubject<Void, Never>()
    /// Every tracked stored property, plus the two preference-backed choices. `ModelObservationTests` checks it against
    /// the model's tracked storage, so a new property cannot silently escape the change signal.
    static let trackedKeyPaths: [PartialKeyPath<TilveroModel>] = [
        \.updatePreparationActive, \.snapshot, \.control, \.draftText, \.isApplying, \.storeError, \.history,
        \.historySummary, \.historyStorage, \.historyLoading, \.sleepSessions, \.processActivity,
        \.highCPUApplications, \.sleepActivity, \.isLowPowerModeEnabled, \.systemChargeLimit,
        \.isReadingSystemChargeLimit, \.sleepReportError, \.isReadingSleepActivity, \.overviewPreferences,
        \.modeLibrary, \.modeReport, \.selectedMode, \.language, \.temperatureUnit, \.weeklyCapacity, \.historyEnabled,
        \.retentionDays, \.displayStyle, \.awakeIndicatorColor, \.menuBarBatteryAppearance, \.menuBarTextSize,
        \.menuBarIconScale, \.loginStatus, \.hasReviewedSetup, \.demoPercent, \.demoExternal, \.demoOverride,
        \.scheduleDate, \.scheduleProfileName, \.schedule, \.exportPreview, \.sleepTimerMinutes,
        \.sleepTimerUsesCustom, \.keepAwakeDraft, \.keepAwakeUsesCustomDuration, \.keepAwakeCustomMinutes,
        \.privilegedPermissions, \.isReading, \.sleeping, \.externalChanges, \.keepAwakeChanges, \.sleepTimerChanges,
        \.sleepAtChargeChanges, \.keepAwakeUntilChargeChanges, \.lidSleepChanges, \.lidComfortChanges,
        \.nativeChargeChanges, \.chargeOnceChanges, \.chargeByChanges, \.liveControlChanges, \.optimizedChargingChanges,
        \.sleepAtChargeChoice, \.keepAwakeUntilChargeChoice
    ]
    /// Armed at the end of `init` and re-armed on a fresh main-actor turn, never inside the change that fired it: a
    /// change can happen while a view body is evaluated, and tracking started there would be merged into that body's
    /// own dependencies (every model property). The re-arm is queued before the signal goes out, so it runs before any
    /// work a listener schedules in response; a change in between is therefore still seen by that work.
    private func trackChanges() {
        withObservationTracking { [self] in
            for keyPath in Self.trackedKeyPaths { _ = self[keyPath: keyPath] }
            _ = notices.notices
            _ = navigation.section; _ = navigation.settingsPage; _ = navigation.sleepPage
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor [weak self] in self?.trackChanges() }
                self.changeSignal.send()
            }
        }
    }
    /// The quick menu's preset pills (`quickPresets.v1`), separate from the Overview blocks' layout.
    let quickPresets: QuickPresetStore
    var overviewPreferences: OverviewPreferences { didSet {
        if let data = try? JSONEncoder().encode(overviewPreferences) { preferences.set(data, forKey: "overviewPreferences.v1") }
        processScanSurfacesChanged()
    } }
    /// First run only: gives a brand-new install the starter Overview. Nothing happens when a layout is already
    /// stored (the user customised it, or an earlier first run wrote it) or in demo.
    @discardableResult func applyFirstRunOverviewLayout() -> Bool {
        guard !isDemo, preferences.object(forKey: "overviewPreferences.v1") == nil else { return false }
        overviewPreferences = .firstRunDefault
        return true
    }
    private(set) var modeLibrary: ModeLibrary
    private(set) var modeReport: ModeApplicationReport?
    var selectedMode: WorkMode = .economy
    var language: String { didSet {
        preferences.set(language, forKey: "language")
        PresentationRevision.shared.bump()   // every view showing localized text re-renders in the new language
        onPresentationChange?()
    } }
    /// System (default), Celsius or Fahrenheit. Views read `fahrenheit`; it follows this setting.
    var temperatureUnit: TemperatureUnitSetting { didSet { preferences.set(temperatureUnit.rawValue, forKey: "temperatureUnit") } }
    var fahrenheit: Bool { temperatureUnit.usesFahrenheit() }
    private(set) var weeklyCapacity: WeeklyCapacity?
    var historyEnabled: Bool { didSet {
        if !historyEnabled { weeklyCapacity = nil }
        preferences.set(historyEnabled, forKey: "historyEnabled")
        let boundary = Date()   // when the switch happened, not when the queue gets to it
        historyWork { [weak self] store in
            do { try await store.markGap(reason: .explicitBoundary, at: boundary) } catch { self?.storeError = HistoryStoreErrorText.text(error) }
        }
        lastPersisted = nil
        resetSleepObservation(reason: .historyDisabled, persist: !historyEnabled)
    } }
    var retentionDays: Int { didSet { preferences.set(retentionDays, forKey: "retentionDays"); configureRetention() } }
    var displayStyle: MenuBarDisplayStyle {
        didSet { preferences.set(displayStyle.rawValue, forKey: "menuBarDisplayStyle"); onPresentationChange?() }
    }
    var awakeIndicatorColor: AwakeIndicatorColor {
        didSet { preferences.set(awakeIndicatorColor.rawValue, forKey: "awakeIndicatorColor"); onPresentationChange?() }
    }
    /// The placement the menu bar shows and the pickers select: `displayStyle` resolved for the battery appearance.
    var shownDisplayStyle: MenuBarDisplayStyle {
        get { displayStyle.effective(for: menuBarBatteryAppearance) }
        set { displayStyle = newValue }
    }
    var menuBarBatteryAppearance: MenuBarBatteryAppearance {
        didSet { preferences.set(menuBarBatteryAppearance.rawValue, forKey: "menuBarBatteryAppearance"); onPresentationChange?() }
    }
    var menuBarTextSize: MenuBarTextSize {
        didSet { preferences.set(menuBarTextSize.rawValue, forKey: "menuBarTextSize"); onPresentationChange?() }
    }
    private(set) var menuBarIconScale: Double
    var loginStatus = "Not enabled"
    private(set) var hasReviewedSetup: Bool
    let canShowSetup: Bool
    private let setupBundle: Bundle
    private let setupLogin: SetupLoginPort?
    private let setupUsesNativeHost: Bool
    @ObservationIgnored lazy var setupCoordinator = SetupActionCoordinator(ports: .init(
        readInputs: { [weak self] in
            guard let self else { return SetupReadinessInputs(launchPolicy: .monitoringOnly) }
            // The backlight is otherwise read only when the quick menu opens, so Setup right after a quiet launch said "unknown".
            // This is the same read-only status read; nothing is written.
            if self.canShowSetup, self.keyboardBacklight.availability == .unknown { await self.keyboardBacklight.refresh() }
            return self.readSetupInputs()
        },
        viewRequirements: { [weak self] in try self?.showSetupRequirements($0) },
        openApprovalSettings: { [weak self] in try self?.openSetupApprovalSettings($0) },
        registerHelper: { [weak self] in try await self?.registerSetupHelper() },
        enableLogin: { [weak self] in try self?.enableSetupLogin() },
        setHistoryEnabled: { [weak self] enabled in
            guard let self, self.canShowSetup else { throw SetupRuntimeError.actionUnavailable }
            if self.historyEnabled != enabled { self.historyEnabled = enabled }
        },
        requestNativeChargeValidation: { throw SetupRuntimeError.actionUnavailable }))

    func markSetupReviewed() {
        guard canShowSetup, !hasReviewedSetup else { return }
        preferences.set(true, forKey: SetupRuntime.reviewedKey)
        hasReviewedSetup = true
    }
    var demoPercent = 76.0
    var demoExternal = true
    var demoOverride = false
    var scheduleDate = Date().addingTimeInterval(3600)
    var scheduleProfileName = "At desk"
    private(set) var schedule: ScheduleRule?
    var exportPreview: String?
    @ObservationIgnored private var exportData: Data?
    @ObservationIgnored private var exportType: UTType = .json
    var keepAwake: KeepAwakeService { _ = keepAwakeChanges; return keepAwakeStorage }
    @ObservationIgnored private let keepAwakeStorage: KeepAwakeService
    private var keepAwakeChanges: UInt64 = 0
    var sleepTimer: SleepTimerService { _ = sleepTimerChanges; return sleepTimerStorage }
    @ObservationIgnored private let sleepTimerStorage: SleepTimerService
    private var sleepTimerChanges: UInt64 = 0
    var sleepAtCharge: SleepAtChargeService { _ = sleepAtChargeChanges; return sleepAtChargeStorage }
    @ObservationIgnored private let sleepAtChargeStorage: SleepAtChargeService
    private var sleepAtChargeChanges: UInt64 = 0
    /// "Keep awake until the charge drops to N %": the same mechanism, but at the level the hold is only released.
    var keepAwakeUntilCharge: SleepAtChargeService { _ = keepAwakeUntilChargeChanges; return keepAwakeUntilChargeStorage }
    @ObservationIgnored private let keepAwakeUntilChargeStorage: SleepAtChargeService
    private var keepAwakeUntilChargeChanges: UInt64 = 0
    @ObservationIgnored private var keepAwakeUntilChargeSubscription: AnyCancellable?
    /// Last chosen "sleep at charge" level (the switch re-arms it); arming itself is never persisted.
    var sleepAtChargeChoice: Int {
        get {
            access(keyPath: \.sleepAtChargeChoice)
            return Self.rememberedLevel(preferences, key: "sleepAtChargeTarget", listed: quickPresets.presets.sleepAtCharge)
        }
        set { withMutation(keyPath: \.sleepAtChargeChoice) { preferences.set(newValue, forKey: "sleepAtChargeTarget") } }
    }
    var keepAwakeUntilChargeChoice: Int {
        get {
            access(keyPath: \.keepAwakeUntilChargeChoice)
            return Self.rememberedLevel(preferences, key: "keepAwakeUntilChargeTarget", listed: quickPresets.presets.awakeUntilCharge)
        }
        set { withMutation(keyPath: \.keepAwakeUntilChargeChoice) { preferences.set(newValue, forKey: "keepAwakeUntilChargeTarget") } }
    }
    /// The remembered level while it is listed. A level no longer listed (the stored choice is kept) gives the highest
    /// listed level, so the switch's fallback picks the highest listed level below the charge.
    static func rememberedLevel(_ preferences: UserDefaults, key: String, listed: [Int]) -> Int {
        let saved = preferences.object(forKey: key) == nil ? 20 : preferences.integer(forKey: key)
        return listed.contains(saved) ? saved : listed.first ?? 20
    }
    @ObservationIgnored private var sleepAtChargeSubscription: AnyCancellable?

    /// The four modes that keep the Mac awake until some condition: only one may run at a time.
    enum AwakeMode: String, CaseIterable {
        case keepAwake, sleepTimer, sleepAtCharge, keepAwakeUntilCharge
        var title: String {
            switch self {
            case .keepAwake: L10n.text("Keep Awake")
            case .sleepTimer: L10n.text("Sleep timer")
            case .sleepAtCharge: L10n.text("Sleep at charge")
            case .keepAwakeUntilCharge: L10n.text("Keep awake until charge")
            }
        }
    }
    func isRunning(_ mode: AwakeMode) -> Bool {
        switch mode {
        case .keepAwake: keepAwake.hasOwnedAssertion
        case .sleepTimer: sleepTimer.isActive
        case .sleepAtCharge: sleepAtCharge.isArmed
        case .keepAwakeUntilCharge: keepAwakeUntilCharge.isArmed
        }
    }
    /// Title of a running mode other than `mode`, or nil when `mode` may start.
    func awakeModeBlocker(for mode: AwakeMode) -> String? {
        AwakeMode.allCases.first { $0 != mode && isRunning($0) }?.title
    }
    var chargeModeActive: Bool { sleepAtCharge.isArmed || keepAwakeUntilCharge.isArmed }
    let closedLid: ClosedLidService
    /// Ordinary builds: closed-lid Keep Awake through the `pmset disablesleep` override (trial/lab builds keep `closedLid`).
    var lidSleep: LidSleepOverrideService { _ = lidSleepChanges; return lidSleepStorage }
    @ObservationIgnored private let lidSleepStorage: LidSleepOverrideService
    private var lidSleepChanges: UInt64 = 0
    /// Brightness and volume while the lid is closed under the lid override (restored before the override is released).
    var lidComfort: LidComfortService { _ = lidComfortChanges; return lidComfortStorage }
    @ObservationIgnored private let lidComfortStorage: LidComfortService
    private var lidComfortChanges: UInt64 = 0
    @ObservationIgnored private var lidComfortSubscription: AnyCancellable?
    @ObservationIgnored private var lidSleepSubscription: AnyCancellable?
    @ObservationIgnored private var sleepTimerSubscription: AnyCancellable?
    var sleepTimerMinutes: String { didSet {
        if let value = SleepTimerInput.minutes(sleepTimerMinutes) { preferences.set(value, forKey: "sleepTimerMinutes") }
    } }
    var sleepTimerUsesCustom = false
    var sleepTimerBlocksControls: Bool { sleepTimer.isActive && !sleepTimer.isEditable }
    private var controlsAreSuspended: Bool { sleepTimerBlocksControls || updatePreparationActive }
    var canStartSleepTimer: Bool {
        sleepTimer.canStart && SleepTimerInput.minutes(sleepTimerMinutes) != nil
            && !isApplying && !sleeping && !updatePreparationActive
    }
    var canSelectSleepTimerDuration: Bool {
        !isApplying && !sleeping && !controlsAreSuspended && !chargeModeActive && (sleepTimer.canStart || sleepTimer.isEditable)
    }
    func startSleepTimer(replacingAwake: Bool = false) throws {
        guard canStartSleepTimer, let minutes = SleepTimerInput.minutes(sleepTimerMinutes) else { throw SleepTimerInputError.invalid }
        try selectSleepTimer(minutes: minutes, replacingAwake: replacingAwake)
    }
    func selectSleepTimer(minutes: Int, replacingAwake: Bool = false) throws {
        guard (1...1440).contains(minutes), !isApplying, !sleeping, !controlsAreSuspended,
              sleepTimer.canStart || sleepTimer.isEditable else { throw SleepTimerInputError.invalid }
        if chargeModeActive { throw SleepTimerInputError.conflictingMode }
        if keepAwake.hasOwnedAssertion {
            guard replacingAwake else { throw SleepTimerInputError.conflictingMode }
            // Make before break: a failed timer start must not also end the running Keep Awake.
            try sleepTimer.selectDuration(minutes: minutes)
            sleepTimerMinutes = String(minutes)
            do {
                try keepAwake.stop()
                guard !keepAwake.hasOwnedAssertion else { throw SleepTimerInputError.conflictingMode }
            } catch { sleepTimer.cancel(); throw error }
            return
        }
        try sleepTimer.selectDuration(minutes: minutes)
        sleepTimerMinutes = String(minutes)
    }
    @ObservationIgnored private var awakeSubscription: AnyCancellable?
    @ObservationIgnored private var awakeMessageSubscription: AnyCancellable?
    /// True while the newest notice is only a copy of the native charge status line (for example the pending lower limit).
    /// It belongs to the Charge page; other quick-menu tabs must not print it.
    var noticeIsNativeChargeStatus: Bool { notices.current()?.source == .chargeStatus }
    /// An action's notice describes the page it was raised on. Leaving that page drops it, so it never trails the user
    /// onto an unrelated tab. A Keep Awake failure is the exception: it stays visible on every tab until it is resolved.
    func dismissActionNotice() { notices.clearPageNotices() }
    var keepAwakeDraft: KeepAwakeDraft { didSet {
        if case .duration(let duration) = keepAwakeDraft {
            preferences.set(duration.rawValue, forKey: "keepAwakeMinutes")
        }
    } }
    var keepAwakeUsesCustomDuration = false
    var keepAwakeCustomMinutes: String { didSet {
        if keepAwakeUsesCustomDuration, let minutes = Int(keepAwakeCustomMinutes),
           let duration = KeepAwakeDuration(rawValue: minutes) { keepAwakeDraft = .duration(duration) }
    } }
    var keepAwakeDuration: KeepAwakeDuration {
        get {
            if case .duration(let duration) = keepAwakeDraft { return duration }
            return KeepAwakeDuration.load(preferences.object(forKey: "keepAwakeMinutes"))
        }
        set {
            keepAwakeUsesCustomDuration = !quickPresets.presets.keepAwake.contains(newValue.rawValue)
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
    var sleepPillActionsAllowed: Bool { !sleeping && !isApplying && !controlsAreSuspended }
    var canStartKeepAwakeDraft: Bool {
        guard !updatePreparationActive, keepAwake.isAvailable, !keepAwake.hasOwnedAssertion, !chargeModeActive else { return false }
        switch keepAwakeDraft {
        case .duration:
            return !keepAwakeUsesCustomDuration || Int(keepAwakeCustomMinutes).flatMap(KeepAwakeDuration.init(rawValue:)) != nil
        case .until(let date): return date.timeIntervalSinceNow > 0 && date.timeIntervalSinceNow <= 86_400
        case .untilStopped: return true
        }
    }
    func startKeepAwakeDraft(replacingSleepTimer: Bool = false) throws {
        guard !controlsAreSuspended, !chargeModeActive else { throw SleepTimerInputError.conflictingMode }
        if sleepTimer.isActive && !replacingSleepTimer { throw SleepTimerInputError.conflictingMode }
        switch keepAwakeDraft {
        case .duration(let duration):
            if keepAwakeUsesCustomDuration {
                guard let minutes = Int(keepAwakeCustomMinutes), let custom = KeepAwakeDuration(rawValue: minutes) else { throw KeepAwakeError.invalidDuration }
                try keepAwake.start(seconds: custom.seconds)
            } else { try keepAwake.start(seconds: duration.seconds) }
        case .until(let date): try keepAwake.start(until: date)
        case .untilStopped: try keepAwake.startUntilStopped()
        }
        // Acquisition is synchronous and verified. A failed start retains the old timer.
        if sleepTimer.isActive { sleepTimer.cancel() }
    }
    var nativeCharge: NativeChargeService { _ = nativeChargeChanges; return nativeChargeStorage }
    @ObservationIgnored private let nativeChargeStorage: NativeChargeService
    private var nativeChargeChanges: UInt64 = 0
    var chargeOnce: ChargeOnceStore { _ = chargeOnceChanges; return chargeOnceStorage }
    @ObservationIgnored private let chargeOnceStorage: ChargeOnceStore
    private var chargeOnceChanges: UInt64 = 0
    var chargeBy: ChargeByService { _ = chargeByChanges; return chargeByStorage }
    @ObservationIgnored private let chargeByStorage: ChargeByService
    private var chargeByChanges: UInt64 = 0
    @ObservationIgnored private var chargeByTicker: ChargeByTicker?
    @ObservationIgnored private var chargeByEnvironment: ModelChargeByEnvironment?
    let keyboardBacklight: KeyboardBacklightService
    var optimizedCharging: OptimizedChargingService { _ = optimizedChargingChanges; return optimizedChargingStorage }
    @ObservationIgnored private let optimizedChargingStorage: OptimizedChargingService
    private var optimizedChargingChanges: UInt64 = 0
    @ObservationIgnored private var optimizedChargingSubscription: AnyCancellable?
    /// Optimized Battery Charging as one value for every read-only place: the switch's own read, else the native limit read.
    var optimizedChargingEnabled: Bool? {
        optimizedCharging.state?.enabled ?? nativeCharge.nativeSetting.flatMap { $0.isFresh ? $0.configuration.optimizedCharging : nil }
    }
    @ObservationIgnored private var nativeSubscription: AnyCancellable?
    @ObservationIgnored private var nativeMessageSubscription: AnyCancellable?
    var liveControl: LiveControlService { _ = liveControlChanges; return liveControlStorage }
    @ObservationIgnored private let liveControlStorage: LiveControlService
    private var liveControlChanges: UInt64 = 0
    @ObservationIgnored private var liveSubscription: AnyCancellable?
    @ObservationIgnored private var chargeOnceSubscription: AnyCancellable?
    @ObservationIgnored private var chargeBySubscription: AnyCancellable?
    let isDemo: Bool
    let launchPolicy: AppLaunchPolicy
    /// Features still in development (the Modes tab, "Profiles & schedules"): debug and laboratory builds only, the same
    /// flag as `QuickPanelSection.showsDevelopmentSections`. Off in a release, where a saved schedule never fires either.
    let developmentFeatures: Bool
    /// What this build shows (resolved once at launch; the quick menu and the window read the same value).
    let features: FeatureFlags
    @ObservationIgnored var isPopoverVisible = false { didSet { if oldValue != isPopoverVisible { updateLiveCharts() } } }
    /// The quick panel's page (reported by the panel itself): live charts run only on Overview.
    @ObservationIgnored var quickPanelSection: QuickPanelSection = .overview { didSet { if oldValue != quickPanelSection { updateLiveCharts() } } }
    @ObservationIgnored var isDetailVisible = false { didSet {
        guard isDetailVisible != oldValue else { return }
        processScanSurfacesChanged()
        if isDetailVisible { activityPageMayHaveAppeared() }
        updateLiveCharts()
    } }
    /// Settings > Setup: the administrator permissions (nil in demo, monitoring-only and test sessions).
    var privilegedPermissions: PrivilegedPermissionsController?
    @ObservationIgnored var onPresentationChange: (@MainActor () -> Void)?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    /// Follow-up work the model starts on its own: the post-wake and queued refreshes, the power-source refresh, the
    /// wake re-read after the settle window, the Activity scan, the sleep-assertion read and raw inspection. `stop()`
    /// cancels all of it (each keeps its own epoch guard). Control writes (apply, restore, sleep preparation, lid
    /// recovery) are never in here: they always run to their end.
    @ObservationIgnored private var ownedTasks: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var ownedTaskSerial: UInt64 = 0
    /// The store's background backfill and weekly VACUUM (detached; `stop()` cancels them before closing the store).
    @ObservationIgnored private var backfillTask: Task<Void, Never>?
    @ObservationIgnored private var vacuumTask: Task<Void, Never>?
    /// Model-owned tasks still running (tests).
    var ownedTaskCount: Int { ownedTasks.count }
    /// Between `stop()` and the next `start()`: no refresh and no new follow-up task begins, so work still in flight
    /// at `stop()` (a refresh awaiting its reading) cannot schedule more.
    @ObservationIgnored private var isStopped = false
    @discardableResult
    private func ownTask(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard !isStopped else { return nil }
        ownedTaskSerial &+= 1
        let id = ownedTaskSerial
        let task = Task { @MainActor [weak self] in
            if !Task.isCancelled { await operation() }
            self?.ownedTasks[id] = nil
        }
        ownedTasks[id] = task
        return task
    }
    /// Tracked: derived properties views read (`updateReadiness`, Setup) depend on it.
    private var isReading = false
    @ObservationIgnored private var lifecycleEpoch: UInt64 = 0
    @ObservationIgnored private var queuedWakeRefresh = false
    @ObservationIgnored private var observedWake = false
    private let sleepRunID = UUID()
    private let postWakeSettleSeconds: Double
    @ObservationIgnored private var sleepTracker: SleepSessionTracker
    @ObservationIgnored private var lastRawSleepEndpoint: SleepBatteryEndpoint?
    private let sleepActivityProvider: @Sendable () async -> SleepAssertionSnapshot
    /// Tracked: `canStartSleepTimer`, `sleepPillActionsAllowed` and the live charts depend on it.
    private var sleeping = false
    @ObservationIgnored private var draftDirty = false
    @ObservationIgnored private var lastPersisted: BatterySnapshot?
    @ObservationIgnored private var inspectedRaw: [CatalogReading] = []
    @ObservationIgnored private var simulator: SimulationController?
    @ObservationIgnored private var store: BatteryHistoryStore?
    /// History work runs off the main actor (the store serialises it on its own queue). This chain keeps the model's
    /// multi-step operations (open → first loads, record → reload, erase → reload) in the order they were requested.
    @ObservationIgnored private var historyChain: Task<Void, Never>?
    @ObservationIgnored private var historyStopped = false
    /// Bumped by an erase: loads that began before it cannot publish pre-erase rows.
    @ObservationIgnored private var historyEpoch: UInt64 = 0
    /// Sleep reports handed to the store and not yet written; `stop()` writes whatever the queue has not reached.
    @ObservationIgnored private var unsavedSleepRecords: [SleepSessionRecord] = []
    private let observer = PowerSourceObserver()
    @ObservationIgnored private var arbiter = ProfileArbiter()
    private let preferences: UserDefaults
    private let sideEffects: TilveroModelSideEffects
    @ObservationIgnored private var snapshotProvider: @Sendable () async -> BatterySnapshot

    init(isDemo: Bool, launchPolicy: AppLaunchPolicy = .current(), preferences: UserDefaults = .standard,
         historyURL: URL? = nil,
         postWakeSettleSeconds: Double = 5,
         snapshotProvider: (@Sendable () async -> BatterySnapshot)? = nil,
         sleepActivityProvider: (@Sendable () async -> SleepAssertionSnapshot)? = nil,
         systemChargeLimitProvider: (@Sendable (_ maximumAge: TimeInterval) async -> SystemChargeLimitObservation)? = nil,
         liveControl: LiveControlService? = nil,
         nativeCharge: NativeChargeService? = nil,
         keepAwakeTransport: (any KeepAwakeTransport)? = nil,
         keepAwakeService: KeepAwakeService? = nil,
         processActivityProvider: (@Sendable () async -> ProcessResourceCollection)? = nil,
         keyboardBacklight: KeyboardBacklightService? = nil,
         optimizedCharging: OptimizedChargingService? = nil,
         sleepTimerTransport: (any SleepTimerTransport)? = nil,
         sleepTimerService: SleepTimerService? = nil,
         closedLidService: ClosedLidService? = nil,
         lidSleepSystem: (any LidSleepSystem)? = nil,
         lidComfortService: LidComfortService? = nil,
         liveSampler: (@Sendable () -> LivePowerSample?)? = nil,
         updateIdentity: UpdateIdentity? = nil,
         updateEvidence: (() -> [UpdateEvidenceProbe.Result])? = nil,
         updateLeaseDirectory: URL? = nil,
         sideEffects: TilveroModelSideEffects? = nil,
         setupBundle: Bundle = .main,
         developmentFeatures: Bool = QuickPanelSection.showsDevelopmentSections,
         newWindow: Bool? = FeatureFlags.newWindowOverride(),
         lowPowerMode: (@Sendable () -> Bool)? = nil) {
        updates = UpdateCheckService(identity: updateIdentity ?? .current(), defaults: preferences)
        self.updateLeaseDirectory = updateLeaseDirectory
        self.updateEvidence = updateEvidence ?? {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Tilvero", isDirectory: true)
            let paths = [root.appendingPathComponent("native-charge-session.json"),
                         root.appendingPathComponent("Production/native-charge-session.json"),
                         root.appendingPathComponent("Laboratory/native-charge-session.json"),
                         root.appendingPathComponent("LidTrial/native-charge-session.json"),
                         URL(fileURLWithPath: "/Library/Application Support/Tilvero"),
                         URL(fileURLWithPath: "/Library/Application Support/TilveroClosedLidLab")]
            return paths.map(UpdateEvidenceProbe.inspect)
        }
        self.systemChargeLimitProvider = systemChargeLimitProvider ?? { maximumAge in
            await Task.detached(priority: .utility) { SystemChargeLimitObservation.read(maximumAge: maximumAge) }.value
        }
        self.isDemo = isDemo
        self.launchPolicy = launchPolicy
        self.developmentFeatures = developmentFeatures
        self.lowPowerModeReader = lowPowerMode ?? { ProcessInfo.processInfo.isLowPowerModeEnabled }
        let processes = ProcessActivityProvider()   // one provider: it keeps process identities between scans
        self.processActivityProvider = processActivityProvider ?? { await processes.read() }
        self.preferences = preferences
        quickPresets = QuickPresetStore(defaults: preferences)
        navigation = AppNavigation(preferences: preferences)
        chargeOnceStorage = ChargeOnceStore(preferences: preferences)
        chargeByStorage = ChargeByService(defaults: preferences, wake: isDemo || launchPolicy.monitoringOnly ? DisabledWakeScheduler() : NativeWakeScheduler())
        self.postWakeSettleSeconds = postWakeSettleSeconds
        self.sleepTracker = SleepSessionTracker(postWakeSettleSeconds: postWakeSettleSeconds)
        self.sideEffects = sideEffects ?? .native
        let savedSleepMinutes = preferences.integer(forKey: "sleepTimerMinutes")
        let initialSleepMinutes = (1...1440).contains(savedSleepMinutes) ? savedSleepMinutes : 30
        sleepTimerMinutes = String(initialSleepMinutes)
        sleepTimerUsesCustom = !quickPresets.presets.sleepTimer.contains(initialSleepMinutes)
        let savedAwakeDuration = KeepAwakeDuration.load(preferences.object(forKey: "keepAwakeMinutes"))
        keepAwakeDraft = .duration(savedAwakeDuration)
        keepAwakeCustomMinutes = String(savedAwakeDuration.rawValue)
        keepAwakeUsesCustomDuration = !quickPresets.presets.keepAwake.contains(savedAwakeDuration.rawValue)
        let monitoring = launchPolicy.monitoringOnly
        let hardwarePolicy = launchPolicy.ordinaryHardwarePolicy
        self.keyboardBacklight = keyboardBacklight ?? KeyboardBacklightService(
            storage: UserDefaultsKeyboardBacklightStorage(defaults: preferences), allowed: !isDemo && !hardwarePolicy.monitoringOnly)
        // The live PowerUI client only inside the shipping app bundle: a test runner or the Lab Studio never reaches it.
        #if TILVERO_LAB_STUDIO
        let optimizedTransport: any OptimizedChargingTransport = UnavailableOptimizedChargingTransport()
        #else
        let optimizedTransport: any OptimizedChargingTransport = Bundle.main.bundleURL.pathExtension == "app"
            ? PowerUIOptimizedChargingClient() : UnavailableOptimizedChargingTransport()
        #endif
        self.optimizedChargingStorage = optimizedCharging ?? OptimizedChargingService(transport: optimizedTransport, allowed: !isDemo && !monitoring)
        keepAwakeStorage = keepAwakeService ?? KeepAwakeService(driver: keepAwakeTransport ?? NativeKeepAwakeTransport(), allowed: !isDemo && !monitoring)
        let sleepTransport = sleepTimerTransport ?? NativeSleepTimerTransport()
        sleepTimerStorage = sleepTimerService ?? SleepTimerService(driver: sleepTransport, allowed: !isDemo && !monitoring)
        // Its own idle hold, independent of the timer's (a real run gets a separate transport instance).
        sleepAtChargeStorage = SleepAtChargeService(driver: sleepTimerTransport ?? NativeSleepTimerTransport(), allowed: !isDemo && !monitoring)
        keepAwakeUntilChargeStorage = SleepAtChargeService(driver: sleepTimerTransport ?? NativeSleepTimerTransport(), allowed: !isDemo && !monitoring, endAction: .release)
        closedLid = closedLidService ?? ClosedLidService(allowed: !isDemo && !monitoring)
        // The real system gets the real watchdog; demo, monitoring-only (also the first-run preview) and an injected
        // (fake) system get an inert one, and a native system outside an app bundle (a test runner) gets none at all.
        let lidRoute = Self.lidSleepRoute(isDemo: isDemo, monitoringOnly: monitoring, injectedSystem: lidSleepSystem != nil,
                                          appBundle: Bundle.main.bundleURL.pathExtension == "app", historyURL: historyURL)
        lidSleepStorage = LidSleepOverrideService(system: lidSleepSystem ?? NativeLidSleepSystem(), defaults: preferences, allowed: !isDemo && !monitoring,
                                           markers: LidOverrideMarkerStore(directory: lidRoute.markerDirectory), watchdog: lidRoute.watchdog,
                                           observesSystemSleep: lidRoute.observesSystemSleep)
        // A test that injects its own lid system gets a disabled comfort service. Even a native one never writes unless
        // a real lid override is armed (display and audio are only touched at lid close).
        lidComfortStorage = lidComfortService ?? LidComfortService(defaults: preferences, allowed: !isDemo && !monitoring && lidSleepSystem == nil)
        self.setupBundle = setupBundle
        let setupIdentity = try? ReleaseIdentity.current(bundle: setupBundle)
        canShowSetup = !isDemo && setupIdentity?.isLaboratory == false && !closedLid.isFixture && !closedLid.isLiveTrial
        hasReviewedSetup = canShowSetup && preferences.bool(forKey: SetupRuntime.reviewedKey)
        features = FeatureFlags.resolve(development: developmentFeatures, isDemo: isDemo, canShowSetup: canShowSetup,
                                        newWindowOverride: newWindow)
        let ordinaryAppID = setupBundle.bundleIdentifier == ReleaseIdentity.prototypeBundleIdentifier
            || setupBundle.bundleIdentifier == UpdateInstallConfiguration.productionBundleID
        let nativeSetupHost = canShowSetup && sideEffects == nil && ordinaryAppID
            && setupBundle.bundleURL.pathExtension == "app" && setupBundle.bundleURL == Bundle.main.bundleURL
        setupUsesNativeHost = nativeSetupHost
        setupLogin = sideEffects?.setupLogin ?? (nativeSetupHost ? .native : nil)
        modeLibrary = ModeLibrary.load(preferences.data(forKey: isDemo ? "demoModePlans.v1" : "modePlans.v1"))
        overviewPreferences = OverviewPreferences.load(preferences.data(forKey: "overviewPreferences.v1"))
        self.sleepActivityProvider = sleepActivityProvider ?? {
            await SleepActivityProvider().readSnapshot()
        }
        self.liveControlStorage = liveControl ?? LiveControlService(preferences: preferences,
            launchPolicy: isDemo ? .resolve(metadata: [:], arguments: ["--demo"]) : hardwarePolicy)
        if let nativeCharge { self.nativeChargeStorage = nativeCharge }
        else if isDemo {
            self.nativeChargeStorage = NativeChargeService(client: NativeChargeService.liveTransport(),
                journalURL: FileManager.default.temporaryDirectory.appendingPathComponent("TilveroDemo-\(UUID().uuidString)/native-session.json"), monitoringOnly: true)
        } else {
            let storage = historyURL ?? (try? ReleaseIdentity.current().historyURL()) ?? FileManager.default.temporaryDirectory.appendingPathComponent("TilveroUnavailable/History.sqlite")
            self.nativeChargeStorage = NativeChargeService(historyURL: storage, launchPolicy: hardwarePolicy)
        }
        let identitySalt = preferences.string(forKey: "identitySalt") ?? UUID().uuidString
        preferences.set(identitySalt, forKey: "identitySalt")
        let provider = MacBatteryProvider(identitySalt: identitySalt)
        self.snapshotProvider = snapshotProvider ?? { await Task.detached(priority: .utility) { provider.readSnapshot() }.value }
        snapshot = isDemo ? .demo() : .unavailable(reason: "Waiting for first reading")
        language = preferences.string(forKey: "language") ?? "system"
        temperatureUnit = TemperatureUnitSetting.load(from: preferences)
        historyEnabled = preferences.object(forKey: "historyEnabled") as? Bool ?? true
        retentionDays = preferences.object(forKey: "retentionDays") as? Int ?? 30
        menuBarTextSize = MenuBarTextSize(rawValue: preferences.string(forKey: "menuBarTextSize") ?? "") ?? .system
        menuBarIconScale = MenuBarSizing.validatedIconScale(preferences.object(forKey: "menuBarIconScale") as? Double ?? 1)
        let batteryAppearance = MenuBarBatteryAppearance.restored(preferences.string(forKey: "menuBarBatteryAppearance"))
        menuBarBatteryAppearance = batteryAppearance
        awakeIndicatorColor = AwakeIndicatorColor(rawValue: preferences.string(forKey: "awakeIndicatorColor") ?? "") ?? .blue
        displayStyle = MenuBarDisplayStyle(rawValue: preferences.string(forKey: "menuBarDisplayStyle") ?? "") ?? batteryAppearance.defaultDisplayStyle
        if let data = preferences.data(forKey: isDemo ? "demoSchedule" : "schedule") { schedule = try? JSONDecoder().decode(ScheduleRule.self, from: data) }
        if let data = preferences.data(forKey: isDemo ? "demoArbiter" : "arbiter"), let saved = try? JSONDecoder().decode(ProfileArbiter.self, from: data) { arbiter = saved }
        if isDemo {
            do { simulator = try SimulationController(savedState: preferences.data(forKey: "simulationState")) }
            catch { notices.post(L10n.text("Operation failed"), from: .control); simulator = try? SimulationController() }
        } else {
            do {
                let url = try historyURL ?? ReleaseIdentity.current().historyURL()
                openHistory(at: url)
            }
            catch { storeError = HistoryStoreErrorText.text(error) }
        }
        updateLoginStatus()
        navigation.onSectionChange = { [weak self] _, _ in
            self?.processScanSurfacesChanged(); self?.activityPageMayHaveAppeared()
        }
        closedLid.bind(keepAwake)
        lidSleep.awakeIsActive = { [weak self] in self?.keepAwake.hasOwnedAssertion ?? false }
        lidSleep.bind(keepAwake)
        // One switch for the sleep timer and Sleep at charge: the override accompanies an armed timer (armed/warning) or an
        // armed charge level, never the sleep request itself.
        lidSleep.scheduledSleepIsActive = { [weak self] in
            guard let self else { return false }
            return self.sleepTimer.phase.isEditable || self.sleepAtCharge.isArmed
        }
        lidSleep.bindTimer(phases: sleepTimer.$phase.eraseToAnyPublisher())
        lidSleep.bindSleepAtCharge(armed: sleepAtCharge.$target.map { $0 != nil }.removeDuplicates().eraseToAnyPublisher())
        lidSleepSubscription = lidSleepStorage.objectWillChange.sink { [weak self] in self?.lidSleepChanges &+= 1 }
        lidComfort.bind(lidSleep)
        self.liveSampler = liveSampler
        lidComfortSubscription = lidComfortStorage.objectWillChange.sink { [weak self] in self?.lidComfortChanges &+= 1 }
        sleepTimer.prepare = { [weak self] in
            guard let self else { return false }
            guard await self.closedLid.prepareForTermination() else { return false }
            guard await self.lidSleep.prepareForTermination() else { return false }   // a sleep request must not meet a set override
            // An earlier observation may be suspended before a native auto-action.
            // Let it finish before preparing; new auto-actions are already gated.
            let readinessDeadline = ContinuousClock.now.advanced(by: .seconds(4))
            while self.isReading || self.isApplying || self.nativeCharge.isBusy || self.nativeCharge.isQualifying || self.liveControl.isBusy {
                guard self.sleepTimer.phase == .preparing, !self.sleeping,
                      ContinuousClock.now < readinessDeadline, !Task.isCancelled else { return false }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
            }
            guard !self.sleeping, self.sleepTimer.phase == .preparing else { return false }
            return await self.liveControl.prepareForRequestedSleep()
        }
        sleepTimerSubscription = sleepTimerStorage.objectWillChange.sink { [weak self] in self?.sleepTimerChanges &+= 1 }
        sleepAtCharge.prepare = { [weak self] in
            guard let self else { return false }
            guard await self.closedLid.prepareForTermination() else { return false }
            guard await self.lidSleep.prepareForTermination() else { return false }
            let readinessDeadline = ContinuousClock.now.advanced(by: .seconds(4))
            while self.isApplying || self.nativeCharge.isBusy || self.nativeCharge.isQualifying || self.liveControl.isBusy {
                guard !self.sleeping, ContinuousClock.now < readinessDeadline, !Task.isCancelled else { return false }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
            }
            guard !self.sleeping else { return false }
            return await self.liveControl.prepareForRequestedSleep()
        }
        sleepAtCharge.blockedBy = { [weak self] in self?.awakeModeBlocker(for: .sleepAtCharge) }
        keepAwakeUntilCharge.blockedBy = { [weak self] in self?.awakeModeBlocker(for: .keepAwakeUntilCharge) }
        sleepAtCharge.levels = { [weak self] in self?.quickPresets.presets.sleepAtCharge ?? QuickPresets.defaults.sleepAtCharge }
        keepAwakeUntilCharge.levels = { [weak self] in self?.quickPresets.presets.awakeUntilCharge ?? QuickPresets.defaults.awakeUntilCharge }
        sleepAtChargeSubscription = sleepAtChargeStorage.objectWillChange.sink { [weak self] in self?.sleepAtChargeChanges &+= 1 }
        keepAwakeUntilChargeSubscription = keepAwakeUntilChargeStorage.objectWillChange.sink { [weak self] in self?.keepAwakeUntilChargeChanges &+= 1 }
        awakeSubscription = keepAwakeStorage.objectWillChange.sink { [weak self] in self?.keepAwakeChanges &+= 1 }
        awakeMessageSubscription = keepAwake.$message.sink { [weak self] message in
            guard let self else { return }
            // Safe cleanup removes the pinned session. Keep its failure visible on every tab.
            let endedFailure = self.keepAwake.hasOwnedAssertion ? nil : message.map(L10n.text)
            if let endedFailure { self.notices.post(endedFailure, from: .keepAwake) }
            else { self.notices.clear(.keepAwake) }
        }
        nativeSubscription = nativeChargeStorage.objectWillChange.sink { [weak self] in self?.nativeChargeChanges &+= 1 }
        optimizedChargingSubscription = optimizedChargingStorage.objectWillChange.sink { [weak self] in self?.optimizedChargingChanges &+= 1 }
        chargeOnceSubscription = chargeOnceStorage.objectWillChange.sink { [weak self] in self?.chargeOnceChanges &+= 1 }
        chargeBySubscription = chargeByStorage.objectWillChange.sink { [weak self] in self?.chargeByChanges &+= 1 }
        nativeMessageSubscription = self.nativeCharge.$message.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            // The pending lower-limit line was copied into the notices when the user released the slider. When the battery
            // later discharges and the service applies the limit on its own, that copy would otherwise outlive the state it described.
            self.notices.clear(.chargeStatus)
        }
        liveSubscription = liveControlStorage.objectWillChange.sink { [weak self] in
            self?.liveControlChanges &+= 1
            self?.onPresentationChange?()
        }
        if isDemo { draftText = "80" }
        else if let target = self.nativeCharge.currentReportedTarget { draftText = String(target) }
        isLowPowerModeEnabled = lowPowerModeReader()
        powerStateSubscription = NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.lowPowerModeDidChange() } }
        trackChanges()
    }
    private func lowPowerModeDidChange() {
        let enabled = lowPowerModeReader()
        if isLowPowerModeEnabled != enabled { isLowPowerModeEnabled = enabled }
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
    /// Window of every overview chart: the last hour up to the newest snapshot.
    var overviewChartWindow: ClosedRange<Date> {
        // While live points exist the window ends at the newest of them (the chart scrolls with the data); a clock that
        // jumped backwards cannot hold the end in the future.
        let end = max(snapshot.collectedAt, min(live.tail.latest ?? snapshot.collectedAt, Date().addingTimeInterval(5)))
        return end.addingTimeInterval(-3600)...end
    }
    // MARK: Live charts (about 1 Hz while a live chart is on screen; in memory only)
    /// Observed only by the chart views (`LiveRefresh`), never by the model's own subscribers.
    let live = LiveMetricStore()
    /// Surfaces that show live charts. The popover's Overview subscribes while the quick panel reports that page
    /// (`quickPanelSection`), as it always did; the details window's charts subscribe with `.liveCharts(_:surface:)`.
    enum LiveSurface: Hashable, Sendable { case popoverOverview, windowOverview }
    /// Charts on screen per window surface (reference counted: each subscribing view retains once while it is shown).
    @ObservationIgnored private var liveSubscribers: [LiveSurface: Int] = [:]
    /// A view with live charts appeared on `surface`.
    func retainLiveCharts(_ surface: LiveSurface) {
        liveSubscribers[surface, default: 0] += 1
        updateLiveCharts()
    }
    /// A view with live charts on `surface` disappeared.
    func releaseLiveCharts(_ surface: LiveSurface) {
        guard let count = liveSubscribers[surface] else { return }
        liveSubscribers[surface] = count > 1 ? count - 1 : nil
        updateLiveCharts()
    }
    /// Surfaces with a live chart that is actually visible: the popover shown on Overview, the details window on screen
    /// (a hidden, covered or closed window keeps its views but reads nothing).
    var visibleLiveSurfaces: Set<LiveSurface> {
        var surfaces: Set<LiveSurface> = []
        if isPopoverVisible && quickPanelSection == .overview { surfaces.insert(.popoverOverview) }
        if isDetailVisible && (liveSubscribers[.windowOverview] ?? 0) > 0 { surfaces.insert(.windowOverview) }
        return surfaces
    }
    @ObservationIgnored private var liveTimer: Timer?
    @ObservationIgnored private var liveReading = false
    @ObservationIgnored private var smcReader: SMCSensorReader?
    @ObservationIgnored private var liveSampler: (@Sendable () -> LivePowerSample?)?
    @ObservationIgnored private var lastWakeAt: Date?
    /// Seconds between live points (the SMC sensors change about once a second).
    static let liveInterval: TimeInterval = 1
    /// The sampler runs while at least one live chart is visible and the Mac is awake (never in the simulation).
    var wantsLiveCharts: Bool { !isDemo && !isStopped && !sleeping && !visibleLiveSurfaces.isEmpty }
    func updateLiveCharts() {
        if wantsLiveCharts {
            guard liveTimer == nil else { return }
            if liveSampler == nil, smcReader == nil { smcReader = SMCSensorReader() }
            guard liveSampler != nil || smcReader != nil else { return }
            live.clearIfStale(now: Date())
            Task { await liveTick() }
            let timer = Timer(timeInterval: Self.liveInterval, repeats: true) { [weak self] _ in Task { @MainActor in await self?.liveTick() } }
            RunLoop.main.add(timer, forMode: .common); liveTimer = timer
        } else {
            liveTimer?.invalidate(); liveTimer = nil
        }
    }
    /// One sensor read (about 1 ms, off the main actor) appended to the tail.
    func liveTick() async {
        guard wantsLiveCharts, !liveReading else { return }
        liveReading = true
        let sampler = liveSampler ?? { [reader = smcReader] in reader?.read() }
        let sample = await Task.detached(priority: .utility) { sampler() }.value
        liveReading = false
        guard wantsLiveCharts, let sample else { return }
        // A power-source change or a sleep starts a new segment; a segment continues the recorded line only when nothing
        // of that kind happened since the last recorded point.
        let boundary = "\(lifecycleEpoch)|\(String(describing: snapshot.isExternalPower.value))"
        let joins = lastPersisted.map { recorded in
            sample.collectedAt.timeIntervalSince(recorded.collectedAt) <= 120
                && recorded.isExternalPower.value == snapshot.isExternalPower.value
                && (lastWakeAt.map { $0 <= recorded.collectedAt } ?? true)
        } ?? false
        live.append(sample, boundary: boundary, adapterConnected: snapshot.adapterIsConnected, joinsRecorded: joins)
    }
    /// What a cached series depends on: the window end, how much history there is and its newest sample.
    /// `history` replaces itself wholesale (a full reload, an append after trimming the week, an erase), so the
    /// count alone could repeat with different data; its newest sample id is added to the key. The `didSet` on
    /// `history` is belt-and-braces beyond the key: stored samples are immutable, so no model API produces a
    /// replacement with the same count and newest id but different older samples, and no test can isolate it.
    private struct RecordedKey: Equatable { let collectedAt: Date; let count: Int; let lastSampleID: UUID? }
    private struct SeriesCacheKey: Equatable { let recorded: RecordedKey; let liveRevision: Int }
    @ObservationIgnored private var recordedKey: RecordedKey?
    @ObservationIgnored private var recordedCache: [String: [HistoryChartPoint]] = [:]
    @ObservationIgnored private var seriesCacheKey: SeriesCacheKey?
    @ObservationIgnored private var seriesCache: [String: MetricChartSeries] = [:]
    /// How many times a series was actually built (not read from the cache); tests assert it.
    @ObservationIgnored private(set) var metricSeriesComputations = 0
    /// How many times the recorded points of a metric were extracted from the history (a full sort); live ticks must not
    /// repeat that.
    @ObservationIgnored private(set) var recordedPointComputations = 0
    private func recordedPoints(id: String, key: RecordedKey) -> [HistoryChartPoint] {
        if key != recordedKey { recordedCache.removeAll(keepingCapacity: true); recordedKey = key }
        if let cached = recordedCache[id] { return cached }
        recordedPointComputations += 1
        // A margin beyond the hour: the window end may move ahead of the newest snapshot while live points arrive.
        let points = PowerMetricHistory.points(history, id: id, since: snapshot.collectedAt.addingTimeInterval(-3600 - 600))
        recordedCache[id] = points
        return points
    }
    /// Last-hour series of one catalog metric for the overview charts. Cards, tiles and the combined chart ask for it
    /// on every body evaluation, so it is memoised per metric until the snapshot, the history or the live tail changes.
    /// The cache is plain storage (not `@Published`): filling it never schedules a view update.
    func metricSeries(id: String) -> MetricChartSeries {
        let recordedKey = RecordedKey(collectedAt: snapshot.collectedAt, count: history.count, lastSampleID: history.last?.id)
        let key = SeriesCacheKey(recorded: recordedKey, liveRevision: live.revision)
        if key != seriesCacheKey { seriesCache.removeAll(keepingCapacity: true); seriesCacheKey = key }
        if let cached = seriesCache[id] { return cached }
        metricSeriesComputations += 1
        let window = overviewChartWindow
        var points = recordedPoints(id: id, key: recordedKey)
        let tail = live.tail.points(id: id).filter { window.contains($0.date) }
        if !tail.isEmpty { points = LiveChartMerge.merge(persisted: points, live: tail, joinable: live.tail.joinable) }
        let series = MetricChartSeries.make(points: points, window: window, now: window.upperBound)
        seriesCache[id] = series
        return series
    }
    var dischargeForecast: DischargeForecast.Estimate? {
        guard !isDemo else { return nil }
        let current = DischargeForecast.currentInputs(snapshot)
        return DischargeForecast.estimate(history.map {
            .init(date: $0.collectedAt, percent: $0.chargePercent, segment: $0.segmentID.uuidString,
                  externalPower: $0.isExternalPower, charging: $0.isCharging, monotonic: $0.monotonicTime, aggregate: $0.isAggregate)
        }, currentPercent: current.percent, currentFresh: current.fresh, onBattery: current.onBattery, now: snapshot.collectedAt,
           launches: (historySummary?.gaps ?? []).filter { $0.reason == .launch }.map { .init(start: $0.start, end: $0.end) })
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
    var canApplyProfiles: Bool { !controlsAreSuspended && (isDemo || liveControl.capabilities.contains { $0.readiness == .available }) }
    var fanObservation: FanObservation? { liveControl.fanObservation }
    var fanDescriptors: [FanDescriptor] { isDemo ? control?.fanDescriptors ?? [] : fanObservation?.descriptors ?? [] }
    var fanRPM: [String: Int] { isDemo ? control?.fans.observedRPM ?? [:] : fanObservation?.actualRPM ?? [:] }
    var fanPhase: FanPhase { isDemo ? control?.fans.phase ?? .systemAuto : liveControl.fanState.phase }
    var canControlFans: Bool { !controlsAreSuspended && (isDemo || liveControl.canFans) }
    var helperStatusText: String {
        switch liveControl.registrationState {
        case .notRegistered: L10n.text("Not enrolled")
        case .enabled: L10n.text("Enabled")
        case .requiresApproval: L10n.text("Requires approval in System Settings")
        case .notFound, .unavailable: L10n.text("Signing and hardware validation required")
        }
    }
    var draftTarget: Int? { ReadingPresentation.percentInput(draftText, acceptedTargets: acceptedTargets) }
    /// A full-charge-once request owns the policy (the simulation's one-shot, or a profile on the helper path).
    var isFullChargeOnceRequested: Bool { chargeState?.requested == .fullOnce }
    var canEdit: Bool { !controlsAreSuspended && (isDemo ? control != nil : usesNativeCharge || liveControl.canCharge) && !isApplying && !nativeCharge.isBusy && !nativeCharge.isQualifying && !liveControl.isBusy && !isFullChargeOnceRequested }
    var canPerformChargeActions: Bool { isDemo || (usesNativeCharge ? nativeCharge.canApply : liveControl.canCharge) }
    var canReleaseCharge: Bool { isDemo || nativeCharge.hasOwnedSettings || nativeCharge.pendingTarget != nil || nativeCharge.recoveryRequired || liveControl.hasOwnedSettings }
    /// Native charging never refuses a quit, so its message is not a termination reason.
    var terminationRecoveryMessage: String? { keepAwake.message.map(L10n.text) ?? lidSleep.failure ?? liveControl.message.map(L10n.text) }
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

    /// Where the closed-lid marker lives, which watchdog guards an override, and whether the system state is read for
    /// the "sleep is disabled" warning. The marker sits next to the history store of the running identity; demo runs,
    /// fake systems and test runners use a private temporary directory, so they never see or touch a real marker.
    struct LidSleepRoute {
        let markerDirectory: URL
        let watchdog: any LidWatchdogLaunching
        let observesSystemSleep: Bool
        var watchdogIsNative: Bool { watchdog is NativeLidWatchdogLauncher }
        var watchdogIsInert: Bool { watchdog is InertLidWatchdogLauncher }
    }
    static func lidSleepRoute(isDemo: Bool, monitoringOnly: Bool, injectedSystem: Bool, appBundle: Bool, historyURL: URL?,
                              identityHistoryURL: () -> URL? = { try? ReleaseIdentity.current().historyURL() }) -> LidSleepRoute {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("TilveroLidMarker-\(UUID().uuidString)", isDirectory: true)
        let watchdog: any LidWatchdogLaunching
        if isDemo || monitoringOnly || injectedSystem { watchdog = InertLidWatchdogLauncher() }
        else if appBundle { watchdog = NativeLidWatchdogLauncher() }
        else { watchdog = UnavailableLidWatchdogLauncher() }
        let directory: URL
        if isDemo { directory = temporary }
        else if let historyURL { directory = historyURL.deletingLastPathComponent() }
        else if injectedSystem || !appBundle { directory = temporary }
        else { directory = identityHistoryURL()?.deletingLastPathComponent() ?? temporary }
        return LidSleepRoute(markerDirectory: directory, watchdog: watchdog, observesSystemSleep: injectedSystem || appBundle)
    }
    func start() {
        updates.start()
        isStopped = false
        processMonitorStopped = false
        guard pollingTask == nil else { return }
        if !isDemo {
            let environment = ModelChargeByEnvironment(model: self)
            chargeByEnvironment = environment; chargeBy.environment = environment
            // A plan resumes after a relaunch (one tick now), the 20 s tick runs only while a plan exists, and a wake
            // (scheduled or not) ticks through `setSleeping`.
            let ticker = ChargeByTicker(service: chargeBy); chargeByTicker = ticker; ticker.start()
        }
        if !isDemo { Task { await lidSleep.recoverIfNeeded(); await lidComfort.recoverIfNeeded() } }
        if !isDemo {
            Task { await liveControl.start() }
            observer.start { [weak self] in self?.ownTask { [weak self] in await self?.refresh() } }
        }
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.sleeping {
                    await self.refresh()
                    await self.refreshNativeCharge()
                    await self.refreshProcessActivity()
                    // After the native read: it reuses that read's `pmset -g battlimit` answer (one launch per cycle).
                    if self.systemChargeLimit.map({ Date().timeIntervalSince($0.collectedAt) >= 30 }) ?? true {
                        await self.refreshSystemChargeLimit()
                    }
                }
                try? await Task.sleep(for: .seconds(self.isPopoverVisible || self.isDetailVisible ? 5 : 30))
            }
        }
    }
    func stop() {
        isStopped = true
        queuedWakeRefresh = false
        chargeByTicker?.stop(); chargeByTicker = nil
        liveTimer?.invalidate(); liveTimer = nil
        live.clear()
        updates.stop()
        notices.cancelExpiries()
        sleepTimer.stop()
        sleepAtCharge.stop(); keepAwakeUntilCharge.stop()
        processMonitorStopped = true; processRevision &+= 1; processSampler.reset(); processActivity = nil
        processHighlights.reset(); highCPUApplications = []
        try? keepAwake.stop()
        bufferSleepRecords(resetSleepObservation(reason: .applicationStopped, persist: true, deferWrite: true))
        pollingTask?.cancel(); pollingTask = nil; observer.stop()
        ownedTasks.values.forEach { $0.cancel() }; ownedTasks = [:]
        backfillTask?.cancel(); backfillTask = nil
        vacuumTask?.cancel(); vacuumTask = nil
        // The process may exit right after this returns: write the queued and final sleep reports and close, waiting a
        // bounded time (long store work stops at its next batch).
        historyStopped = true
        if let store {
            self.store = nil
            let records = unsavedSleepRecords
            unsavedSleepRecords = []
            do { try store.closeImmediately(upserting: records) }
            catch { sleepReportError = L10n.text("Sleep report storage is unavailable. Existing data was preserved.") }
        }
    }
    func setSleeping(_ value: Bool) {
        if value { sleepTimer.systemWillSleep(); sleepAtCharge.systemWillSleep(); keepAwakeUntilCharge.systemWillSleep() } else { sleepTimer.systemDidWake(); sleepAtCharge.systemDidWake(); keepAwakeUntilCharge.systemDidWake() }
        if !isDemo { Task { @MainActor in if value { await chargeBy.systemWillSleep() } else { await chargeBy.systemDidWake() } } }
        if value && sleeping { return }
        if !value && !sleeping && observedWake { return }
        lifecycleEpoch &+= 1
        processRevision &+= 1; processSampler.reset(); processActivity = nil; lastProcessRefreshUptime = nil
        processHighlights.reset(); highCPUApplications = []
        sleeping = value
        updateLiveCharts()
        systemChargeLimit = nil
        if value {
            observedWake = false
            if !isDemo && historyEnabled {
                saveSleepChanges(sleepTracker.accept(.willSleep(stamp: sleepStamp(), latestEndpoint: lastRawSleepEndpoint)))
            }
            if !isDemo { Task { if !(await liveControl.prepareForSleep()) { notices.post(L10n.text("Recovery required"), from: .recovery) } } }
            let sleptAt = Date()
            historyWork { [weak self] store in
                do { try await store.markGap(reason: .sleep, at: sleptAt) } catch { self?.storeError = HistoryStoreErrorText.text(error) }
            }
        } else {
            observedWake = true
            lastWakeAt = Date()
            try? keepAwake.reconcile()
            Task { await lidSleep.reconcileAfterWake() }
            lidComfort.systemDidWake()
            if !isDemo && historyEnabled { saveSleepChanges(sleepTracker.accept(.didWake(stamp: sleepStamp(), epoch: lifecycleEpoch))) }
            queuedWakeRefresh = true
            ownTask { [weak self] in await self?.refresh() }
            if !isDemo && historyEnabled {
                // The first wake read may be deferred as a possibly pre-sleep value; read once more after the settle window.
                let epoch = lifecycleEpoch
                let delay = postWakeSettleSeconds + 3
                ownTask { [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }   // cancelled by `stop()`
                    guard let self, epoch == self.lifecycleEpoch, !self.sleeping,
                          self.sleepTracker.pending?.phase == .awaitingReading else { return }
                    self.queuedWakeRefresh = true   // coalesce with a read already in flight instead of being dropped
                    await self.refresh()
                }
            }
        }
    }
    /// Scans follow the poll while processes are shown or would be the moment the popover opens: the Overview
    /// applications block is enabled (popover open or not, so it never pops in on opening), or the Activity page is on
    /// screen. Otherwise the scan runs only every two minutes (`ProcessScanCadence`).
    var processScansFollowPoll: Bool {
        visibleOverviewMetrics.contains(.applications) || (isDetailVisible && selectedSection == .activity)
    }
    func refreshProcessActivity(force: Bool = false) async {
        guard !isDemo, !sleeping, !processMonitorStopped, !isReadingProcesses else { return }
        let followsPoll = processScansFollowPoll
        let sinceLastScan = lastProcessRefreshUptime.map { ProcessInfo.processInfo.systemUptime - $0 }
        guard ProcessScanCadence.isDue(sinceLastScan: sinceLastScan, followsPoll: followsPoll, force: force) else { return }
        isReadingProcesses = true
        let revision = processRevision
        defer { isReadingProcesses = false }
        let observed = await processActivityProvider()
        guard revision == processRevision, !sleeping, !processMonitorStopped else { return }
        let activity = processSampler.accept(observed)
        processActivity = activity
        highCPUApplications = processHighlights.accept(activity, monotonic: observed.monotonic,
            maximumInterval: ProcessScanCadence.maximumInterval(previousFollowedPoll: lastScanFollowedPoll, followsPoll: followsPoll))
        lastScanFollowedPoll = followsPoll
        lastProcessRefreshUptime = ProcessInfo.processInfo.systemUptime
    }
    /// When nothing keeps scans at the poll cadence any more, the next interval may be up to two minutes long: the last
    /// scan stops counting as a poll-cadence one, so that interval is not taken for a collection gap (which would clear
    /// a high-CPU app that is still busy when the page or block comes back).
    private func processScanSurfacesChanged() {
        if !processScansFollowPoll { lastScanFollowedPoll = false }
    }
    /// The Activity page just came on screen: scan now instead of waiting for the next poll (the last scan may be two
    /// minutes old while nothing listed processes).
    private func activityPageMayHaveAppeared() {
        guard isDetailVisible, selectedSection == .activity, !isDemo else { return }
        ownTask { [weak self] in await self?.refreshProcessActivity() }
    }
    /// A read-only display sample. The normal refresh owns history and control observations.
    func readOverviewMetrics() async -> [CatalogReading]? {
        guard !isDemo, !sleeping, isDetailVisible, selectedSection == .overview else { return nil }
        let epoch = lifecycleEpoch
        let sample = await snapshotProvider()
        guard !Task.isCancelled, epoch == lifecycleEpoch, !sleeping, isDetailVisible,
              selectedSection == .overview, sample.batteryIdentityToken == snapshot.batteryIdentityToken else { return nil }
        return sample.catalog.filter { $0.id == "039" || $0.id == "054" }
    }

    func refresh() async {
        guard !isStopped else { return }
        try? keepAwake.reconcile()
        guard !isReading, !sleeping else { return }
        isReading = true
        let readEpoch = lifecycleEpoch
        defer {
            isReading = false
            if queuedWakeRefresh && !sleeping {
                queuedWakeRefresh = false
                ownTask { [weak self] in await self?.refresh() }
            }
        }
        if isDemo { await refreshSimulation() }
        else {
            let raw = await snapshotProvider()
            // Display-retained values are not new measurements. A read begun before
            // a sleep/wake/erase boundary cannot become the post-wake endpoint.
            guard readEpoch == lifecycleEpoch, !sleeping else { return }
            queuedWakeRefresh = false
            if weeklyCapacity != nil && (raw.batteryIdentityToken == nil || raw.batteryIdentityToken != snapshot.batteryIdentityToken) {
                weeklyCapacity = nil
            }
            let previousPower = snapshot.isExternalPower.value
            if historyEnabled {
                lastRawSleepEndpoint = SleepBatteryEndpoint(snapshot: raw, stamp: sleepStamp())
                if let endpoint = lastRawSleepEndpoint {
                    saveSleepChanges(sleepTracker.accept(.freshReading(endpoint: endpoint, epoch: readEpoch)))
                }
                saveSleepChanges(sleepTracker.accept(.expire(stamp: sleepStamp())))
            } else { lastRawSleepEndpoint = nil }
            snapshot = raw.retainingPreviousReadings(snapshot)
            // Detached: the safe preparation before a sleep request must not hold this refresh open.
            let observedPercent = raw.chargePercent.value
            // `raw` is a reading taken just now; live IOKit readings carry freshness .unknown, only .stale is excluded.
            let observedFresh = raw.chargePercent.availability == .available && raw.chargePercent.freshness != .stale
            let observedPower = raw.isExternalPower.availability == .available && raw.isExternalPower.freshness != .stale ? raw.isExternalPower.value : nil
            Task {
                await sleepAtCharge.observe(percent: observedPercent, fresh: observedFresh, externalPower: observedPower)
                await keepAwakeUntilCharge.observe(percent: observedPercent, fresh: observedFresh, externalPower: observedPower)
            }
            if !controlsAreSuspended { await liveControl.observe(snapshot) }
            if !controlsAreSuspended {
                await nativeCharge.observeBattery(percent: raw.chargePercent.value,
                    fresh: raw.chargePercent.availability == .available && raw.chargePercent.freshness == .fresh)
            }
            guard readEpoch == lifecycleEpoch, !sleeping else { return }
            if selectedSection == .sleep && previousPower != raw.isExternalPower.value {
                ownTask { [weak self] in await self?.refreshSleepActivity() }
            }
            if historyEnabled {
                let changed = lastPersisted.map { $0.isCharging.value != snapshot.isCharging.value || $0.isExternalPower.value != snapshot.isExternalPower.value || $0.batteryIdentityToken != snapshot.batteryIdentityToken || $0.chargePercent.availability != snapshot.chargePercent.availability } ?? true
                let due = changed || lastPersisted.map({ previous in
                    let age = snapshot.monotonicTime.flatMap { current in previous.monotonicTime.map { current - $0 } } ?? snapshot.collectedAt.timeIntervalSince(previous.collectedAt)
                    return age >= 60 || age < 0
                }) ?? true
                let observed = snapshot
                let onExternalPower = raw.isExternalPower.availability == .available && raw.isExternalPower.freshness != .stale ? raw.isExternalPower.value : nil
                let epoch = historyEpoch
                // Claimed now so the next refresh does not record the same reading again; released if the write fails.
                if due { lastPersisted = observed }
                // Not awaited: the store may still be opening, exporting or vacuuming; the menu bar, controls and the next
                // poll never wait for it. The job applies its own results once the store has answered.
                historyWork { [weak self] store in
                    guard let self else { return }
                    // A sleep, an erase or recording switched off since this reading makes it stale for history.
                    @MainActor func current() -> Bool { epoch == self.historyEpoch && readEpoch == self.lifecycleEpoch && !self.sleeping && self.historyEnabled }
                    guard current() else {
                        if self.lastPersisted == observed { self.lastPersisted = nil }
                        return
                    }
                    do {
                        if due {
                            try await store.record(observed)
                            guard current() else { return }
                            await self.loadHistory(from: store, incremental: true)
                            let capacity = try? await store.weeklyCapacity(for: raw)
                            guard current() else { return }
                            if self.weeklyCapacity != capacity { self.weeklyCapacity = capacity }
                            self.vacuumHistoryIfDue(store, onExternalPower: onExternalPower)
                        }
                        let rows = try await store.catalogReadings(at: observed.collectedAt, summaryMaxAge: 600, waitForBackfill: false)
                        guard current() else { return }
                        self.snapshot = self.snapshot.replacingCatalog(rows)
                        self.storeError = nil
                    } catch {
                        if due, self.lastPersisted == observed { self.lastPersisted = nil }
                        self.storeError = HistoryStoreErrorText.text(error)
                    }
                }
            }
        }
        snapshot = snapshot.replacingCatalog(ControlCatalog.readings(state: chargeState, capabilities: liveControl.capabilities, fans: isDemo ? nil : liveControl.fanObservation, isDemo: isDemo, connected: liveControl.connected, at: snapshot.collectedAt))
        if !inspectedRaw.isEmpty { snapshot = snapshot.replacingCatalog(inspectedRaw) }
        await evaluateSchedule()
        evaluateChargeOnce()
        onPresentationChange?()
    }
    func setSliderIndex(_ value: Double) {
        guard canEdit, value.isFinite, !acceptedTargets.isEmpty else { return }
        setDraft(acceptedTargets[min(acceptedTargets.count - 1, max(0, Int(value.rounded())))])
    }
    func setDraft(_ target: Int) {
        guard canEdit, acceptedTargets.contains(target) else { return }
        draftText = String(target); draftDirty = true; notices.clearPageNotices()
    }
    func typedDraftChanged() { draftDirty = true }
    @discardableResult func validateTypedDraft() -> Bool {
        guard let value = draftTarget else { notices.post(L10n.text("Unsupported percentage. Choose an available step."), from: .control); return false }
        draftText = String(value); return true
    }
    func setMenuBarIconScale(_ value: Double) {
        menuBarIconScale = MenuBarSizing.validatedIconScale(value)
        preferences.set(menuBarIconScale, forKey: "menuBarIconScale")
        onPresentationChange?()
    }
    func resetMenuBarSizing() { menuBarTextSize = .system; setMenuBarIconScale(1) }
    /// Read-only: the quick panel's keyboard row exists only once the backlight has been read, and a view
    /// modifier on an initially empty row never runs, so opening the panel refreshes it explicitly.
    func quickPanelWillOpen() async {
        async let keyboard: Void = keyboardBacklight.refresh()
        // Discover the native charge interface (read-only) before the Charge tab is opened. Doing it only
        // when that tab appears made its content grow and shrink three times, a visible vertical jump.
        if !isDemo, !sleeping { lastNativeChargeRead = Date(); await nativeCharge.refresh() }
        await keyboard
    }
    @ObservationIgnored private var lastNativeChargeRead: Date?
    /// For views that merely appear: skips the read when the panel opening (or an explicit refresh) just did it,
    /// so the status rows do not flash a "reading" state and resize the open menu.
    func refreshNativeChargeIfStale(maximumAge: TimeInterval = 30) async {
        if let last = lastNativeChargeRead, Date().timeIntervalSince(last) < maximumAge { return }
        await refreshNativeCharge()
    }
    func quickPanelDidClose() {
        isPopoverVisible = false
        if !isDetailVisible || selectedSection != .charging { discardDraft() }
    }
    func discardDraft() {
        if !isDemo, case let .ceiling(target) = nativeCharge.requestedIntent { draftText = String(target) }
        else if !isDemo, let observed = nativeCharge.observed { draftText = String(observed.configuration.target) }
        else if !isDemo, let reported = nativeCharge.currentReportedTarget { draftText = String(reported) }
        else if !isDemo, case let .ceiling(target) = liveControl.requestedIntent { draftText = String(target) }
        else if case let .ceiling(target) = chargeState?.requested { draftText = String(target) }
        else if let value = chargeState?.appliedTarget, acceptedTargets.contains(value) { draftText = String(value) }
        else { draftText = isDemo ? acceptedTargets.first.map(String.init) ?? "" : "" }
        draftDirty = false
    }
    func applyDraftTarget() { guard canApply, validateTypedDraft(), let target = draftTarget else { return }; perform(.setCeiling(percent: target)) }
    /// Simulation only. The live one-time charge is `startChargeOnce`/`cancelChargeOnce` (`ChargeOnceStore`, quick menu).
    func toggleSimulatedFullChargeOnce() {
        guard isDemo else { return }
        perform(isFullChargeOnceRequested ? .cancelOneShot : .chargeToFullOnce)
    }

    // MARK: One-time charge to 100 % on the native path (the slider's own apply; the previous limit is put back afterwards)
    /// The limit macOS reports right now (100 when the limit is off), nil until read.
    var observedNativeLimit: Int? {
        nativeCharge.observed.map { $0.configuration.enabled ? $0.configuration.target : NativeChargeAdmission.unlimitedTarget }
    }
    var isChargeOnceRunning: Bool { chargeOnce.isActive }
    var chargeByObservation: ChargeByObservation { chargeByEnvironment?.observation() ?? ModelChargeByEnvironment(model: self).observation() }
    /// The one-time charge is on offer (steady look); `canStartChargeOnce` adds the momentary gates and decides the tap.
    var chargeOnceOffered: Bool {
        guard !isDemo, usesNativeCharge, !controlsAreSuspended, !chargeOnce.isActive, !chargeBy.isArmed, nativeCharge.offersTarget(100),
              let limit = observedNativeLimit, limit < NativeChargeAdmission.unlimitedTarget else { return false }
        return true
    }
    var canStartChargeOnce: Bool {
        guard !isDemo, usesNativeCharge, canEdit, !chargeOnce.isActive, !chargeBy.isArmed, nativeCharge.canApplyTarget(100),
              let limit = observedNativeLimit, limit < NativeChargeAdmission.unlimitedTarget else { return false }
        return true
    }
    func startChargeOnce() {
        guard canStartChargeOnce, let previous = observedNativeLimit else { return }
        let percent = snapshot.chargePercent.value
        let fresh = snapshot.chargePercent.availability == .available && snapshot.chargePercent.freshness == .fresh
        runNative { [weak self] service in
            try await service.apply(100, batteryPercent: percent, batteryFresh: fresh)
            self?.chargeOnce.begin(previous: previous)
        }
    }
    func cancelChargeOnce() {
        guard let previous = chargeOnce.previousTarget else { return }
        restoreAfterChargeOnce(previous)
    }
    private func restoreAfterChargeOnce(_ previous: Int) {
        let percent = snapshot.chargePercent.value
        let fresh = snapshot.chargePercent.availability == .available && snapshot.chargePercent.freshness == .fresh
        runNative { [weak self] service in
            try await service.apply(previous, batteryPercent: percent, batteryFresh: fresh)
            self?.chargeOnce.clear()
        }
    }
    /// After every reading: the charge is over (full, or the adapter was unplugged) or the limit was changed elsewhere.
    private func evaluateChargeOnce() {
        guard !isDemo, !sleeping, !isApplying, !nativeCharge.isBusy, let previous = chargeOnce.previousTarget else { return }
        let usable = { (reading: TelemetryReading<Bool>) in reading.availability == .available && reading.freshness != .stale ? reading.value : nil }
        let level = snapshot.chargePercent.availability == .available && snapshot.chargePercent.freshness != .stale ? snapshot.chargePercent.value : nil
        switch ChargeOnceRule.decide(previous: previous, observedTarget: observedNativeLimit, percent: level,
                                     isCharging: usable(snapshot.isCharging), externalPower: usable(snapshot.isExternalPower)) {
        case .keep: break
        case .drop: chargeOnce.clear()
        case .restore(let target): restoreAfterChargeOnce(target)
        }
    }
    func releaseControl() { perform(.returnToSystemControl) }
    func cancelPendingTarget() {
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
        lastNativeChargeRead = Date()
        await nativeCharge.refresh()
        await optimizedCharging.refresh()
        if !draftDirty { discardDraft() }
    }
    func qualifyNativeCharge() { runNative { try await $0.qualify() } }
    /// A native charge action (runNative) is running: a quit waits for it instead of refusing.
    private(set) var nativeActionInFlight = false
    private func runNative(_ action: @escaping @MainActor (NativeChargeService) async throws -> Void) {
        guard !isDemo, !isApplying, !controlsAreSuspended else { return }
        isApplying = true; nativeActionInFlight = true; arbiter.recordManualAction(at: Date()); persistArbiter()
        Task {
            defer { isApplying = false; nativeActionInFlight = false }
            do {
                try await action(nativeCharge); draftDirty = false
                if !nativeCharge.isBusy { await nativeCharge.refresh() }
                // The confirmation is the slider and its readout, so only the explanation of a waiting target is kept (it goes
                // when the target is applied or cancelled). Other service messages are not copied onto the page.
                discardDraft(); notices.clearPageNotices()
                if nativeCharge.pendingTarget != nil, let message = nativeCharge.message { notices.post(L10n.text(message), from: .chargeStatus) }
            } catch {
                // A failure line that goes away on its own, so a one-off refusal never stays on the Charge page.
                notices.post(L10n.text(error.localizedDescription), from: .control, expiresAfter: .seconds(6))
            }
        }
    }
    private func runSimulation(_ action: @escaping @Sendable (SimulationController) async throws -> Void) {
        guard isDemo, !updatePreparationActive, !isApplying, let simulator else { return }
        isApplying = true; arbiter.recordManualAction(at: Date()); persistArbiter()
        Task {
            defer { isApplying = false }
            do { try await action(simulator); draftDirty = false; await refreshSimulation(); notices.post(L10n.text("Simulation only — your Mac settings are unchanged."), from: .simulation) }
            catch { notices.post(L10n.text("Operation failed") + ": " + String(describing: error), from: .control) }
        }
    }
    private func runLive(_ action: @escaping @MainActor (LiveControlService) async throws -> Void) {
        guard !isDemo, !isApplying, !controlsAreSuspended else { return }
        isApplying = true; arbiter.recordManualAction(at: Date()); persistArbiter()
        Task {
            defer { isApplying = false }
            do { try await action(liveControl); draftDirty = false; discardDraft(); postControlResult(liveControl.message) }
            catch { notices.post(L10n.text("Operation failed") + ": " + error.localizedDescription, from: .control) }
        }
    }
    /// A helper or schedule result: its message replaces the earlier notices, and no message clears them (as the single
    /// notice line used to).
    private func postControlResult(_ message: String?) {
        if let message { notices.post(message, from: .control) } else { notices.clearPageNotices() }
    }
    func setFanPolicy(_ policy: FanPolicy) {
        if isDemo { runSimulation { try await $0.setFanPolicy(policy) } }
        else { runLive { try await $0.setFanPolicy(policy) } }
    }
    func registerHelper() { runLive { try await $0.registerHelper() } }
    func removeHelper() { runLive { try await $0.unregisterHelper() } }
    func restoreAll() { runLive { guard try await $0.restoreAll() else { throw PrivilegeError.recoveryRequired } } }
    func prepareForTermination(systemInitiated: Bool = false) async -> Bool {
        guard await closedLid.prepareForTermination() else { return false }
        // A system-initiated logout or shutdown cannot wait: the recovery marker restores sleep at the next launch.
        if !(await lidSleep.prepareForTermination()) {
            if !systemInitiated { navigation.sleepPage = .awake; return false }
        }
        await lidComfort.prepareForTermination()   // brightness and volume back, whether or not the override was on
        sleepAtCharge.stop(); keepAwakeUntilCharge.stop()   // release their awake holds before any termination or update install
        if systemInitiated { sleepTimer.stop() }
        else {
            if sleepTimer.needsHoldRelease { sleepTimer.cancel(); guard !sleepTimer.needsHoldRelease else { return false } }
            guard !sleepTimerBlocksControls else { return false }; sleepTimer.cancel()
            guard !sleepTimer.needsHoldRelease else { return false }
        }
        do { try keepAwake.stop() } catch { return false }
        if isDemo { return true }
        // Native charging never writes the limit at quit, logout or update and never refuses: a confirmed limit is the
        // user's macOS setting and an unconfirmed one is journaled before dispatch, so it resolves at the next launch.
        // An ordinary quit waits (bounded) for a native write in flight to read back; a system-initiated one cannot wait.
        if !systemInitiated {
            let deadline = ContinuousClock.now.advanced(by: nativeCharge.maximumOperationDuration)
            while (isApplying && nativeActionInFlight) || nativeCharge.isBusy || nativeCharge.isQualifying {
                guard ContinuousClock.now < deadline, !Task.isCancelled else { break }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
        }
        // Helper and mode actions keep their rule: they are not interrupted.
        if isApplying && !nativeActionInFlight { return false }
        return await liveControl.prepareForTermination()
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
        let targets = !isDemo && usesNativeCharge ? nativeCharge.authorizedPersistentTargets : acceptedTargets
        return plan.preview(chargeTargets: targets, chargeAvailable: isDemo || (usesNativeCharge && nativeCharge.canApply),
                            restoreAvailable: isDemo || canReleaseCharge || liveControl.hasOwnedSettings || liveControl.recoveryRequired)
    }
    func applyMode(_ mode: WorkMode) async {
        guard !controlsAreSuspended, !isApplying, !nativeCharge.isBusy, !nativeCharge.isQualifying, !liveControl.isBusy else { return }
        notices.clearPageNotices()
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
                        // Existing services restore journaled baselines only; no guessed Normal values. The native limit
                        // is the user's own macOS setting: Normal never writes it.
                        let helper = try await liveControl.restoreAll()
                        rows[index].status = helper ? .applied : .pending
                        rows[index].detail = helper ? "Owned settings restored." : "Restoration is incomplete. Keep Tilvero open for recovery."
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
            guard let external = snapshot.isExternalPower.value, snapshot.isExternalPower.freshness != .stale else { notices.post(L10n.text("Power source unavailable"), from: .control); return }
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
        } catch { notices.post(L10n.text("Operation failed") + ": " + String(describing: error), from: .control) }
        onPresentationChange?()
    }
    func saveSchedule() {
        do {
            schedule = try ScheduleRule(fireDate: scheduleDate, profile: PowerProfile(name: scheduleProfileName, chargeTarget: scheduleProfileName == "At desk" ? 80 : nil, mode: scheduleProfileName == "On battery profile" ? .low : .automatic, oneShotFullCharge: scheduleProfileName == "Before leaving"), missedPolicy: .skip)
            preferences.set(try JSONEncoder().encode(schedule), forKey: isDemo ? "demoSchedule" : "schedule")
        } catch { notices.post(String(describing: error), from: .control) }
    }
    func removeSchedule() { schedule = nil; preferences.removeObject(forKey: isDemo ? "demoSchedule" : "schedule") }
    private func evaluateSchedule() async {
        // A schedule saved where the panel is shown (or by an earlier release that showed it) never fires in a release.
        guard developmentFeatures, !controlsAreSuspended else { return }
        guard let schedule, let profile = arbiter.evaluate(schedule, now: Date()) else { return }
        persistArbiter()
        if !isDemo {
            guard let external = snapshot.isExternalPower.value, snapshot.isExternalPower.freshness != .stale else { notices.post(L10n.text("Power source unavailable"), from: .control); return }
            let result = await liveControl.applyProfile(profile, source: external ? .adapter : .battery)
            postControlResult(result.isComplete ? liveControl.message : L10n.text("Operation failed"))
            return
        }
        guard let simulator else { return }
        let result = await simulator.applyProfile(profile)
        if result.isComplete { notices.post(L10n.text("Simulation only — your Mac settings are unchanged."), from: .simulation) }
        else { notices.post(L10n.text("Operation failed"), from: .control) }
        await refreshSimulation()
    }
    private func persistArbiter() { if let data = try? JSONEncoder().encode(arbiter) { preferences.set(data, forKey: isDemo ? "demoArbiter" : "arbiter") } }
    /// Opens the store off the main actor, then loads the week, the summary and the sleep reports. Until then the
    /// history views show their loading/empty states; nothing is invented in the meantime.
    private func openHistory(at url: URL) {
        historyLoading = true
        historyChain = Task { @MainActor [weak self] in
            // A model stopped (or released) before this task ran never opens, so nothing is created behind its back.
            guard self?.historyStopped == false else { self?.historyLoading = false; return }
            let opened: BatteryHistoryStore
            do { opened = try await BatteryHistoryStore.open(url: url) }
            catch { self?.storeError = HistoryStoreErrorText.text(error); self?.historyLoading = false; return }
            guard let self, !self.historyStopped else { try? await opened.close(); return }
            self.store = opened
            // Independent history readers must still run if sleep-codec validation
            // rejects retention. Never turn a preserved corrupt record into empty success.
            do { try await opened.configureRetention(self.retentionDays) } catch { self.storeError = HistoryStoreErrorText.text(error) }
            await self.loadHistory(from: opened)
            await self.loadSleepSessions(from: opened)
            self.historyLoading = false
            self.finishBackfill(opened)
        }
    }

    /// A store migrated from schema 2 fills its scalar columns in the background; the summary appears once it is done.
    private func finishBackfill(_ store: BatteryHistoryStore) {
        backfillTask = Task.detached(priority: .utility) { [weak self] in
            do { try await store.completeBackfill() }
            catch {
                // A backfill cancelled or cut short by `stop()` is not a store error.
                await MainActor.run { if let self, !self.historyStopped { self.storeError = HistoryStoreErrorText.text(error) } }
                return
            }
            await MainActor.run {
                _ = self?.historyWork { [weak self] store in
                    guard let self, self.historySummary == nil else { return }
                    do { self.historySummary = try await store.summaryIfReady() } catch { self.storeError = HistoryStoreErrorText.text(error) }
                }
            }
        }
    }

    /// Runs `body` with the open store after all earlier history work. Without a store (it failed to open or the model
    /// stopped) `unavailable` runs instead.
    @discardableResult
    private func historyWork<T: Sendable>(unavailable: (@MainActor () -> Void)? = nil,
                                          _ body: @escaping @MainActor (BatteryHistoryStore) async -> T) -> Task<T?, Never> {
        let previous = historyChain
        let task = Task { @MainActor [weak self] () -> T? in
            await previous?.value
            guard let self else { return nil }
            guard let store = self.store, !self.historyStopped else { unavailable?(); return nil }
            return await body(store)
        }
        historyChain = Task { _ = await task.value }
        return task
    }

    /// Tests: holds the history queue (as a long export or VACUUM would) until the returned closure is called.
    func holdHistoryWorkForTesting() -> @MainActor () -> Void {
        let gate = HistoryWorkGate()
        historyWork { _ in await gate.wait() }
        return { gate.open() }
    }

    /// Waits until every history operation requested so far has finished.
    func waitForHistoryWork() async {
        while let tail = historyChain {
            await tail.value
            if historyChain == tail { return }
        }
    }

    /// A full reload reads the week from scalar columns (catalog only for the last three hours); the regular minute
    /// record only appends the new samples. The summary is the store's running total, so reading it costs nothing.
    private func loadHistory(from store: BatteryHistoryStore, incremental: Bool = false) async {
        let now = Date()
        let epoch = historyEpoch
        do {
            let weekStart = now.addingTimeInterval(-7 * 86400)
            if incremental, let last = history.last, let lastFull = lastFullHistoryReload, now.timeIntervalSince(lastFull) < 1800 {
                let seen = Set(history.suffix(8).map(\.id))
                let fresh = try await store.samples(since: last.collectedAt, readingsSince: now.addingTimeInterval(-3 * 3600))
                guard epoch == historyEpoch else { return }
                let appended = fresh.filter { !seen.contains($0.id) && $0.collectedAt >= last.collectedAt }
                if !appended.isEmpty {
                    history = history.filter { $0.collectedAt >= weekStart } + appended
                }
            } else {
                let week = try await store.samples(since: weekStart, readingsSince: now.addingTimeInterval(-3 * 3600))
                guard epoch == historyEpoch else { return }
                history = week
                lastFullHistoryReload = now
            }
            // nil while a migrated store is still backfilling: the summary stays unavailable, never partial.
            let summary = try await store.summaryIfReady()
            guard epoch == historyEpoch else { return }
            if let summary { historySummary = summary }
            // Republished only when the shown megabytes change, not on every record.
            if let usage = try? await store.storageUsage(), epoch == historyEpoch,
               usage.megabytes != historyStorage?.megabytes || usage.limitBytes != historyStorage?.limitBytes {
                historyStorage = usage
            }
        }
        catch { storeError = HistoryStoreErrorText.text(error) }
    }

    /// A full VACUUM at most weekly, only while no Tilvero window is shown and the Mac runs on the adapter.
    private func vacuumHistoryIfDue(_ store: BatteryHistoryStore, onExternalPower: Bool?) {
        let idle = !isPopoverVisible && !isDetailVisible
        guard idle, onExternalPower == true else { return }
        guard vacuumTask == nil else { return }
        vacuumTask = Task.detached(priority: .background) { [weak self] in
            _ = try? await store.vacuumIfDue(onExternalPower: onExternalPower, idle: idle)
            await MainActor.run { self?.vacuumTask = nil }
        }
    }

    private func configureRetention() {
        let days = retentionDays
        historyWork { [weak self] store in
            guard let self else { return }
            do { try await store.configureRetention(days) } catch { self.storeError = HistoryStoreErrorText.text(error) }
            await self.loadHistory(from: store)
            await self.loadSleepSessions(from: store)
        }
    }
    func eraseHistory() {
        resetSleepObservation(reason: .historyErased, persist: false)
        // Shown at once; the store erases off the main actor and the reload below restores rows if it failed.
        historyEpoch &+= 1
        lastPersisted = nil; weeklyCapacity = nil
        history = []; historySummary = nil; sleepSessions = []
        unsavedSleepRecords = []   // an unwritten report must not come back after the erase
        historyWork { [weak self] store in
            guard let self else { return }
            do { try await store.erase() } catch { self.storeError = HistoryStoreErrorText.text(error) }
            await self.loadHistory(from: store)
            await self.loadSleepSessions(from: store)
        }
    }
    private func sleepStamp() -> SleepObservationStamp {
        SleepObservationStamp(wallDate: Date(), continuousSeconds: HelperClock.continuousSeconds(), runID: sleepRunID)
    }
    private func saveSleepChanges(_ records: [SleepSessionRecord]) {
        guard !isDemo, !records.isEmpty else { return }
        bufferSleepRecords(records)
        let unavailable = L10n.text("Sleep report storage is unavailable. Existing data was preserved.")
        historyWork(unavailable: { [weak self] in self?.sleepReportError = unavailable }) { [weak self] store in
            guard let self else { return }
            let pending = self.unsavedSleepRecords
            guard !pending.isEmpty else { return }   // an earlier job already wrote them
            do {
                for record in pending { try await store.upsertSleepSession(record) }
                // Keep a report that changed again meanwhile; it is written by the job queued with that change.
                self.unsavedSleepRecords.removeAll { pending.contains($0) }
                await self.loadSleepSessions(from: store)
            } catch { self.sleepReportError = unavailable }
        }
    }
    /// Newest version per report, in first-seen order; bounded so a store that keeps failing cannot grow it forever.
    private func bufferSleepRecords(_ records: [SleepSessionRecord]) {
        guard !isDemo else { return }
        for record in records {
            if let index = unsavedSleepRecords.firstIndex(where: { $0.id == record.id }) { unsavedSleepRecords[index] = record }
            else { unsavedSleepRecords.append(record) }
        }
        if unsavedSleepRecords.count > 200 { unsavedSleepRecords.removeFirst(unsavedSleepRecords.count - 200) }
    }
    private func loadSleepSessions(from store: BatteryHistoryStore) async {
        guard !isDemo else { sleepSessions = []; return }
        do {
            var records = try await store.sleepSessions(limit: 2000)
            // Older-run pending observations can never resume, even when history
            // is off and we deliberately avoid writing recovery metadata to disk.
            let staleIDs = Set(records.filter { row in
                row.isPending && (row.sleepBoundary?.runID ?? row.wakeBoundary?.runID) != sleepRunID
            }.map(\.id))
            if !staleIDs.isEmpty {
                let stamp = sleepStamp()
                records = records.map { staleIDs.contains($0.id) ? $0.interrupted(reason: .applicationRestarted, at: stamp) : $0 }
                if historyEnabled { for record in records where staleIDs.contains(record.id) { try await store.upsertSleepSession(record) } }
            }
            sleepSessions = records; sleepReportError = nil
        } catch { sleepReportError = L10n.text("Sleep report storage is unavailable. Existing data was preserved.") }
    }
    /// With `deferWrite` the interrupted records are returned for the caller to write (termination) instead of queued.
    @discardableResult
    private func resetSleepObservation(reason: SleepInterruptionReason, persist: Bool, deferWrite: Bool = false) -> [SleepSessionRecord] {
        lifecycleEpoch &+= 1
        var records: [SleepSessionRecord] = []
        if persist && !isDemo { records = sleepTracker.accept(.interrupted(reason: reason, stamp: sleepStamp())) }
        if !deferWrite { saveSleepChanges(records) }
        sleepTracker = SleepSessionTracker(postWakeSettleSeconds: postWakeSettleSeconds); lastRawSleepEndpoint = nil; queuedWakeRefresh = false; observedWake = false
        return deferWrite ? records : []
    }
    /// `reusingRecent: false` for the explicit Refresh: a fresh `pmset` run, never the answer of a recent native read.
    func refreshSystemChargeLimit(reusingRecent: Bool = true) async {
        guard !isDemo, !sleeping, !isReadingSystemChargeLimit else { return }
        isReadingSystemChargeLimit = true
        defer { isReadingSystemChargeLimit = false }
        let epoch = lifecycleEpoch
        let value = await systemChargeLimitProvider(reusingRecent ? BatteryLimitReadings.reuseWindow : 0)
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
        ownTask { [weak self] in
            guard let self else { return }
            let raw = await self.sideEffects.rawCatalog()
            guard !Task.isCancelled else { return }
            self.inspectedRaw = raw
            self.snapshot = self.snapshot.replacingCatalog(raw)
        }
    }
    func prepareExport(diagnostics: Bool = false, csv: Bool = false) {
        if diagnostics {
            do { presentExport(try DoctorReport(snapshot: snapshot).encodedJSON(), csv: false) } catch { notices.post(String(describing: error), from: .data) }
            return
        }
        // Decoding every stored payload happens on the store's queue, not here.
        historyWork { [weak self] store in
            do { self?.presentExport(try await csv ? store.exportCSV() : store.exportJSON(), csv: csv) }
            catch { self?.notices.post(String(describing: error), from: .data) }
        }
    }
    private func presentExport(_ data: Data, csv: Bool) {
        exportData = data; exportType = csv ? .commaSeparatedText : .json
        exportPreview = String(data: data.prefix(6000), encoding: .utf8) ?? ""
    }
    func saveExport() {
        guard let data = exportData else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [exportType]
        panel.nameFieldStringValue = "Tilvero-\(isDemo ? "SIMULATION-" : "")\(Date().formatted(.iso8601.year().month().day()))" + (exportType == .json ? ".json" : ".csv")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic); exportPreview = nil; notices.post(L10n.text("Export saved"), from: .data) }
        catch { notices.post(String(describing: error), from: .data) }
    }
    func updateLoginStatus() {
        loginStatus = sideEffects.loginStatus()
    }

    private var setupControlsIdle: Bool {
        let charge = nativeCharge.presentation()
        return !controlsAreSuspended && !isApplying && !isReading && !sleeping && !sleepTimer.isActive && !sleepTimer.needsHoldRelease
            && !keepAwake.hasOwnedAssertion && !closedLid.busy && !closedLid.isOn && !closedLid.needsRecovery && !lidSleep.isOn && !lidSleep.needsRecovery
            && !nativeCharge.isBusy && !nativeCharge.isQualifying && !nativeCharge.hasOwnedSettings
            && !nativeCharge.recoveryRequired && !nativeCharge.restorationPending && nativeCharge.pendingTarget == nil
            && charge.pendingPurpose == nil && !charge.hasRecordedMutation && !charge.hasSavedAction
            && !keyboardBacklight.isBusy && !liveControl.isBusy
    }

    private func readSetupInputs() -> SetupReadinessInputs {
        var inputs = SetupReadinessInputs(launchPolicy: .monitoringOnly)
        guard canShowSetup else { return inputs }
        inputs.launchPolicy = SetupRuntime.launchPolicy(launchPolicy)
        inputs.monitoring = snapshot.chargePercent.availability == .available ? .available : .unknown
        inputs.hasReviewedSetup = hasReviewedSetup
        inputs.historyEnabled = historyEnabled
        inputs.login = setupLogin?.readStatus() ?? .unavailable

        let persistent = nativeCharge.observed.map {
            $0.isFresh && NativeChargeAdmission.isPersistent($0, target: $0.configuration.target,
                optimizedCharging: $0.configuration.optimizedCharging)
        } ?? false
        let observedCapability = persistent || nativeCharge.incompleteObservation?.isFresh() == true
        let discoveredCapability = liveControl.capabilities.first { $0.backend == "native-powerui" }?.readiness
        inputs.nativeCharge = .init(availability: observedCapability ? .available : SetupRuntime.availability(discoveredCapability),
            hasCompletePersistentState: persistent, currentOSQualified: nativeCharge.isAvailable
                && !nativeCharge.recoveryRequired && !nativeCharge.restorationPending,
            canSafelyRequestValidation: false) // The charging screen owns explicit qualification consent.
        inputs.fanAvailability = liveControl.setupFanAvailability
        inputs.helperPowerAvailability = liveControl.setupPowerAvailability
        if setupUsesNativeHost {
            inputs.helper = liveControl.readSetupHelper()
            inputs.helper.canRequestRegistration = inputs.helper.canRequestRegistration && setupControlsIdle
        }
        switch keyboardBacklight.availability {
        case .available: inputs.keyboardBacklight = .available
        case .unsupported: inputs.keyboardBacklight = .unsupported
        case .unavailable: inputs.keyboardBacklight = .unavailable
        case .unknown: inputs.keyboardBacklight = .unknown
        }
        inputs.keepAwake = keepAwake.isAvailable ? .available : .unavailable
        inputs.sleepTimer = sleepTimer.isAvailable ? .available : .unavailable
        inputs.closedLid.restorationRequired = closedLid.needsRecovery || lidSleep.needsRecovery
        inputs.updates = SetupRuntime.updates(bundle: setupBundle,
            eligiblePolicy: launchPolicy.monitoringOnly && updates.identity.supportsInstallerProfile) {
                !updatePreparationActive && updateReadiness.blockers.isEmpty
            }
        return inputs
    }

    private func showSetupRequirements(_ feature: SetupFeature) throws {
        guard canShowSetup else { throw SetupRuntimeError.actionUnavailable }
        let destination: AppDestination = switch feature {
        case .monitoring: .section(.overview)
        case .nativeCharging: .section(.charging)
        case .fans: .section(.cooling)
        case .helperPowerModes, .keyboardBacklight: .section(.diagnostics)
        case .keepAwake, .closedLid: .sleep(.awake)
        case .sleepTimer: .sleep(.timer)
        case .history: .settings(.history)
        case .launchAtLogin: .settings(.general)
        case .updateChecks, .updateInstallation: .settings(.updates)
        }
        navigation.navigate(to: destination)
    }

    private func openSetupApprovalSettings(_ feature: SetupFeature) throws {
        guard canShowSetup, let setupLogin else { throw SetupRuntimeError.actionUnavailable }
        // Both the login item and ordinary helper use the same System Settings pane.
        switch feature {
        case .launchAtLogin, .fans, .helperPowerModes: setupLogin.openApprovalSettings()
        default: throw SetupRuntimeError.actionUnavailable
        }
    }

    private func registerSetupHelper() async throws {
        guard setupUsesNativeHost, setupControlsIdle else { throw SetupRuntimeError.actionUnavailable }
        isApplying = true
        defer { isApplying = false }
        try await liveControl.registerSetupHelper()
    }

    private func enableSetupLogin() throws {
        guard canShowSetup, let setupLogin else { throw SetupRuntimeError.actionUnavailable }
        defer { updateLoginStatus() }
        try setupLogin.enable()
    }
    func toggleLogin() {
        do {
            try sideEffects.toggleLogin()
            updateLoginStatus()
        } catch { notices.post(String(describing: error), from: .data); updateLoginStatus() }
    }
    func openBatterySettings() { sideEffects.openBatterySettings() }
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

/// A one-shot latch for `holdHistoryWorkForTesting`.
@MainActor private final class HistoryWorkGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume() }
    }
}
