// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import Foundation
import Observation
import Sparkle

/// Sparkle owns authenticated download, extraction, replacement and relaunch.
/// This adapter owns explicit consent and never exposes install-on-quit choices.
@MainActor @Observable
final class SparkleUpdateInstaller: NSObject {
    private(set) var unavailableReasons: [String] = []
    private(set) var lastError: String?
    let gate: UpdateInstallGate
    private let bundle: Bundle
    private let configuration: UpdateInstallConfiguration
    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var driver: SparkleExplicitUserDriver?
    @ObservationIgnored private var channel: UpdateChannel = .stable
    @ObservationIgnored private let diagnostics: () -> Void

    var isQualified: Bool { unavailableReasons.isEmpty }
    var installationBlocksQuit: Bool { gate.installationBlocksQuit }
    var validatedHandoffAllowsTermination: Bool { gate.validatedHandoffAllowsTermination }

    init(bundle: Bundle = .main, readOnlyReadiness: @escaping () -> [String],
         prepareAfterExplicitConsent: @escaping () async -> Bool,
         releaseInstallationExclusion: @escaping () -> Void,
         diagnostics: @escaping () -> Void) {
        self.bundle = bundle
        configuration = UpdateInstallConfiguration(info: bundle.infoDictionary ?? [:])
        gate = UpdateInstallGate(readOnlyReadiness: readOnlyReadiness,
                                prepareAfterExplicitConsent: prepareAfterExplicitConsent,
                                releaseInstallationExclusion: releaseInstallationExclusion)
        self.diagnostics = diagnostics
        super.init()
        unavailableReasons = UpdateInstallHostFacts.inspect(bundle: bundle, configuration: configuration).blockers(configuration: configuration)
    }

    /// Informational GitHub checks do not call this method. Only a user can open
    /// this authenticated executable-feed flow on a qualified Monitoring host.
    func checkForUpdates(channel: UpdateChannel) {
        unavailableReasons = UpdateInstallHostFacts.inspect(bundle: bundle, configuration: configuration).blockers(configuration: configuration)
        guard isQualified else { return }
        guard !gate.installationBlocksQuit else { driver?.showUpdateInFocus(); return }
        self.channel = channel
        gate.protectUpdateSession()
        do {
            if updater == nil {
                let userDriver = SparkleExplicitUserDriver(owner: self)
                let candidate = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: userDriver, delegate: self)
                driver = userDriver
                updater = candidate
                // This also overrides any stale preference from an older build.
                // The delegate additionally refuses every non-user check.
                candidate.automaticallyChecksForUpdates = false
                candidate.automaticallyDownloadsUpdates = false
                candidate.sendsSystemProfile = false
                try candidate.start()
            }
            updater?.checkForUpdates()
        } catch { report(error); gate.finish() }
    }

    fileprivate func report(_ error: Error) { lastError = error.localizedDescription }
    fileprivate func openDiagnostics() { diagnostics() }
    fileprivate func candidateIsAdmitted(_ item: SUAppcastItem) -> Bool {
        guard item.signingValidationStatus == .succeeded else { return false }
        let enclosure = item.propertiesDictionary["enclosure"] as? [String: Any] ?? [:]
        return UpdateInstallCandidate(build: item.versionString,
                                      bundleID: enclosure["tilveroBundleID"] as? String,
                                      profile: enclosure["tilveroProfile"] as? String,
                                      teamID: enclosure["tilveroTeamID"] as? String,
                                      architecture: enclosure["tilveroArchitecture"] as? String,
                                      url: item.fileURL, edSignature: enclosure["sparkle:edSignature"] as? String,
                                      installationType: item.installationType, informationOnly: item.isInformationOnlyUpdate)
            .isAdmitted(currentBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "", configuration: configuration)
    }
}

