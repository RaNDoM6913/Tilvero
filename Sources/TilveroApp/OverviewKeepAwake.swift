// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import PowerCore

/// The Keep Awake block of the Overview page: a switch, one strip of four quick durations, an
/// "until stopped" button and a way to the Sleep page. Choosing a duration starts at once and the chosen
/// segment shows the countdown; every start, switch and confirmation goes through `SleepPillActions`,
/// exactly like the Keep Awake page of the Sleep tab.
@MainActor struct OverviewKeepAwake: View {
    static let presets = [15, 30, 60, 240]
    @ObservedObject var model: TilveroModel
    /// Opens the Sleep page. `nil` in the passive builder preview.
    var openSleep: (@MainActor () -> Void)?
    @State private var error: String?
    private enum PendingAction { case request(AwakePillRequest), enable(AwakePillRequest) }
    @State private var pending: PendingAction?
    @State private var consent: SleepPillConfirmation?
    @State private var confirms = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var service: KeepAwakeService { model.keepAwake }

    /// "Until 22:21" while a timed session runs. An open-ended session names no end, so nothing is shown.
    static func endText(expiry: KeepAwakeExpiry?, endDate: Date?) -> String? {
        guard let endDate, let expiry, expiry != .untilStopped else { return nil }
        return untilText(endDate)
    }

