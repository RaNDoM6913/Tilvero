// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI

private typealias M = FirstRunMotion

// MARK: Drawn pieces

struct FirstRunCursorShape: Shape {
    func path(in r: CGRect) -> Path {
        let points: [(Double, Double)] = [(0, 0), (0, 17), (4.2, 13.2), (7, 19.5), (9.6, 18.4), (6.8, 12.4), (12.5, 12.4)]
        var p = Path()
        for (i, q) in points.enumerated() {
            let point = CGPoint(x: r.minX + q.0 / 12.5 * r.width, y: r.minY + q.1 / 19.5 * r.height)
            i == 0 ? p.move(to: point) : p.addLine(to: point)
        }
        p.closeSubpath(); return p
    }
}

/// Guide cursor; the tip sits at `frame.point` in the parent's top-leading space. Never takes clicks.
struct FirstRunGuideCursor: View {
    var frame: FirstRunMotion.CursorFrame
    var body: some View {
        ZStack(alignment: .topLeading) {
            if frame.ripple > 0 && frame.ripple < 1 {
                let d = 6 + 34 * frame.ripple
                Circle().stroke(Color.accentColor.opacity(0.5 * (1 - frame.ripple)), lineWidth: 2)
                    .frame(width: d, height: d).offset(x: frame.point.x - d / 2, y: frame.point.y - d / 2)
            }
            FirstRunCursorShape().fill(Color.white).overlay(FirstRunCursorShape().stroke(Color.accentColor, lineWidth: 1.5))
                .frame(width: 15, height: 23).shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .scaleEffect(1 - 0.12 * frame.press, anchor: .topLeading).offset(x: frame.point.x, y: frame.point.y)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(frame.opacity).allowsHitTesting(false).accessibilityHidden(true)
    }
}

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

struct FirstRunCaret: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.closeSubpath(); return p
    }
}

private func plaque(_ width: CGFloat, _ height: CGFloat = 8, _ opacity: Double = 0.16) -> some View {
    Capsule().fill(Color.primary.opacity(opacity)).frame(width: width, height: height)
}

/// The real menu bar battery image (the same `NativeBatteryStatusImage` frames), drawn as a template in the scene.
struct FirstRunBatteryGlyph: View {
    var level: Int = 100
    var height: CGFloat = 15
    var body: some View {
        let image = NativeBatteryStatusImage.make(level: level, style: .inside, externalPower: true, scale: 3, highlighted: true, appearance: .macOS27)
        Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high)
            .aspectRatio(image.size, contentMode: .fit).frame(height: height).foregroundStyle(Color.primary)
    }
}

// MARK: Window scenes

struct FirstRunWhereScene: View {
    var t: Double
    var reduceMotion: Bool
    var jumpedToEnd: Bool
    var body: some View {
        let f = M.whereScene(t, reduceMotion: reduceMotion, jumpedToEnd: jumpedToEnd)
        let icon = M.whereIconCenter
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)).frame(width: M.whereCanvas.width, height: 30)
                .overlay {
                    ZStack(alignment: .topLeading) {
                        Image(systemName: "apple.logo").font(.system(size: 12)).position(x: 20, y: 15)
                        plaque(44).position(x: 70, y: 15)
                        plaque(60).position(x: 438, y: 15)
                        Image(systemName: "wifi").font(.system(size: 11)).foregroundStyle(.secondary).position(x: 396, y: 15)
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.14 * f.highlight))
                            .frame(width: 52, height: 22).position(x: icon.x, y: icon.y)
                        FirstRunBatteryGlyph().position(x: icon.x, y: icon.y)
                    }
                }
                .offset(y: (f.barIn - 1) * 10).opacity(f.barIn)
            ZStack(alignment: .top) {
                FirstRunCaret().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 14, height: 7)
                miniPopover.offset(y: 6)
            }
            .frame(width: 180, height: 140, alignment: .top)
            .scaleEffect(0.6 + 0.4 * f.popover, anchor: .top).opacity(M.clamp01(f.popover * 2))
            .position(x: icon.x, y: 104)
            FirstRunGuideCursor(frame: .init(point: f.cursor, opacity: f.cursorOpacity, press: f.press, ripple: f.ripple))
        }
        .frame(width: M.whereCanvas.width, height: M.whereCanvas.height, alignment: .topLeading)
    }
    private var miniPopover: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { plaque(70, 9, 0.28); Spacer() }
            HStack { plaque(80); Spacer(); miniSwitch }
            HStack { plaque(60); Spacer(); miniSwitch }
            Capsule().fill(Color.accentColor).frame(height: 20)
        }
        .padding(12).frame(width: 170)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.14), radius: 8, y: 3))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
    }
    private var miniSwitch: some View {
        Capsule().fill(Color.accentColor).frame(width: 24, height: 14)
            .overlay(alignment: .trailing) { Circle().fill(Color.white).frame(width: 11, height: 11).padding(.trailing, 1.5) }
    }
}

