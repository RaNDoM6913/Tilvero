// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI

private typealias M = FirstRunMotion

struct FirstRunCheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.26, y: r.minY + r.height * 0.52))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.43, y: r.minY + r.height * 0.69))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.76, y: r.minY + r.height * 0.33))
        return p
    }
}

/// Green check that draws itself in (`progress` 0…1).
struct FirstRunDoneMark: View {
    var progress: Double
    var body: some View {
        ZStack {
            Circle().fill(Color.green).scaleEffect(0.6 + 0.4 * M.easeOutCubic(progress * 2)).opacity(M.clamp01(progress * 3))
            FirstRunCheckShape().trim(from: 0, to: M.easeOutCubic(progress))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)).padding(2)
        }.frame(width: 18, height: 18).accessibilityHidden(true)
    }
}

struct FirstRunPreviewBadge: View {
    var body: some View {
        Text(L10n.text("firstRun.preview")).font(.caption2.weight(.semibold)).foregroundStyle(.orange)
            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.orange.opacity(0.15)))
    }
}

/// The one first-run window: every choice on one page, one main button, the outcome on the same page.
struct FirstRunWindowView: View {
    @ObservedObject var session: FirstRunSession
    static let width: CGFloat = 480

    struct Row: Identifiable {
        var id: String
        var title: String, detail: String, symbol: String
        var path: WritableKeyPath<FirstRunChoices, Bool>
        var feature: PrivilegedFeature?
    }
    static let rows: [Row] = [
        Row(id: "login", title: "firstRun.launchAtLogin", detail: "firstRun.launchAtLogin.detail", symbol: "power", path: \.launchAtLogin),
        Row(id: "history", title: "firstRun.keepHistory", detail: "firstRun.keepHistory.detail", symbol: "clock.arrow.circlepath", path: \.keepHistory),
        Row(id: "lid", title: "firstRun.lidClosed", detail: "firstRun.lidClosed.detail", symbol: "laptopcomputer", path: \.lidClosed, feature: .lidClosed),
        Row(id: "chargeBy", title: "firstRun.chargeByTime", detail: "firstRun.chargeByTime.detail", symbol: "alarm", path: \.chargeByTime, feature: .chargeByTime),
    ]
    static let infoKeys = ["firstRun.info.what", "firstRun.info.password"]

    private var flow: FirstRunFlow { session.flow }

    /// Everything that changes the window's height; the coordinator resizes (keeping the center) when it changes.
    nonisolated static func layoutKey(_ flow: FirstRunFlow, showsCommand: Bool) -> String {
        "\(flow.step.rawValue)|\(flow.buttons)|\(flow.attention.map(\.rawValue))|\(showsCommand && flow.step == .waitingTerminal)"
    }

    var body: some View {
        // One timeline for the entrance (window content, hero battery, staggered rows); it stops for good after
        // `entranceEnd` (no per-frame work while the window waits), or at once on any click.
        TimelineView(.animation(paused: entranceDone || session.reduceMotion || session.frozenTime != nil)) { context in
            content(entrance: session.entranceTime(at: context.date))
        }
        .simultaneousGesture(TapGesture().onEnded { session.motionSkipped = true; session.hintSkipped = true })
        .task(id: session.entranceStart) {
            entranceDone = false
            try? await Task.sleep(for: .seconds(M.entranceEnd / max(session.speed, 0.1) + 0.05))
            if !Task.isCancelled { entranceDone = true }
        }
        .onChange(of: session.motionSkipped) { _, skipped in if skipped { entranceDone = true } }
        .frame(width: Self.width, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, L10n.locale)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("firstRun.window")
    }

    @State private var entranceDone = false
    @State private var hintDone = false

    private var reduce: Bool { session.reduceMotion }
    /// Crossfades between steps: short, and at most 0.15 s with Reduce Motion.
    private var stepAnimation: Animation { .easeInOut(duration: M.crossfadeDuration(reduceMotion: reduce)) }

