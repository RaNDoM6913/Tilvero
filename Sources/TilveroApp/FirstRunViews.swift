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
        Row(id: "limit", title: "firstRun.chargeLimit", detail: "firstRun.chargeLimit.detail", symbol: "battery.75percent", path: \.chargeLimit),
        Row(id: "lid", title: "firstRun.lidClosed", detail: "firstRun.lidClosed.detail", symbol: "laptopcomputer", path: \.lidClosed, feature: .lidClosed),
        Row(id: "chargeBy", title: "firstRun.chargeByTime", detail: "firstRun.chargeByTime.detail", symbol: "alarm", path: \.chargeByTime, feature: .chargeByTime),
    ]
    static let infoKeys = ["firstRun.info.what", "firstRun.info.password"]

    private var flow: FirstRunFlow { session.flow }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            choices
            status
            if session.showsCommand, flow.step == .waitingTerminal, let text = session.commandText { commandBox(text) }
            buttons
        }
        .padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 22)
        .frame(width: Self.width, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, L10n.locale)
        .animation(session.reduceMotion ? nil : .easeInOut(duration: M.crossfadeDuration(reduceMotion: false)), value: flow.step)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("firstRun.window")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "battery.100percent.bolt").font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color.accentColor).symbolRenderingMode(.hierarchical).accessibilityHidden(true)
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

    private var choices: some View {
        VStack(spacing: 0) {
            ForEach(Array(Self.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.leading, 40) }
                choiceRow(row)
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
                    if let feature = row.feature { badge(granted: flow.granted.contains(feature)) }
                }
                Text(L10n.text(row.detail)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(L10n.text(row.title), isOn: binding).toggleStyle(.switch).tint(Color.accentColor).labelsHidden().controlSize(.regular).fixedSize()
                .accessibilityIdentifier("firstRun.toggle." + row.id)
        }
        .padding(.vertical, 9)
    }

    private func badge(granted: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: granted ? "checkmark" : "lock.fill").font(.system(size: 8, weight: .bold))
            Text(L10n.text(granted ? "firstRun.badge.allowed" : "firstRun.badge.password")).font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(granted ? Color.green : Color.secondary)
        .padding(.horizontal, 6).padding(.vertical, 1.5)
        .background(Capsule().fill((granted ? Color.green : Color.primary).opacity(granted ? 0.14 : 0.08)))
        .accessibilityElement(children: .combine)
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
        case .declined: note("hand.raised", "firstRun.declined", info: true)
        case .failed: note("exclamationmark.circle", flow.route == .terminal && flow.failureCode == 1 ? "firstRun.failed.password" : "firstRun.failed", info: true)
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
            if model.terminalLink {
                Button(L10n.text("firstRun.useTerminal")) { session.send(.useTerminal) }
                    .buttonStyle(.link).font(.system(size: 12)).accessibilityIdentifier("firstRun.useTerminal")
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
                if primary == .allowAndStart || primary == .tryAgain { Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)) }
                Text(L10n.text(Self.primaryKey(primary))).font(.system(size: 13, weight: .semibold))
            }
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

// MARK: Coach on the real quick panel

/// After setup, when the charge limit was chosen: a capsule under the real Charge tab says where it is. Never takes
/// clicks; it ends by itself, on the first pointer movement over the panel, or when the panel closes.
struct FirstRunCoachLayer: View {
    static let space = "firstRunCoach"

    /// Adds the Charge tab's frame, an equal segment of the full-width tabs.
    static func chargeTab(in frames: [String: CGRect], sections: [QuickPanelSection]) -> CGRect? {
        guard let tabs = frames["tabs"], let index = sections.firstIndex(of: .charge), !sections.isEmpty else { return nil }
        let width = tabs.width / CGFloat(sections.count)
        return CGRect(x: tabs.minX + width * CGFloat(index), y: tabs.minY, width: width, height: tabs.height)
    }

    @ObservedObject var session: FirstRunSession
    var tab: CGRect?
    static let capsuleWidth: CGFloat = 190
    /// Under the tab, kept inside the panel.
    static func capsuleCenter(tab: CGRect, width: CGFloat) -> CGFloat {
        min(max(tab.midX, capsuleWidth / 2 + 8), max(capsuleWidth / 2 + 8, width - capsuleWidth / 2 - 8))
    }

    var body: some View {
        let visible = session.coachVisible && tab != nil
        TimelineView(.animation(paused: !visible || session.frozenTime != nil)) { context in
            if visible, let tab {
                let f = M.coach(session.coachTime(at: context.date), reduceMotion: session.reduceMotion)
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.accentColor.opacity(0.6 * (1 - f.pulse)), lineWidth: 2)
                            .frame(width: tab.width + 8 * f.pulse, height: tab.height + 8 * f.pulse)
                            .position(x: tab.midX, y: tab.midY)
                            .opacity(f.pulse > 0 ? 1 : 0)
                        VStack(spacing: 0) {
                            FirstRunCaret().fill(Color.accentColor).frame(width: 12, height: 6)
                                .offset(x: tab.midX - Self.capsuleCenter(tab: tab, width: proxy.size.width))
                            Text(L10n.text("firstRun.coach")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(Color.accentColor)).fixedSize()
                        }
                        .frame(width: Self.capsuleWidth)
                        .position(x: Self.capsuleCenter(tab: tab, width: proxy.size.width), y: tab.maxY + 18)
                    }
                }
                .opacity(f.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct FirstRunCaret: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.closeSubpath(); return p
    }
}

/// The coach stops as soon as the pointer really moves over the panel (the user has taken over).
struct FirstRunHoverDismissal: ViewModifier {
    var session: FirstRunSession?
    @State private var firstPoint: CGPoint?
    func body(content: Content) -> some View {
        if let session {
            content.onContinuousHover { phase in
                guard case .active(let point) = phase, session.coachVisible else { return }
                if let first = firstPoint { if hypot(point.x - first.x, point.y - first.y) > 10 { session.showCoach(false) } }
                else { firstPoint = point }
            }
        } else { content }
    }
}