struct FirstRunHiddenScene: View {
    var t: Double
    var reduceMotion: Bool
    var jumpedToEnd: Bool
    var body: some View {
        let f = M.hiddenScene(t, reduceMotion: reduceMotion, jumpedToEnd: jumpedToEnd)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)).frame(width: M.whereCanvas.width, height: 30)
                .overlay {
                    ZStack(alignment: .topLeading) {
                        Image(systemName: "apple.logo").font(.system(size: 12)).position(x: 20, y: 15)
                        plaque(44).position(x: 70, y: 15)
                        FirstRunBatteryGlyph().position(x: f.iconX, y: 15)
                        plaque(22, 10, 0.2).position(x: 392, y: 15).opacity(1 - f.drag)
                        plaque(22, 10, 0.2).position(x: 436, y: 15)
                        UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12).fill(Color.black)
                            .frame(width: 110, height: 24 * f.notch).position(x: 240, y: 12 * f.notch)
                    }
                }
                .opacity(f.notch)
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.25 + 0.4 * f.keyDown), lineWidth: 1))
                .overlay(Text("⌘").font(.system(size: 22, weight: .medium)))
                .frame(width: 52, height: 46).scaleEffect(1 - 0.06 * f.keyDown).position(x: 60, y: 188)
            // The neighbouring icon travels with the cursor while ⌘ is held, then disappears off the bar.
            plaque(22, 10, 0.3).position(x: f.cursor.x - 3, y: f.cursor.y - 5)
                .opacity(f.drag > 0 && f.drag < 1 ? 1 - 0.5 * f.drag : 0)
            FirstRunGuideCursor(frame: .init(point: f.cursor, opacity: f.cursorOpacity, press: f.keyDown > 0 ? 1 : 0, ripple: 0))
        }
        .frame(width: M.whereCanvas.width, height: M.whereCanvas.height, alignment: .topLeading)
    }
}

/// Drawn, generic Touch ID / password preview. Not a copy of the system dialog.
struct FirstRunTouchPreview: View {
    var t: Double
    var reduceMotion: Bool
    var body: some View {
        let f = M.touchPreview(t, reduceMotion: reduceMotion)
        HStack(spacing: 14) {
            dialog.scaleEffect(0.9 + 0.1 * f.dialog).opacity(f.dialog)
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor.opacity(0.2 + 0.6 * f.glow), lineWidth: 1.5))
                    .shadow(color: Color.accentColor.opacity(0.35 * f.glow), radius: 8)
                ForEach(0..<3, id: \.self) { i in
                    Circle().trim(from: 0.14, to: 0.14 + 0.72 * f.rings).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: CGFloat(10 + i * 8), height: CGFloat(10 + i * 8)).rotationEffect(.degrees(-90 + Double(i) * 25))
                }
                Capsule().fill(Color.primary.opacity(0.22)).frame(width: 14, height: 24)
                    .offset(y: -22 * (1 - f.finger) - 2).opacity(f.finger * (1 - f.glow))
            }
            .frame(width: 44, height: 44).scaleEffect(0.8 + 0.2 * f.key).opacity(f.key)
        }
        .frame(height: 96).frame(maxWidth: .infinity)
        .scaleEffect(1 - 0.25 * f.collapse).opacity(1 - f.collapse)
        .accessibilityHidden(true)
    }
    private var dialog: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(Color.accentColor.opacity(0.18)).frame(width: 22, height: 22)
                    .overlay(Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Color.accentColor))
                VStack(alignment: .leading, spacing: 4) { plaque(76, 7, 0.3); plaque(52, 6) }
                Spacer()
            }
            RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)).frame(height: 18)
                .overlay(HStack(spacing: 4) { ForEach(0..<6, id: \.self) { _ in Circle().fill(Color.primary.opacity(0.5)).frame(width: 4, height: 4) }; Spacer() }.padding(.leading, 8))
            HStack(spacing: 6) { Capsule().fill(Color.primary.opacity(0.1)).frame(height: 16); Capsule().fill(Color.accentColor).frame(height: 16) }
        }
        .padding(10).frame(width: 190)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.14), radius: 6, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
    }
}