    private func content(entrance t: Double) -> some View {
        let e = M.entrance(t, reduceMotion: reduce)
        return VStack(alignment: .leading, spacing: 18) {
            header(M.hero(t, reduceMotion: reduce))
            choices(t)
            status.id(flow.step).transition(.opacity)
            if flow.step == .waitingTerminal { terminalHint.transition(.opacity) }
            if session.showsCommand, flow.step == .waitingTerminal, let text = session.commandText { commandBox(text).transition(.opacity) }
            buttons
        }
        .padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 22)
        .animation(stepAnimation, value: flow.step)
        .animation(stepAnimation, value: session.showsCommand)
        .opacity(e.opacity).scaleEffect(e.scale).offset(y: e.rise)
    }

    // MARK: Header

    private func header(_ hero: FirstRunMotion.Hero) -> some View {
        HStack(alignment: .center, spacing: 16) {
            FirstRunHeroBattery(frame: hero)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(L10n.text("firstRun.title")).font(.system(size: 20, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    if session.isPreview { FirstRunPreviewBadge() }
                }
                Text(L10n.text("firstRun.subtitle")).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Choices

    private func choices(_ t: Double) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(Self.rows.enumerated()), id: \.element.id) { index, row in
                let appear = M.rowAppear(index, t, reduceMotion: reduce)
                VStack(spacing: 0) {
                    if index > 0 { Divider().padding(.leading, 40) }
                    choiceRow(row)
                }
                .opacity(appear).offset(y: 6 * (1 - appear))
            }
        }
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
        .disabled(!flow.choicesEditable)
        .opacity(flow.choicesEditable || flow.step == .done ? 1 : 0.75)
    }

    private func choiceRow(_ row: Row) -> some View {
        let binding = Binding(get: { session.flow.choices[keyPath: row.path] }, set: { session.flow.choices[keyPath: row.path] = $0 })
        return HStack(spacing: 12) {
            Image(systemName: row.symbol).font(.system(size: 17)).foregroundStyle(Color.accentColor).frame(width: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(L10n.text(row.title)).font(.system(size: 13, weight: .semibold))
                    if let feature = row.feature { badge(granted: flow.granted.contains(feature), chosen: session.flow.choices[keyPath: row.path]) }
                }
                Text(L10n.text(row.detail)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(L10n.text(row.title), isOn: binding).toggleStyle(.switch).tint(Color.accentColor).labelsHidden().controlSize(.regular).fixedSize()
                .accessibilityIdentifier("firstRun.toggle." + row.id)
        }
        .padding(.vertical, 9)
    }

    /// The lock bounces once when the option is ticked; it turns into a check when the permission is granted.
    private func badge(granted: Bool, chosen: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: granted ? "checkmark" : "lock.fill").font(.system(size: 8, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, options: .nonRepeating, value: reduce ? false : chosen)
            Text(L10n.text(granted ? "firstRun.badge.allowed" : "firstRun.badge.password")).font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(granted ? Color.green : Color.secondary)
        .padding(.horizontal, 6).padding(.vertical, 1.5)
        .background(Capsule().fill((granted ? Color.green : Color.primary).opacity(granted ? 0.14 : 0.08)))
        .animation(reduce ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: granted)
        .accessibilityElement(children: .combine)
    }

    /// While Terminal waits: a flat drawing of "type the password, press Return" (three loops at most, then it rests).
    private var terminalHint: some View {
        TimelineView(.animation(paused: hintDone || reduce || session.frozenTime != nil)) { context in
            FirstRunTerminalHint(frame: M.terminalHint(session.hintTime(at: context.date), reduceMotion: reduce))
        }
        .task(id: session.sceneStart) {
            hintDone = false
            let total = M.terminalHintPeriod * Double(M.terminalHintLoops)
            try? await Task.sleep(for: .seconds(total / max(session.speed, 0.1) + 0.05))
            if !Task.isCancelled { hintDone = true }
        }
        .onChange(of: session.hintSkipped) { _, skipped in if skipped { hintDone = true } }
    }

    // MARK: Status line (one line under the choices: what happens next, or what happened)

    @ViewBuilder private var status: some View {
        switch flow.step {
        case .choosing:
            if !flow.missingLocked.isEmpty { note("lock.fill", "firstRun.passwordNote", info: true) } else { note("checkmark.circle", "firstRun.readyNote") }
        case .applying, .enablingLid: progress("firstRun.enabling")
        case .waitingSystem: progress("firstRun.waiting.system")
        case .waitingTerminal:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.text("firstRun.waiting.terminal")).font(.system(size: 13))
                Spacer(minLength: 8)
                if session.commandText != nil {
                    Button(L10n.text(session.showsCommand ? "firstRun.hideCommand" : "firstRun.showCommand")) { session.showsCommand.toggle() }
                        .buttonStyle(.link).font(.system(size: 12)).accessibilityIdentifier("firstRun.showCommand")
                }
            }.frame(minHeight: 20)
        case .declined: note("hand.raised", flow.route == .terminal ? "firstRun.declined.terminal" : "firstRun.declined", info: true)
        case .failed: note("exclamationmark.circle", flow.route == .terminal ? "firstRun.failed.terminal" : "firstRun.failed", info: true)
        case .timedOut: note("clock", "firstRun.timedOut", info: true)
        case .attention: attentionList
        case .done:
            HStack(spacing: 8) {
                TimelineView(.animation(paused: session.reduceMotion || session.frozenTime != nil)) { context in
                    FirstRunDoneMark(progress: M.check(session.time(at: context.date), reduceMotion: session.reduceMotion))
                }.frame(width: 18, height: 18)
                Text(L10n.text("firstRun.done")).font(.system(size: 13, weight: .semibold))
            }.frame(minHeight: 20)
        case .iconHidden:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "menubar.arrow.up.rectangle").font(.system(size: 15)).foregroundStyle(Color.accentColor).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("firstRun.iconHidden.title")).font(.system(size: 13, weight: .semibold))
                    Text(L10n.text("firstRun.iconHidden.text")).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        case .finished: EmptyView()
        }
    }

    private func note(_ symbol: String, _ key: String, info: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            Text(L10n.text(key)).font(.system(size: 13)).foregroundStyle(.secondary)
            if info { SectionInfoButton(title: L10n.text("firstRun.info.title"), paragraphs: Self.infoKeys.map(L10n.text), id: "firstRun.info") }
            Spacer(minLength: 0)
        }.frame(minHeight: 20)
    }

    private func progress(_ key: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L10n.text(key)).font(.system(size: 13))
            Spacer(minLength: 0)
        }.frame(minHeight: 20)
    }

    private var attentionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(flow.attention, id: \.self) { item in
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange).frame(width: 18).accessibilityHidden(true)
                    Text(L10n.text("firstRun.attention." + item.rawValue)).font(.system(size: 13))
                    Spacer(minLength: 8)
                    if item == .loginNeedsApproval {
                        Button(L10n.text("firstRun.openSettings")) { session.send(.openLoginSettings) }.controlSize(.small)
                            .accessibilityIdentifier("firstRun.openSettings")
                    }
                }.frame(minHeight: 22)
            }
        }
    }

    private func commandBox(_ text: String) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            ScrollView {
                Text(text).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            Button(L10n.text("firstRun.copy")) { copy(text) }
                .controlSize(.small).accessibilityIdentifier("firstRun.copy")
        }
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
    }

    // MARK: Buttons

    private var buttons: some View {
        let model = flow.buttons
        return VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 10) {
                if let secondary = model.secondary { secondaryButton(secondary) }
                Spacer(minLength: 8)
                if let primary = model.primary { primaryButton(primary) }
            }
            if model.terminalLink || flow.choicesEditable {
                // Reserved while the choices can change, so ticking a password feature never changes the height.
                Button(L10n.text("firstRun.useTerminal")) { session.send(.useTerminal) }
                    .buttonStyle(.link).font(.system(size: 12)).accessibilityIdentifier("firstRun.useTerminal")
                    .opacity(model.terminalLink ? 1 : 0).disabled(!model.terminalLink).accessibilityHidden(!model.terminalLink)
                    .animation(.easeInOut(duration: M.crossfadeDuration(reduceMotion: reduce)), value: model.terminalLink)
            }
        }
        .frame(minHeight: 34)
    }

    static func primaryKey(_ primary: FirstRunButtons.Primary) -> String {
        switch primary {
        case .start: "firstRun.start"
        case .allowAndStart: "firstRun.allowAndStart"
        case .tryAgain: "firstRun.tryAgain"
        case .openApp: "firstRun.openApp"
        }
    }
    static func secondaryKey(_ secondary: FirstRunButtons.Secondary) -> String {
        switch secondary {
        case .skip: "firstRun.skip"
        case .cancel: "firstRun.cancel"
        case .withoutPassword: "firstRun.withoutPassword"
        case .close: "firstRun.close"
        }
    }

    private func primaryButton(_ primary: FirstRunButtons.Primary) -> some View {
        Button {
            session.send(primary == .openApp ? .openDetails : .start)
        } label: {
            HStack(spacing: 6) {
                if primary == .allowAndStart || primary == .tryAgain {
                    Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)).transition(.scale(scale: 0.4).combined(with: .opacity))
                }
                Text(L10n.text(Self.primaryKey(primary))).font(.system(size: 13, weight: .semibold)).id(primary).transition(.opacity)
            }
            .animation(reduce ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.82), value: primary)
            .foregroundStyle(Color.white).padding(.horizontal, 20).frame(minWidth: 150, minHeight: 34)
            .background(Capsule().fill(Color.accentColor)).contentShape(Capsule())
        }
        .buttonStyle(.plain).keyboardShortcut(.defaultAction).accessibilityIdentifier("firstRun.primary")
    }

    private func secondaryButton(_ secondary: FirstRunButtons.Secondary) -> some View {
        Button {
            switch secondary {
            case .skip, .close: session.send(.skip)
            case .cancel: session.send(.cancel)
            case .withoutPassword: session.send(.continueWithout)
            }
        } label: {
            Text(L10n.text(Self.secondaryKey(secondary))).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.primary)
                .padding(.horizontal, 18).frame(minHeight: 34).background(Capsule().fill(Color.primary.opacity(0.07))).contentShape(Capsule())
        }
        .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityIdentifier("firstRun.secondary")
    }
}

