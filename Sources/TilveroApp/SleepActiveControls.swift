// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI

enum SleepControlToken: Equatable, Identifiable {
    case awake(UInt32), timer(UUID)
    var id: String {
        switch self { case .awake(let id): "awake.\(id)"; case .timer(let id): "timer.\(id)" }
    }
}

@MainActor extension SleepPillActions {
    static func controlToken(_ model: TilveroModel, awake: Bool) -> SleepControlToken? {
        if awake {
            guard model.keepAwake.isActive, let id = model.keepAwake.ownedAssertionID else { return nil }
            return .awake(id)
        }
        guard model.sleepTimer.isEditable, let id = model.sleepTimer.sessionID else { return nil }
        return .timer(id)
    }
    static func canExtend(_ model: TilveroModel, token: SleepControlToken, minutes: Int) -> Bool {
        guard [15, 30, 60].contains(minutes), model.sleepPillActionsAllowed else { return false }
        switch token {
        case .awake:
            guard controlToken(model, awake: true) == token, model.keepAwake.expiry != .untilStopped else { return false }
            return model.keepAwake.remainingSeconds > 0 && model.keepAwake.remainingSeconds <= 86_400 - minutes * 60
        case .timer:
            guard controlToken(model, awake: false) == token else { return false }
            return model.sleepTimer.remainingSeconds > 0 && model.sleepTimer.remainingSeconds <= 86_400 - minutes * 60
        }
    }
    static func extend(_ model: TilveroModel, token: SleepControlToken, minutes: Int) throws {
        guard canExtend(model, token: token, minutes: minutes) else { throw SleepPillActionError.blocked }
        switch token {
        case .awake: try model.keepAwake.extend(by: minutes * 60)
        case .timer:
            // The service verifies each supported fifteen-minute extension. Any
            // failure remains its actual terminal/cleanup state, never a UI claim.
            for _ in 0..<(minutes / 15) {
                guard controlToken(model, awake: false) == token else { throw SleepPillActionError.blocked }
                try model.sleepTimer.extend()
            }
        }
    }
    static func finish(_ model: TilveroModel, token: SleepControlToken) throws {
        switch token {
        case .awake(let id):
            guard model.keepAwake.ownedAssertionID == id else { throw SleepPillActionError.blocked }
            try model.keepAwake.stop()
        case .timer(let id):
            guard model.sleepTimer.sessionID == id,
                  model.sleepTimer.isEditable || model.sleepTimer.phase == .preparing else { throw SleepPillActionError.blocked }
            model.sleepTimer.cancel()
            if model.sleepTimer.needsHoldRelease { throw KeepAwakeError.releaseFailed }
        }
    }
}

@MainActor struct SleepActiveControls: View {
    @ObservedObject var model: TilveroModel
    let token: SleepControlToken
    let onClose: () -> Void
    var onSetTime: ((SleepWheelValue) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var revision = 0
    @State private var error: String?
    private var isAwake: Bool { if case .awake = token { true } else { false } }
    private var sameSession: Bool { SleepPillActions.controlToken(model, awake: isAwake) == token }
    private var mode: SleepWheelMode {
        if isAwake, case .until = model.keepAwake.expiry { return .until }
        return .duration
    }
    private var initialMinutes: Int {
        let remaining = isAwake ? model.keepAwake.remainingSeconds : model.sleepTimer.remainingSeconds
        return remaining > 0 ? min(1440, max(1, (remaining + 59) / 60)) : 30
    }
    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                ForEach([15, 60], id: \.self) { minutes in
                    Button(minutes == 15 ? "+15 " + L10n.text("min") : "+1 " + L10n.text("h")) {
                        do {
                            try SleepPillActions.extend(model, token: token, minutes: minutes)
                            error = nil; revision += 1
                        } catch { self.error = error.localizedDescription }
                    }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
                    .disabled(!SleepPillActions.canExtend(model, token: token, minutes: minutes))
                    .studioElement("sleep.extend.\(minutes)", label: "Extend \(minutes) minutes")
                }
                Button {
                    do { try SleepPillActions.finish(model, token: token); onClose() }
                    catch { self.error = error.localizedDescription }
                } label: {
                    Image(systemName: "power").font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28).background(Color.red.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain).foregroundStyle(.red).disabled(!sameSession)
                .accessibilityLabel(L10n.language == "ru" ? "Завершить сеанс" : "End session")
                .help(L10n.language == "ru" ? "Завершить сеанс" : "End session")
                .studioElement("sleep.finish", label: "End session")
            }.padding(.horizontal, 12).frame(height: 34)
            Text(error.map(L10n.text) ?? (L10n.language == "ru" ? "Изменить оставшееся время" : "Edit remaining time"))
                .font(.system(size: 10)).foregroundStyle(error == nil ? Color.secondary : Color.orange)
                .lineLimit(2).frame(height: 22).padding(.horizontal, 12).help(error ?? "")
            SleepWheelPicker(mode: mode, initialMinutes: initialMinutes,
                initialDate: (isAwake ? model.keepAwake.endDate : model.sleepTimer.endDate) ?? Date().addingTimeInterval(1800),
                onCommit: commit, onCancel: onClose)
                .id(revision).disabled(!sameSession)
        }
        .frame(width: 244)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { appeared = true } }
        .onExitCommand(perform: onClose)
    }
    private func commit(_ value: SleepWheelValue) {
        guard sameSession else { error = SleepPillActionError.blocked.localizedDescription; return }
        onClose()
        Task { @MainActor in
            await Task.yield()
            guard SleepPillActions.controlToken(model, awake: isAwake) == token else { return }
            onSetTime?(value)
        }
    }
}