// MARK: First-run window

struct FirstRunWindowView: View {
    @ObservedObject var session: FirstRunSession
    var body: some View {
        Group {
            if session.flow.hostedInWindow && session.flow.cardVisible {
                FirstRunCard(session: session).frame(width: QuickPanelMetrics.width - 2 * QuickPanelMetrics.padding).padding(24)
            } else {
                scenes
            }
        }
        .environment(\.locale, L10n.locale)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var hidden: Bool { session.step == .hiddenIcon }

    private var scenes: some View {
        VStack(spacing: 16) {
            VStack(spacing: 5) {
                Text(L10n.text(hidden ? "firstRun.window.hidden.title" : "firstRun.window.title")).font(.system(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.text(hidden ? "firstRun.window.hidden.subtitle" : "firstRun.window.subtitle")).font(.system(size: 14)).foregroundStyle(.secondary)
                if session.isPreview { FirstRunPreviewBadge() }
            }
            let loop = hidden ? M.hiddenLoop : M.whereLoop
            TimelineView(.animation(paused: !session.windowOnScreen
                                    || loop.isFrozen(session.time(at: Date()), reduceMotion: session.reduceMotion, jumpedToEnd: session.jumpedToEnd))) { context in
                let t = session.time(at: context.date)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04))
                    if hidden {
                        FirstRunHiddenScene(t: t, reduceMotion: session.reduceMotion, jumpedToEnd: session.jumpedToEnd)
                    } else {
                        FirstRunWhereScene(t: t, reduceMotion: session.reduceMotion, jumpedToEnd: session.jumpedToEnd)
                    }
                }
                .frame(width: M.whereCanvas.width, height: M.whereCanvas.height)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .id(session.step)
            .transition(.opacity)
            .contentShape(Rectangle())
            .onTapGesture { session.jumpedToEnd = true }
            // After the last loop the scene rests on its explanatory frame and the timeline stops.
            .task(id: session.sceneStart) {
                try? await Task.sleep(for: .seconds(loop.totalDuration / max(session.speed, 0.1)))
                if !Task.isCancelled { session.jumpedToEnd = true }
            }
            .accessibilityElement()
            .accessibilityLabel(L10n.text(hidden ? "firstRun.window.hidden.accessibility" : "firstRun.window.accessibility"))
            .accessibilityAddTraits(.isImage)
            HStack(spacing: 12) {
                Button(L10n.text(hidden ? "firstRun.back" : "firstRun.cantSeeIcon")) { session.send(hidden ? .backFromHidden : .showHidden) }
                    .buttonStyle(.link)
                Spacer()
                if hidden { Button(L10n.text("firstRun.openHere")) { session.send(.openHere) } }
                Button(L10n.text("firstRun.skip")) { session.send(.skip) }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 528)
        .animation(.easeInOut(duration: M.crossfadeDuration(reduceMotion: session.reduceMotion)), value: session.step)
    }
}

struct FirstRunPreviewBadge: View {
    var body: some View {
        Text(L10n.text("firstRun.preview")).font(.caption2.weight(.semibold)).foregroundStyle(.orange)
            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.orange.opacity(0.15)))
    }
}

// MARK: Card

/// The card on top of the real Overview (or inside the window for "Open here").
struct FirstRunCard: View {
    @ObservedObject var session: FirstRunSession