extension SparkleUpdateInstaller: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updates, !updater.automaticallyDownloadsUpdates,
              !updater.automaticallyChecksForUpdates, !updater.sendsSystemProfile,
              UpdateInstallConfiguration.isHTTPS(updater.feedURL),
              updater.feedURL?.absoluteString == configuration.feedURL?.absoluteString,
              UpdateInstallHostFacts.inspect(bundle: bundle, configuration: configuration).blockers(configuration: configuration).isEmpty else {
            throw NSError(domain: "Tilvero.Updates", code: 1, userInfo: [NSLocalizedDescriptionKey: text("Only explicit qualified update checks are allowed.", "Разрешена только явная проверка для подходящей сборки.")])
        }
    }
    // SUFeedURL in legacy host preferences otherwise wins over signed Info.plist.
    // Always resolve the executable feed from the sealed profile configuration.
    func feedURLString(for updater: SPUUpdater) -> String? { configuration.feedURL?.absoluteString }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { channel == .beta ? ["beta"] : [] }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard candidateIsAdmitted(item) else {
            throw NSError(domain: "Tilvero.Updates", code: 2, userInfo: [NSLocalizedDescriptionKey: text("This release is not a newer signed Monitoring app for this installation.", "Этот выпуск не является новой подписанной сборкой Monitoring для этой установки.")])
        }
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error { report(error) }
        gate.finish()
    }
    // A defense in depth veto, not the primary gate: Sparkle documents paths
    // where this delegate is never invoked. All user-driver .install replies
    // below acquire consent and readiness independently.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        !gate.validatedHandoffAllowsTermination
    }
}

@MainActor
private func text(_ english: String, _ russian: String) -> String { L10n.language == "ru" ? russian : english }

@MainActor
private final class SparkleExplicitUserDriver: NSObject, SPUUserDriver {
    private weak var owner: SparkleUpdateInstaller?
    private var progressPanel: NSPanel?
    private var statusLabel: NSTextField?
    private var progress: NSProgressIndicator?
    private var cancelButton: NSButton?
    private let progressAction = UpdateInstallProgressAction()
    private var received: UInt64 = 0
    private var expected: UInt64 = 0

