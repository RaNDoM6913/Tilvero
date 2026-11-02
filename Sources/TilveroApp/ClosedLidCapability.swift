import SwiftUI
import ClosedLidControl

@MainActor struct ClosedLidExplanationView: View {
    @ObservedObject var model: TilveroModel
    @ObservedObject private var service: ClosedLidService
    init(model: TilveroModel) { self.model = model; service = model.closedLid }
    private var ru: Bool { L10n.language == "ru" }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(ru ? "С закрытой крышкой" : "With lid closed", isOn: Binding(
                get: { service.isOn },
                set: { enabled in Task { await service.setEnabled(enabled, seconds: min(86_400, max(1, model.keepAwake.remainingSeconds))) } }))
                .toggleStyle(.switch).controlSize(.small)
                .disabled(!service.isAvailable || service.busy || (!service.isOn && (!model.keepAwake.hasOwnedAssertion || service.needsRecovery)))
                .accessibilityIdentifier("closed-lid-master")
            Text(capabilityDescription)
                .font(.caption2).foregroundStyle(.secondary)
            if service.state.phase != .idle { Text(status).font(.caption).foregroundStyle(service.needsRecovery ? .orange : .secondary).accessibilityIdentifier("closed-lid-status") }
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
        .font(.caption).padding(.top, 4)
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