    var body: some View {
        Group {
            switch session.step {
            case .confirmPreview, .systemPrompt: confirmCard
            case .done: doneCard
            case .declined: declinedCard
            default: startCard
            }
        }
        .metricCardChrome()
        .animation(session.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9), value: session.flow.choices.moreExpanded)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("firstRun.card")
    }

    private func header(_ key: String, symbol: String, tint: Color = .accentColor, close: Bool = true) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(tint).accessibilityHidden(true)
            Text(L10n.text(key)).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            if session.isPreview { FirstRunPreviewBadge() }
            Spacer(minLength: 8)
            if close {
                Button { session.send(.dismissCard) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).focusEffectDisabled().accessibilityLabel(L10n.text("firstRun.close"))
            }
        }
    }

    private func toggleRow(_ key: String, _ value: Binding<Bool>, locked: Bool = false, id: String) -> some View {
        HStack(spacing: 6) {
            Text(L10n.text(key)).font(.system(size: 13, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
            if locked { Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.secondary).accessibilityLabel(L10n.text("firstRun.needsPermission")) }
            Spacer(minLength: 8)
            Toggle(L10n.text(key), isOn: value).toggleStyle(.switch).tint(Color.accentColor).controlSize(.regular).labelsHidden().fixedSize()
                .accessibilityIdentifier(id)
        }
        .frame(height: 30)
    }

    private func choice(_ path: WritableKeyPath<FirstRunChoices, Bool>) -> Binding<Bool> {
        Binding(get: { session.flow.choices[keyPath: path] }, set: { session.flow.choices[keyPath: path] = $0 })
    }

    private func primaryButton(_ key: String, lock: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if lock { Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)) }
                Text(L10n.text(key)).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Color.white).frame(maxWidth: .infinity, minHeight: 32).background(Capsule().fill(Color.accentColor))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).keyboardShortcut(.defaultAction)
    }

    private func secondaryButton(_ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(L10n.text(key)).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, minHeight: 32).background(Capsule().fill(Color.primary.opacity(0.07))).contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func pill(_ key: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(L10n.text(key)).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.primary)
                .padding(.horizontal, 12).frame(height: 26).background(Capsule().fill(Color.primary.opacity(0.08))).contentShape(Capsule())
        }
        .buttonStyle(.plain).accessibilityIdentifier(id)
    }

    // MARK: States

    private var startCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            header("firstRun.card.title", symbol: "battery.100percent.bolt")
            toggleRow("firstRun.launchAtLogin", choice(\.launchAtLogin), id: "firstRun.login")
            toggleRow("firstRun.keepHistory", choice(\.keepHistory), id: "firstRun.history")
            Button { session.flow.choices.moreExpanded.toggle() } label: {
                HStack {
                    Text(L10n.text("firstRun.more")).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(session.flow.choices.moreExpanded ? 90 : 0))
                }
                .frame(height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .accessibilityValue(L10n.text(session.flow.choices.moreExpanded ? "firstRun.expanded" : "firstRun.collapsed"))
            .accessibilityIdentifier("firstRun.more")
            if session.flow.choices.moreExpanded {
                Divider()
                toggleRow("firstRun.chargeLimit", choice(\.chargeLimit), id: "firstRun.limit")
                toggleRow("firstRun.lidClosed", choice(\.lidClosed), locked: true, id: "firstRun.lid")
                toggleRow("firstRun.chargeByTime", choice(\.chargeByTime), locked: true, id: "firstRun.chargeBy")
            }
            primaryButton("firstRun.done", lock: session.flow.choices.doneNeedsPermission) { session.send(.done) }
                .padding(.top, 4).firstRunFrame("done").accessibilityIdentifier("firstRun.doneButton")
        }
    }

    private var confirmCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.animation(paused: session.step != .systemPrompt || session.reduceMotion)) { context in
                let breathe = session.step == .systemPrompt && !session.reduceMotion ? 0.8 + 0.2 * sin(session.time(at: context.date) * 2 * .pi / 1.6) : 1
                header("firstRun.confirm.title", symbol: "touchid", close: false).opacity(breathe)
            }
            HStack(spacing: 6) {
                Text(L10n.text("firstRun.confirm.subtitle")).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SectionInfoButton(title: L10n.text("firstRun.info.title"), paragraphs: Self.infoKeys.map(L10n.text), id: "firstRun.info")
            }
            .padding(.bottom, 6)
            if session.step == .confirmPreview {
                TimelineView(.animation(paused: session.reduceMotion)) { context in
                    FirstRunTouchPreview(t: session.time(at: context.date), reduceMotion: session.reduceMotion)
                }
                .contentShape(Rectangle())
                .onTapGesture { session.send(.previewFinished) }
            }
            secondaryButton("firstRun.cancel") { session.send(.cancelConfirmation) }.accessibilityIdentifier("firstRun.cancel")
        }
    }

    static let infoKeys = ["firstRun.info.what", "firstRun.info.password"]

    private struct Row: Identifiable { var id: String; var key: String; var trailing: (key: String, action: () -> Void)?; var neutral = false }

    private var doneRows: [Row] {
        let flow = session.flow, choices = flow.choices
        var rows: [Row] = []
        if choices.launchAtLogin {
            switch flow.loginResult {
            case .requiresApproval:
                rows.append(Row(id: "login", key: "firstRun.row.login", trailing: ("firstRun.allow", { session.perform(.openLoginItemsSettings) }), neutral: true))
            case .failed: break
            default: rows.append(Row(id: "login", key: "firstRun.row.login"))
            }
        }
        if choices.keepHistory { rows.append(Row(id: "history", key: "firstRun.row.history")) }
        if flow.granted.contains(.lidClosed) && choices.lidClosed { rows.append(Row(id: "lid", key: "firstRun.lidClosed")) }
        if flow.granted.contains(.chargeByTime) && choices.chargeByTime { rows.append(Row(id: "chargeBy", key: "firstRun.chargeByTime")) }
        return rows
    }

    private var doneCard: some View {
        TimelineView(.animation(paused: session.reduceMotion)) { context in
            let t = session.time(at: context.date)
            VStack(alignment: .leading, spacing: 6) {
                header("firstRun.done.title", symbol: "checkmark.circle.fill", tint: .green)
                let rows = doneRows
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 8) {
                        if row.neutral {
                            Image(systemName: "circle.dotted").font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 18)
                        } else {
                            FirstRunDoneMark(progress: M.check(index, t, reduceMotion: session.reduceMotion))
                        }
                        Text(L10n.text(row.key)).font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 8)
                        if let trailing = row.trailing { pill(trailing.key, id: "firstRun.allow", action: trailing.action) }
                    }
                    .frame(height: 30)
                }
                if session.flow.choices.chargeLimit {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.dotted").font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
                        Text(L10n.text("firstRun.chargeLimit")).font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 8)
                        pill("firstRun.check", id: "firstRun.checkLimit") { session.requestedSection = .charge }.firstRunFrame("check")
                    }
                    .frame(height: 30)
                }
            }
        }
    }

    private var declinedCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(session.flow.promptFailed ? "firstRun.failed.title" : "firstRun.declined.title", symbol: "lock.open", tint: .secondary)
            if session.flow.choices.launchAtLogin {
                HStack(spacing: 8) { FirstRunDoneMark(progress: 1); Text(L10n.text("firstRun.row.login")).font(.system(size: 13, weight: .medium)); Spacer() }.frame(height: 30)
            }
            if session.flow.choices.keepHistory {
                HStack(spacing: 8) { FirstRunDoneMark(progress: 1); Text(L10n.text("firstRun.row.history")).font(.system(size: 13, weight: .medium)); Spacer() }.frame(height: 30)
            }
            ForEach(session.flow.missingLocked, id: \.self) { feature in
                HStack(spacing: 8) {
                    Image(systemName: "lock").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
                    Text(L10n.text(feature == .lidClosed ? "firstRun.lidClosed" : "firstRun.chargeByTime")).font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 8)
                    pill("firstRun.turnOn", id: "firstRun.turnOn.\(feature.rawValue)") { session.send(.enable(feature)) }
                }
                .frame(height: 30)
            }
            primaryButton("firstRun.done") { session.send(.done) }.padding(.top, 4)
        }
    }
}

