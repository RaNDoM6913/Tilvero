// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import ClosedLidControl

@MainActor struct ClosedLidExplanationView: View {
    @ObservedObject var model: TilveroModel
    @ObservedObject private var service: ClosedLidService
    // The small native switch can settle from 24 to 20 pt on first mount.
    // Keep the row stable while allowing larger text to increase its height.
    @ScaledMetric(relativeTo: .caption) private var minimumSwitchRowHeight: CGFloat = 24
    init(model: TilveroModel) { self.model = model; service = model.closedLid }
    private var ru: Bool { L10n.language == "ru" }
    var body: some View {
        if service.isFixture || service.isLiveTrial { trialBody } else { LidSleepOverrideRow(model: model) }
    }

    private var trialBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StudioText(ru ? "С закрытой крышкой" : "With lid closed", id: "awake.closedLid.heading")
                    .font(.system(size: 14, weight: .semibold)).fixedSize()
                SectionInfoButton(title: ru ? "С закрытой крышкой" : "With lid closed", paragraphs: [capabilityDescription, status], id: "closed-lid-info")
                Spacer(minLength: 8)
                Toggle(ru ? "С закрытой крышкой" : "With lid closed", isOn: Binding(
                    get: { service.isOn },
                    set: { enabled in Task { await service.setEnabled(enabled, seconds: min(86_400, max(1, model.keepAwake.remainingSeconds))) } }))
                    .toggleStyle(.switch).controlSize(.regular).labelsHidden().fixedSize()
                    .disabled(!service.isAvailable || service.busy || (!service.isOn && (!model.keepAwake.hasOwnedAssertion || service.needsRecovery)))
                    .accessibilityIdentifier("closed-lid-master")
            }
            .frame(height: 32)
            if service.needsRecovery { Text(status).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("closed-lid-status") }
            if let failure = service.failure { Text(failure).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if service.isLiveTrial {
                HStack {
                    Button(ru ? "Подключить помощник" : "Enable helper") { Task { await service.enroll() } }.disabled(service.busy || service.isOn)
                    Button(ru ? "Настройки macOS" : "macOS Settings") { service.openApproval() }
                }.font(.caption)
                Button(ru ? "Отключить помощник" : "Remove helper") { Task { await service.removeHelper() } }
                    .font(.caption).disabled(service.busy || service.isOn || service.needsRecovery)
            }
            if service.needsRecovery {
                Button(ru ? "Проверить восстановление" : "Check restoration") { Task { await service.refresh() } }.font(.caption).disabled(service.busy)
            }
        }
        .onAppear { service.bind(model.keepAwake) }
        .studioElement("awake.closedLid", kind: "container", label: "Closed-lid session controls")
    }
    private var capabilityDescription: String {
        if service.isLiveTrial { return ru ? "Пробный системный режим · до 2 минут" : "System trial · maximum 2 minutes" }
        if service.isFixture { return ru ? "Lab · изолированный контроллер и память" : "Lab · isolated controller and memory" }
        return ru ? "Системный контроллер требует отдельно подписанного пробного приложения и помощника. Работа с закрытой крышкой ещё не подтверждена." : "The system controller requires a separately signed trial app and helper. Closed-lid behavior is not yet qualified."
    }
    private var status: String {
        switch service.state.phase {
        case .idle: ru ? "Выключено" : "Off"
        case .prepared: ru ? "Включение…" : "Starting…"
        case .commandAccepted: ru ? "Команда принята · работа с крышкой ещё не проверена" : "Command accepted · lid behavior not yet verified"
        case .restorationRequired: ru ? "Восстановление не завершено" : "Restoration incomplete"
        case .restoreAcceptedAwaitingWitness: ru ? "Восстановление запрошено · ожидается подтверждение" : "Restore requested · awaiting confirmation"
        case .restored: ru ? "Исходное управление крышкой восстановлено" : "Original lid control restored"
        case .conflict: ru ? "Обнаружен конфликт · требуется проверка" : "Conflict detected · review required"
        case .retiredAfterBoot: ru ? "Предыдущая сессия завершена перезагрузкой" : "Previous session ended by reboot"
        }
    }
}

/// Ordinary builds: the closed-lid switch backed by `LidSleepOverrideService` (`pmset disablesleep`).
@MainActor struct LidSleepOverrideRow: View {
    @ObservedObject var model: TilveroModel
    @ObservedObject private var service: LidSleepOverrideService
    /// Keep Awake and the sleep timer each have their own switch; they share the permission and the override.
    let mode: LidMode
    init(model: TilveroModel, mode: LidMode = .keepAwake) { self.model = model; service = model.lidSleep; self.mode = mode }
    private var isTimer: Bool { mode == .sleepTimer }
    private var preferred: Bool { isTimer ? service.isPreferredForTimer : service.isPreferred }
    /// The two info paragraphs differ by mode; the third (verification note) is shared.
    static func infoKeys(for mode: LidMode) -> [String] {
        switch mode {
        case .keepAwake: [
            "An option for Keep Awake: with it on, a Keep Awake session also continues with the lid closed. It never starts Keep Awake by itself. The first time, macOS asks for the administrator password to allow one command, pmset disablesleep, without a password. Nothing else is allowed.",
            "Normal sleep returns when Keep Awake ends, when you quit Tilvero, before a sleep timer or charge sleep, and at the next launch if the app was killed. A closed Mac in a bag stays on and warm: use a hard, ventilated surface.",
            "Not verified on every Mac and macOS version."]
        case .sleepTimer: [
            "An option for the sleep timer: with it on, a running sleep timer also continues with the lid closed, and the Mac sleeps only when the timer ends. It never starts a timer by itself. The first time, macOS asks for the administrator password to allow one command, pmset disablesleep, without a password. Nothing else is allowed. The permission is shared with Keep Awake.",
            "Normal sleep returns when the timer ends or is cancelled, when you quit Tilvero, and at the next launch if the app was killed. A timer can run for up to 24 hours: a closed Mac in a bag stays on and warm, so use a hard, ventilated surface.",
            "Not verified on every Mac and macOS version."]
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StudioText(L10n.text("With lid closed"), id: isTimer ? "timer.closedLid.heading" : "awake.closedLid.heading")
                    .font(.system(size: 14, weight: .semibold)).fixedSize()
                SectionInfoButton(title: L10n.text("With lid closed"), paragraphs: Self.infoKeys(for: mode).map { L10n.text($0) },
                   id: isTimer ? "closed-lid-timer-info" : "closed-lid-info",
                   action: service.ruleFilePresent && !service.isOn && !service.needsRecovery
                    ? (L10n.text("Remove permission…"), { Task { await service.removePermission() } }) : nil)
                Spacer(minLength: 8)
                Toggle(L10n.text("With lid closed"), isOn: Binding(
                    get: { preferred },
                    set: { enabled in Task { await service.setPreferred(enabled, for: mode) } }))
                    .toggleStyle(.switch).controlSize(.regular).labelsHidden().fixedSize()
                    .disabled(!service.isAvailable || service.busy || (!preferred && service.needsRecovery))
                    .accessibilityIdentifier(isTimer ? "closed-lid-timer-master" : "closed-lid-master")
            }
            .frame(height: 32)
            if let failure = service.failure {
                Text(failure).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if service.needsRecovery {
                Button(L10n.text("Restore sleep")) { Task { await service.restoreSleep() } }.font(.caption).disabled(service.busy)
            }
        }
        .studioElement(isTimer ? "timer.closedLid" : "awake.closedLid", kind: "container", label: isTimer ? "Closed-lid timer controls" : "Closed-lid session controls")
    }
}
