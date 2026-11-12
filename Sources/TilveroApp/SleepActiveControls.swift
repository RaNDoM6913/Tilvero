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
    /// The extension steps of this session: a sleep timer also takes five minutes (it restarts with the longer total,
    /// exactly like the wheel's Apply); Keep Awake keeps its verified 15 and 60.
    private var steps: [Int] { isAwake ? [15, 60] : [5, 15, 60] }
    private func label(_ minutes: Int) -> String { minutes < 60 ? "+\(minutes) " + L10n.text("min") : "+\(minutes / 60) " + L10n.text("h") }
    private func canStep(_ minutes: Int) -> Bool {
        if minutes == 5 { return sameSession && model.sleepPillActionsAllowed && model.sleepTimer.remainingSeconds > 0 && model.sleepTimer.remainingSeconds <= 86_400 - 300 }
        return SleepPillActions.canExtend(model, token: token, minutes: minutes)
    }
    private func step(_ minutes: Int) {
        if minutes == 5 {
            guard canStep(5) else { error = SleepPillActionError.blocked.localizedDescription; return }
            let total = min(1440, (model.sleepTimer.remainingSeconds + 59) / 60 + 5)
            onClose()
            Task { @MainActor in
                await Task.yield()
                guard SleepPillActions.controlToken(model, awake: false) == token else { return }
                onSetTime?(.duration(total))
            }
            return
        }
        do { try SleepPillActions.extend(model, token: token, minutes: minutes); error = nil; revision += 1 }
        catch { self.error = error.localizedDescription }
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(steps, id: \.self) { minutes in
                    Button { step(minutes) } label: {
                        Text(label(minutes)).font(.subheadline.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .foregroundStyle(Color.primary)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain).disabled(!canStep(minutes)).opacity(canStep(minutes) ? 1 : 0.45)
                    .studioElement("sleep.extend.\(minutes)", label: "Extend \(minutes) minutes")
                }
                // Off: the red power pill closes the row (5 · 15 · 1 h · off).
                Button {
                    do { try SleepPillActions.finish(model, token: token); onClose() }
                    catch { self.error = error.localizedDescription }
                } label: {
                    Image(systemName: "power").font(.system(size: 13, weight: .semibold)).foregroundStyle(.red)
                        .frame(width: 40).padding(.vertical, 7)
                        .background(Capsule().fill(Color.red.opacity(0.14)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain).disabled(!sameSession)
                .help(L10n.text(isAwake ? "End Keep Awake" : "End timer"))
                .accessibilityLabel(L10n.text(isAwake ? "End Keep Awake" : "End timer"))
                .studioElement("sleep.finish", label: "End session")
            }.padding(.horizontal, 12).padding(.top, 4)
            if let error {
                Text(L10n.text(error)).font(.caption).foregroundStyle(.orange).lineLimit(2).padding(.horizontal, 12)
            }
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