// MARK: Card + guide inside the quick panel

/// Hosts the card at the top of the real quick panel and plays the guide cursor over it. Never intercepts clicks.
struct FirstRunPanelLayer: View {
    @ObservedObject var session: FirstRunSession
    @Binding var section: QuickPanelSection

    var body: some View {
        Group {
            if session.flow.cardVisible && !session.flow.hostedInWindow {
                FirstRunCard(session: session).transition(.opacity)
            }
        }
        .onChange(of: session.requestedSection) { _, requested in
            guard let requested else { return }
            section = requested
            session.requestedSection = nil
        }
    }
}

/// The guide stops as soon as the pointer really moves over the panel (the user has taken over).
struct FirstRunHoverDismissal: ViewModifier {
    var session: FirstRunSession?
    @State private var firstPoint: CGPoint?
    func body(content: Content) -> some View {
        if let session {
            content.onContinuousHover { phase in
                guard case .active(let point) = phase, !session.guideDismissed else { return }
                if let first = firstPoint { if hypot(point.x - first.x, point.y - first.y) > 10 { session.guideDismissed = true } }
                else { firstPoint = point }
            }
        } else { content }
    }
}

struct FirstRunGuideLayer: View {
    static let space = "firstRunGuide"

    /// Adds the Charge tab's frame, an equal segment of the full-width tabs.
    static func withTabs(_ frames: [String: CGRect], sections: [QuickPanelSection]) -> [String: CGRect] {
        guard let tabs = frames["tabs"], let index = sections.firstIndex(of: .charge), !sections.isEmpty else { return frames }
        var result = frames
        let width = tabs.width / CGFloat(sections.count)
        result["tab.charge"] = CGRect(x: tabs.minX + width * CGFloat(index), y: tabs.minY, width: width, height: tabs.height)
        return result
    }
    @ObservedObject var session: FirstRunSession
    var frames: [String: CGRect]