    init(owner: SparkleUpdateInstaller) { self.owner = owner }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, automaticUpdateDownloading: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        showProgress(text("Checking signed app updates…", "Проверка подписанных обновлений…"), cancellation: cancellation)
    }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        closeProgress()
        guard let owner, owner.candidateIsAdmitted(appcastItem) else { reply(.skip); return }
        let title = String(format: text("Install Tilvero %@?", "Установить Tilvero %@?"), appcastItem.displayVersionString)
        let message = text("Tilvero will download and prepare this signed Monitoring update. Active sessions must end safely. Once installation begins, Sparkle may finish replacement after the app exits, including an unexpected exit. A second confirmation appears before the planned restart.", "Tilvero загрузит и подготовит подписанное обновление Monitoring. Активные сеансы должны безопасно завершиться. После начала установки Sparkle может закончить замену после выхода приложения, включая непредвиденный выход. Перед запланированным перезапуском появится второе подтверждение.")
        guard confirm(title, message, action: text("Install and Restart…", "Установить и перезапустить…")), owner.gate.beginStaging(explicitConsent: true) else {
            showBlockersIfNeeded(); reply(.skip); return
        }
        Task { @MainActor [weak self] in
            guard await owner.gate.authorizeHandoff(explicitConsent: true) else { self?.showBlockersIfNeeded(); reply(.skip); return }
            // Sparkle can resume an already-installing update directly from
            // this reply. That path retains the fresh termination permit.
            if state.stage != .installing { owner.gate.invalidateHandoff() }
            reply(.install)
        }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // Full release notes are exposed by the app's Updates panel. Never
        // execute HTML/JavaScript or open an untrusted enclosure as a URL.
    }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { owner?.report(error) }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        closeProgress(); information(text("Signed app update check", "Проверка подписанного обновления"), error.localizedDescription); acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        owner?.report(error); closeProgress(); information(text("Update could not continue", "Не удалось продолжить обновление"), error.localizedDescription); acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        received = 0; expected = 0
        showProgress(text("Downloading signed update…", "Загрузка подписанного обновления…"), cancellation: cancellation)
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expected = expectedContentLength; updateProgress() }
    func showDownloadDidReceiveData(ofLength length: UInt64) { received = received.addingReportingOverflow(length).partialValue; updateProgress() }
    func showDownloadDidStartExtractingUpdate() {
        progressAction.clear(); cancelButton?.isEnabled = false
        statusLabel?.stringValue = text("Verifying and preparing update…", "Проверка и подготовка обновления…")
        progress?.isIndeterminate = true; progress?.startAnimation(nil)
    }
    func showExtractionReceivedProgress(_ value: Double) { progress?.isIndeterminate = false; progress?.doubleValue = max(0, min(1, value)) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        closeProgress()
        guard let owner else { reply(.skip); return }
        guard confirm(text("Restart to finish installing?", "Перезапустить для завершения установки?"),
                      text("Tilvero will recheck recovery readiness, then quit and restart. Later cancels this staged installation; it will not be scheduled for the next normal quit.", "Tilvero повторно проверит готовность восстановления, затем завершит работу и запустится снова. «Позже» отменит подготовленную установку; она не будет запланирована на обычный выход."),
                      action: text("Install and Restart", "Установить и перезапустить")) else { reply(.skip); return }
        Task { @MainActor [weak self] in
            guard await owner.gate.authorizeHandoff(explicitConsent: true) else { self?.showBlockersIfNeeded(); reply(.skip); return }
            reply(.install)
        }
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        showProgress(text("Installing update…", "Установка обновления…"), cancellation: nil)
        guard !applicationTerminated, let owner else { return }
        // A canceled/indefinitely delayed termination must not retain a retry
        // closure that bypasses fresh consent. This native Retry button repeats
        // the same async gate; no automatic retries are scheduled.
        progressAction.setRetry { [weak self, weak owner] in
            guard let self, let owner else { return }
            owner.gate.invalidateHandoff()
            guard self.confirm(text("Retry restart?", "Повторить перезапуск?"), text("Readiness will be checked again.", "Готовность будет проверена повторно."), action: text("Retry Restart", "Повторить перезапуск")) else { return }
            Task { @MainActor in
                if await owner.gate.authorizeHandoff(explicitConsent: true) { retryTerminatingApplication() }
                else { self.showBlockersIfNeeded() }
            }
        }
        cancelButton?.title = text("Retry Restart…", "Повторить перезапуск…"); cancelButton?.isEnabled = true
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { closeProgress(); acknowledgement() }
    func dismissUpdateInstallation() { closeProgress(); owner?.gate.finish() }
    func showUpdateInFocus() { progressPanel?.makeKeyAndOrderFront(nil) }

    private func confirm(_ title: String, _ message: String, action: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: action); alert.addButton(withTitle: text("Later", "Позже"))
        alert.buttons[0].keyEquivalent = ""; alert.buttons[1].keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func information(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.runModal()
    }
    private func showBlockersIfNeeded() {
        guard let owner, !owner.gate.blockers.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = text("Installation is deferred", "Установка отложена")
        alert.informativeText = owner.gate.blockers.map(L10n.text).joined(separator: "\n")
        alert.addButton(withTitle: text("Later", "Позже")); alert.addButton(withTitle: text("Diagnostics", "Диагностика"))
        if alert.runModal() == .alertSecondButtonReturn { owner.openDiagnostics() }
    }
    private func showProgress(_ title: String, cancellation: (() -> Void)?) {
        closeProgress(); progressAction.setCancellation(cancellation)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 130), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = text("Tilvero Update", "Обновление Tilvero"); panel.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: title); label.frame = NSRect(x: 20, y: 80, width: 350, height: 24)
        let indicator = NSProgressIndicator(frame: NSRect(x: 20, y: 56, width: 350, height: 14)); indicator.style = .bar; indicator.isIndeterminate = true; indicator.minValue = 0; indicator.maxValue = 1; indicator.startAnimation(nil)
        let button = NSButton(title: text("Cancel", "Отмена"), target: self, action: #selector(cancel)); button.frame = NSRect(x: 240, y: 12, width: 130, height: 32); button.isEnabled = cancellation != nil
        panel.contentView?.addSubview(label); panel.contentView?.addSubview(indicator); panel.contentView?.addSubview(button)
        progressPanel = panel; statusLabel = label; progress = indicator; cancelButton = button
        panel.center(); panel.makeKeyAndOrderFront(nil)
    }
    @objc private func cancel() { progressAction.perform() }
    private func closeProgress() { progressPanel?.close(); progressPanel = nil; statusLabel = nil; progress = nil; cancelButton = nil; progressAction.clear() }
    private func updateProgress() {
        guard expected > 0 else { return }
        progress?.isIndeterminate = false; progress?.doubleValue = min(1, Double(received) / Double(expected))
    }
}