    /// "Until 22:21", with ", tomorrow" when the end is on the next day.
    static func untilText(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter(); formatter.locale = L10n.locale; formatter.timeStyle = .short
        let suffix = calendar.isDateInTomorrow(date) ? ", " + L10n.text("tomorrow") : ""
        return L10n.text("Until") + " " + formatter.string(from: date) + suffix
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tick in
            let _ = tick.date   // the content must read the tick, or SwiftUI may keep the first rendering
            let applied = SleepPillActions.awakeSelection(model)
            VStack(alignment: .leading, spacing: 10) {
                header
                HStack(spacing: 6) {
                    strip(applied: applied)
                    roundButton(selected: applied == .untilStopped, id: "overview-awake-forever", label: L10n.text("Until stopped"),
                                action: { if applied == .untilStopped { stopSession() } else { apply(.untilStopped) } }) {
                        Text("∞").font(.system(size: 15, weight: .semibold))
                    }
                    if let openSleep {
                        roundButton(selected: false, id: "overview-awake-more", label: L10n.text("Sleep"), action: openSleep) {
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }
                }
                if applied == .custom || applied == .until, service.isActive {
                    HStack(spacing: 4) {
                        Text(L10n.text("Time remaining"))
                        AwakeCountdownText(service: service)
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if service.hasOwnedAssertion, !service.isActive {
                    Text(L10n.text("Check session")).font(.caption).foregroundStyle(.orange)
                }
                if let message = error ?? service.message {
                    Text(L10n.text(message)).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if !service.isAvailable {
                    Text(L10n.text("Keep Awake is unavailable in this build or simulation.")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .studioElement("overview.awake", kind: "container", label: "Keep Awake")
        .confirmationDialog(consent?.title ?? "", isPresented: $confirms, titleVisibility: .visible) {
            Button(consent?.action ?? L10n.text("Apply")) {
                switch pending {
                case .request(let request): apply(request, consent: consent)
                case .enable(let request): setEnabled(true, token: nil, request: request, consent: consent)
                case nil: break
                }
            }
            Button(L10n.text("Cancel"), role: .cancel) { pending = nil; consent = nil }
        } message: { Text(consent?.explanation ?? "") }
    }

    private var header: some View {
        let token = service.ownedAssertionID.map(SleepControlToken.awake)
        return HStack(spacing: 8) {
            Label(L10n.text("Keep Awake"), systemImage: "cup.and.saucer").font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 8)
            if let end = Self.endText(expiry: service.expiry, endDate: service.isActive ? service.endDate : nil) {
                Text(end).font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
            }
            Toggle(L10n.text("Keep Awake"), isOn: Binding(get: { service.hasOwnedAssertion }, set: { setEnabled($0, token: token) }))
                .toggleStyle(.switch).tint(Color.accentColor).controlSize(.regular).labelsHidden().fixedSize()
                .disabled(!service.hasOwnedAssertion && !SleepPillActions.canChooseAwake(model))
                .accessibilityIdentifier("overview-awake-master")
        }.frame(height: 26)
    }

    private func strip(applied: SleepPillSelection?) -> some View {
        HStack(spacing: 2) {
            ForEach(Self.presets, id: \.self) { minutes in
                let selected = applied == .preset(minutes)
                Button { if selected { stopSession() } else { apply(.duration(minutes)) } } label: {
                    Group {
                        if selected { AwakeCountdownText(service: service).font(.system(size: 12, weight: .semibold, design: .rounded)) }
                        else { Text(Self.label(minutes)).font(.system(size: 12, weight: .medium)) }
                    }
                    .foregroundStyle(selected ? Color.white : Color.primary).lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .background(selected ? Color.accentColor : Color.clear, in: Capsule())
                    .contentShape(Capsule())
                }.buttonStyle(.plain)
                    .disabled(!selected && !SleepPillActions.canChooseAwake(model))
                    .help(selected ? Self.endSessionHelp : "")
                    .accessibilityLabel(Self.label(minutes)).accessibilityAddTraits(selected ? .isSelected : [])
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selected)
            }
        }
        .padding(3).background(Color.primary.opacity(0.07), in: Capsule())
    }

    private func roundButton<Label: View>(selected: Bool, id: String, label: String, action: @escaping () -> Void, @ViewBuilder content: () -> Label) -> some View {
        Button(action: action) {
            content().foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 34, height: 34)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.07), in: Circle())
                .contentShape(Circle())
        }.buttonStyle(.plain)
            .disabled(!selected && id == "overview-awake-forever" && !SleepPillActions.canChooseAwake(model))
            .accessibilityLabel(label).accessibilityAddTraits(selected ? .isSelected : []).accessibilityIdentifier(id)
    }

    /// 15 min, 30 min, 1 h, 4 h in the app's language.
    static func label(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) " + L10n.text("min") : "\(minutes / 60) " + L10n.text("h")
    }

    static var endSessionHelp: String { L10n.language == "ru" ? "Завершить сеанс" : "End session" }

    /// Tapping the running choice again ends the session, exactly like the selected pill of the Sleep tab.
    private func stopSession() {
        setEnabled(false, token: service.ownedAssertionID.map(SleepControlToken.awake))
    }

    private func apply(_ request: AwakePillRequest, consent confirmed: SleepPillConfirmation? = nil) {
        do {
            try SleepPillActions.awake(model, request: request, consent: confirmed)
            error = nil; pending = nil; consent = nil
        } catch SleepPillActionError.confirmation(let needed) {
            pending = .request(request); consent = needed; confirms = true
        } catch { self.error = error.localizedDescription }
    }

    private func setEnabled(_ enabled: Bool, token: SleepControlToken?, request: AwakePillRequest? = nil, consent confirmed: SleepPillConfirmation? = nil) {
        do {
            try SleepPillActions.setAwakeEnabled(model, enabled: enabled, token: token, request: request, consent: confirmed)
            error = nil; pending = nil; consent = nil
        } catch SleepPillActionError.confirmation(let needed) {
            guard let captured = try? request ?? SleepPillActions.awakeDraftRequest(model) else { return }
            pending = .enable(captured); consent = needed; confirms = true
        } catch { self.error = error.localizedDescription }
    }
}

/// A live countdown of a Keep Awake session. It owns its own one-second clock, so it keeps running wherever it sits
/// (inside a pill, behind a button label, in a lazily evaluated ForEach) without relying on its parents to redraw.
@MainActor struct AwakeCountdownText: View {
    @ObservedObject var service: KeepAwakeService
    @State private var now = Date()
    var body: some View {
        let _ = now
        Text(KeepAwakePresentation.countdown(service.remainingSeconds)).monospacedDigit()
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
    }
}