    var body: some View {
        let playing = active
        TimelineView(.animation(paused: !playing)) { context in
            if playing { cursor(session.time(at: context.date)) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // Played once per scene: afterwards the timeline stops for good (no per-frame work while the panel stays open).
        .task(id: session.sceneStart) {
            let length = session.step == .done ? 1.0 + M.guideDuration + 1.2 : M.guideDuration
            try? await Task.sleep(for: .seconds(length / max(session.speed, 0.1) + 0.1))
            if !Task.isCancelled { session.guideDismissed = true }
        }
    }

    private var active: Bool {
        guard !session.guideDismissed, !session.flow.hostedInWindow else { return false }
        let t = session.time(at: Date())
        switch session.step {
        case .card: return !session.flow.choices.moreExpanded && t < M.guideDuration && frames["done"] != nil
        case .done: return session.flow.choices.chargeLimit && t < 1.0 + M.guideDuration + 1.2 && frames["check"] != nil && frames["tab.charge"] != nil
        default: return false
        }
    }

    @ViewBuilder private func cursor(_ t: Double) -> some View {
        switch session.step {
        case .card:
            if let done = frames["done"] {
                FirstRunGuideCursor(frame: M.guide(t, from: CGPoint(x: 150, y: 34), to: CGPoint(x: done.midX + 40, y: done.midY + 4), reduceMotion: session.reduceMotion))
            }
        case .done:
            if let check = frames["check"], let tab = frames["tab.charge"] {
                let bubble = M.segment(t, 1.7, 1.85) * (1 - M.segment(t, 3.0, 3.3))
                ZStack(alignment: .topLeading) {
                    FirstRunGuideCursor(frame: M.guide(t, from: CGPoint(x: check.midX, y: check.midY), to: CGPoint(x: tab.midX, y: tab.midY + 4),
                                                       delay: 0.8, reduceMotion: session.reduceMotion))
                    Text(L10n.text("firstRun.limitCoach")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(Color.accentColor)).fixedSize()
                        .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, QuickPanelMetrics.padding)
                        .opacity(bubble).offset(y: tab.maxY + 8 - 4 * (1 - bubble))
                }
            }
        default: EmptyView()
        }
    }
}

// MARK: Beacon and bubble (non-activating, mouse-transparent panels under the real icon)

struct FirstRunBeaconView: View {
    var start: Date
    var reduceMotion: Bool
    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSince(start)
            let f = M.beacon(t, reduceMotion: reduceMotion)
            ZStack(alignment: .top) {
                Circle().stroke(Color.accentColor.opacity(0.4 * (1 - f.ring)), lineWidth: 2)
                    .frame(width: 30 + 26 * f.ring, height: 30 + 26 * f.ring).offset(y: -4 - 13 * f.ring).opacity(f.ring > 0 ? 1 : 0)
                Image(systemName: "arrowtriangle.up.fill").font(.system(size: 16)).foregroundStyle(Color.accentColor)
                    .offset(y: 14 + 4 * (f.bob + 1) / 2)
            }
            .frame(width: 80, height: 70, alignment: .top)
        }
        .accessibilityHidden(true)
    }
}

struct FirstRunBubbleView: View {
    var start: Date
    var reduceMotion: Bool
    var body: some View {
        TimelineView(.animation) { context in
            let f = M.bubble(context.date.timeIntervalSince(start), reduceMotion: reduceMotion)
            ZStack(alignment: .top) {
                ForEach(0..<2, id: \.self) { i in
                    let r = f.rings[i]
                    Circle().stroke(Color.accentColor.opacity(r > 0 ? 0.5 * (1 - r) : 0), lineWidth: 2)
                        .frame(width: 24 + 44 * r, height: 24 + 44 * r).offset(y: 4 - 22 * r)
                }
                VStack(spacing: 0) {
                    FirstRunCaret().fill(Color.accentColor).frame(width: 14, height: 7)
                    Text(L10n.text("firstRun.bubble")).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8).background(Capsule().fill(Color.accentColor)).fixedSize()
                }
                .opacity(f.opacity).offset(y: 26)
            }
            .frame(width: 220, height: 100, alignment: .top)
        }
        .environment(\.locale, L10n.locale)
    }
}