/// The hero battery: charges up once as the window appears, its bolt gives one soft pulse, then it rests.
struct FirstRunHeroBattery: View {
    var frame: FirstRunMotion.Hero
    var body: some View {
        let light = M.segment(frame.fill, 0.45, 0.65)   // the bolt turns white once the fill is under it
        HStack(spacing: 2) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 2.5)
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor.gradient)
                    .frame(width: max(5, 42 * frame.fill), height: 20).padding(.leading, 5)
                ZStack {
                    Image(systemName: "bolt.fill").foregroundStyle(Color.accentColor).opacity(1 - light)
                    Image(systemName: "bolt.fill").foregroundStyle(Color.white).opacity(light)
                }
                .font(.system(size: 16, weight: .bold))
                .shadow(color: Color.accentColor.opacity(0.7 * frame.glow), radius: 7 * frame.glow)
                .scaleEffect(frame.bolt)
                .frame(maxWidth: .infinity)
            }
            .frame(width: 52, height: 30)
            Capsule().fill(Color.accentColor.opacity(0.9)).frame(width: 3.5, height: 11)
        }
        .accessibilityHidden(true)
    }
}

/// A flat illustration (not a picture of Terminal): password dots fill in, the Return key is pressed, a check.
struct FirstRunTerminalHint: View {
    var frame: FirstRunMotion.TerminalHint
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "key.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(0..<6, id: \.self) { i in
                    Circle().fill(Color.primary.opacity(i < frame.dots ? 0.7 : 0.13)).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 0.5, y: 1.5 * (1 - frame.press))
                RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                Image(systemName: "return").font(.system(size: 13, weight: .semibold))
            }
            .frame(width: 46, height: 30).offset(y: 1.5 * frame.press).scaleEffect(1 - 0.05 * frame.press)
            Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(Color.green)
                .opacity(frame.done).scaleEffect(0.7 + 0.3 * frame.done)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
        .accessibilityHidden(true)
    }
}
