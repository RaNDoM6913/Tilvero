// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import SwiftUI
import PowerCore

/// The editing rules of the presets editor, pure so they are tested without a view (IA §5 "Validation").
enum QuickPresetEdit {
    enum Verdict: Equatable {
        case valid(Int)
        /// Not a value of this row (empty field, hours over 24, minutes over 59, zero, over 24 h, an illegal level).
        case invalid
        /// Already in the row at this index; the existing chip is highlighted.
        case duplicate(Int)
        /// The row is at its maximum (adding only).
        case full
    }

    /// Hours 0–24 and minutes 0–59 typed in the inline row; the total must be 1 min–24 h.
    static func minutes(hours: String, minutes: String) -> Int? {
        let h = hours.trimmingCharacters(in: .whitespaces), m = minutes.trimmingCharacters(in: .whitespaces)
        guard !(h.isEmpty && m.isEmpty) else { return nil }
        guard let hourValue = h.isEmpty ? 0 : Int(h), let minuteValue = m.isEmpty ? 0 : Int(m),
              (0...24).contains(hourValue), (0...59).contains(minuteValue) else { return nil }
        let total = hourValue * 60 + minuteValue
        return (1...1440).contains(total) ? total : nil
    }

    /// `editing` is the index of the chip being changed, `nil` when adding.
    static func verdict(_ value: Int?, row: QuickPresets.Row, in values: [Int], editing: Int?) -> Verdict {
        if editing == nil, values.count >= row.maximum { return .full }
        guard let value, row.accepts(value) else { return .invalid }
        if let index = values.firstIndex(of: value), index != editing { return .duplicate(index) }
        return .valid(value)
    }

    /// The row after the edit (normalised: sorted, unique, cut to the maximum).
    static func applying(_ value: Int, row: QuickPresets.Row, to values: [Int], editing: Int?) -> [Int] {
        var next = values
        if let editing, next.indices.contains(editing) { next[editing] = value } else { next.append(value) }
        return QuickPresets.normalize(next, row: row)
    }

    /// The last chip of a row stays.
    static func canRemove(_ values: [Int]) -> Bool { values.count > 1 }
    static func removing(at index: Int, row: QuickPresets.Row, from values: [Int]) -> [Int] {
        guard canRemove(values), values.indices.contains(index) else { return values }
        var next = values; next.remove(at: index)
        return QuickPresets.normalize(next, row: row)
    }
    static func canAdd(_ values: [Int], row: QuickPresets.Row) -> Bool { values.count < row.maximum }

    /// Levels the row may still take, in display order.
    static func freeLevels(row: QuickPresets.Row, in values: [Int]) -> [Int] {
        row.legalLevels.filter { !values.contains($0) }
    }

    /// Fixed tail pills: never removable in step 1.
    static func fixedTail(_ row: QuickPresets.Row) -> [(label: String, spoken: String)] {
        switch row {
        case .sleepTimer: [(L10n.text("Custom timer time"), L10n.text("Custom timer time"))]
        case .keepAwake: [("∞", L10n.text("Until stopped")), (L10n.text("Until…"), L10n.text("Until…"))]
        case .overviewAwake: [("∞", L10n.text("Until stopped"))]
        case .sleepAtCharge, .awakeUntilCharge: []
        }
    }

    static func chipLabel(_ value: Int, row: QuickPresets.Row) -> String {
        row.kind == .level ? PresetLabel.level(value) : PresetLabel.duration(value, form: row == .overviewAwake ? .narrow : .standard)
    }
    static func spoken(_ value: Int, row: QuickPresets.Row) -> String {
        row.kind == .level ? PresetLabel.spokenLevel(value) : PresetLabel.spokenDuration(value)
    }

    /// VoiceOver names of a chip's two buttons and of a fixed chip.
    static func editLabel(_ value: Int, row: QuickPresets.Row) -> String { L10n.text("Change") + " " + spoken(value, row: row) }
    static func removeLabel(_ value: Int, row: QuickPresets.Row) -> String { L10n.text("Remove") + " " + spoken(value, row: row) }
    static func lockedLabel(_ spoken: String) -> String { spoken + ", " + L10n.text("cannot be removed") }

    static func title(_ row: QuickPresets.Row) -> String {
        switch row {
        case .sleepTimer: L10n.text("Sleep timer")
        case .keepAwake: L10n.text("Keep Awake")
        case .sleepAtCharge: L10n.text("Sleep at charge")
        case .awakeUntilCharge: L10n.text("Keep awake until charge")
        case .overviewAwake: L10n.text("Overview: Keep Awake")
        }
    }
    static func info(_ row: QuickPresets.Row) -> [String] {
        let first: String = switch row {
        case .sleepTimer: L10n.text("Sleep timer pills in the quick menu, up to 7. Custom always stays for any other time.")
        case .keepAwake: L10n.text("Keep Awake pills in the quick menu, up to 6. ∞ and Until… always stay.")
        case .sleepAtCharge: L10n.text("Sleep at charge levels, up to 6, from 5 to 95 %. Levels at or above the current charge are unavailable.")
        case .awakeUntilCharge: L10n.text("Keep awake until charge levels, up to 6, from 5 to 95 %. Levels at or above the current charge are unavailable.")
        case .overviewAwake: L10n.text("The Keep Awake strip of the quick Overview, up to 4. ∞ always stays.")
        }
        return [first, L10n.text("Pills are sorted automatically. Editing never changes a running session.")]
    }
}

/// Settings › Quick menu: «Блоки обзора · Пресеты сна». Blocks is today's builder; Presets edits the five pill rows
/// with a passive 340 pt preview of the quick menu built from the real pill views.
@MainActor struct QuickMenuSettingsEditor: View {
    enum Page: String, CaseIterable, Identifiable {
        case blocks, presets
        var id: String { rawValue }
        var title: String { L10n.text(self == .blocks ? "Overview blocks" : "Sleep presets") }
    }
    var model: TilveroModel
    @State var page: Page = .blocks
    /// An open inline duration row to start with (render tests).
    var presetDraft: QuickPresetDurationDraft? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: WindowTheme.tileGap) {
            Picker(L10n.text("Quick menu"), selection: $page) {
                ForEach(Page.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            .accessibilityIdentifier("quick-menu-editor-page")
            switch page {
            case .blocks: QuickPanelBuilder(model: model)
            case .presets: QuickPresetsEditor(model: model, initialDraft: presetDraft)
            }
        }
    }
}

/// The inline duration row's draft: which row, which chip (`nil` = a new one) and the two fields.
struct QuickPresetDurationDraft: Equatable {
    var row: QuickPresets.Row
    var index: Int?
    var hours: String
    var minutes: String
    var value: Int? { QuickPresetEdit.minutes(hours: hours, minutes: minutes) }
}

@MainActor struct QuickPresetsEditor: View {
    var model: TilveroModel
    private var store: QuickPresetStore { model.quickPresets }
    @State private var draft: QuickPresetDurationDraft?
    /// The group being edited: the preview follows it.
    @State private var focus: QuickPresets.Row
    @State private var wide = true

    init(model: TilveroModel, initialDraft: QuickPresetDurationDraft? = nil) {
        self.model = model
        _draft = State(initialValue: initialDraft)
        _focus = State(initialValue: initialDraft?.row ?? .sleepTimer)
    }

    /// The saved presets with a valid draft applied, for the preview.
    private var previewPresets: QuickPresets {
        var value = store.presets
        if let draft, let minutes = draft.value,
           case .valid = QuickPresetEdit.verdict(minutes, row: draft.row, in: value[draft.row], editing: draft.index) {
            value[draft.row] = QuickPresetEdit.applying(minutes, row: draft.row, to: value[draft.row], editing: draft.index)
        }
        return value
    }

    var body: some View {
        // One layout object switched by width, so the drafts (state of the editor below) survive the switch.
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                          : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
        layout {
            VStack(alignment: .leading, spacing: 12) {
                WindowTile {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(QuickPresets.Row.allCases) { row in
                            if row != QuickPresets.Row.allCases.first { Divider() }
                            QuickPresetGroup(row: row, values: store[row], draft: $draft, focus: $focus,
                                             commit: { store.set(row, $0) })
                        }
                    }
                }
                Button(L10n.text("Restore defaults")) { draft = nil; store.resetToDefaults() }
                    .buttonStyle(.borderless).foregroundStyle(WindowTheme.accent)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(WindowTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    .disabled(store.isDefault && draft == nil)
                    .accessibilityIdentifier("quick-presets-reset")
            }
            .frame(minWidth: 380, maxWidth: .infinity, alignment: .leading)
            QuickPresetsPreview(presets: previewPresets, row: focus)
        }
        // minWidth 0: the frame reports the offered width, not the wider side-by-side child, so a narrow window stacks.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Bool.self) { $0.size.width >= Self.wideWidth } action: { wide = $0 }
    }

    /// Editor minimum (380) + gap (20) + preview (340).
    static let wideWidth: CGFloat = 740
}

/// One group: title, (i), counter, chips, «+ Добавить», and the inline duration row while one of its chips is edited.
@MainActor private struct QuickPresetGroup: View {
    let row: QuickPresets.Row
    let values: [Int]
    @Binding var draft: QuickPresetDurationDraft?
    @Binding var focus: QuickPresets.Row
    let commit: ([Int]) -> Void

    private var ownDraft: QuickPresetDurationDraft? { draft?.row == row ? draft : nil }
    private var verdict: QuickPresetEdit.Verdict? {
        ownDraft.map { QuickPresetEdit.verdict($0.value, row: row, in: values, editing: $0.index) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Text(QuickPresetEdit.title(row)).font(.headline)
                SectionInfoButton(title: QuickPresetEdit.title(row), paragraphs: QuickPresetEdit.info(row), id: "quick-presets-info-" + row.rawValue)
                Spacer(minLength: 8)
                Text("\(values.count) / \(row.maximum)").foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityLabel(QuickPresetEdit.title(row) + ": \(values.count) / \(row.maximum)")
            }
            QuickPresetFlow(spacing: 6) {
                ForEach(Array(values.enumerated()), id: \.element) { index, value in
                    chip(index: index, value: value)
                }
                ForEach(QuickPresetEdit.fixedTail(row), id: \.label) { tail in
                    QuickPresetLockedChip(label: tail.label, spoken: tail.spoken)
                }
                addButton
            }
            if let ownDraft { durationRow(ownDraft) }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder private func chip(index: Int, value: Int) -> some View {
        let editing = ownDraft?.index == index
        let duplicate: Bool = { if case .duplicate(let other) = verdict { return other == index }; return false }()
        QuickPresetChip(label: QuickPresetEdit.chipLabel(value, row: row), editing: editing, duplicate: duplicate,
                        canRemove: QuickPresetEdit.canRemove(values),
                        editLabel: QuickPresetEdit.editLabel(value, row: row),
                        removeLabel: QuickPresetEdit.removeLabel(value, row: row),
                        levelChoices: row.kind == .level ? QuickPresetEdit.freeLevels(row: row, in: values) : nil,
                        edit: {
                            focus = row
                            draft = QuickPresetDurationDraft(row: row, index: index, hours: String(value / 60), minutes: String(value % 60))
                        },
                        replace: { level in
                            focus = row
                            commit(QuickPresetEdit.applying(level, row: row, to: values, editing: index))
                        },
                        remove: {
                            focus = row
                            if ownDraft != nil { draft = nil }
                            commit(QuickPresetEdit.removing(at: index, row: row, from: values))
                        })
    }

    @ViewBuilder private var addButton: some View {
        let canAdd = QuickPresetEdit.canAdd(values, row: row)
        let limit = L10n.text("Maximum") + " \(row.maximum)"
        Group {
            if row.kind == .level {
                Menu {
                    ForEach(QuickPresetEdit.freeLevels(row: row, in: values), id: \.self) { level in
                        Button(PresetLabel.level(level)) {
                            focus = row
                            commit(QuickPresetEdit.applying(level, row: row, to: values, editing: nil))
                        }
                    }
                } label: { QuickPresetAddLabel() }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()
            } else {
                Button {
                    focus = row
                    draft = QuickPresetDurationDraft(row: row, index: nil, hours: "0", minutes: "")
                } label: { QuickPresetAddLabel() }
                    .buttonStyle(.plain)
            }
        }
        .disabled(!canAdd)
        .opacity(canAdd ? 1 : 0.45)
        .help(canAdd ? L10n.text("Add") : limit)
        .accessibilityLabel(L10n.text("Add") + ": " + QuickPresetEdit.title(row))
        .accessibilityHint(canAdd ? "" : limit)
        .accessibilityIdentifier("quick-presets-add-" + row.rawValue)
    }

    private func durationRow(_ current: QuickPresetDurationDraft) -> some View {
        let valid: Bool = { if case .valid = verdict { return true }; return false }()
        return HStack(spacing: 8) {
            Text(L10n.text("Duration")).foregroundStyle(.secondary)
            field(text: Binding(get: { draft?.hours ?? "" }, set: { draft?.hours = $0 }), label: L10n.text("h"), valid: valid)
            Text(L10n.text("h"))
            field(text: Binding(get: { draft?.minutes ?? "" }, set: { draft?.minutes = $0 }), label: L10n.text("min"), valid: valid)
            Text(L10n.text("min"))
            Spacer(minLength: 8)
            Button(L10n.text("Cancel")) { draft = nil }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("quick-presets-cancel")
            Button(L10n.text("Done")) { confirm() }
                .buttonStyle(.borderedProminent).tint(WindowTheme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
                .accessibilityIdentifier("quick-presets-done")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .padding(.bottom, 2)
    }

    private func field(text: Binding<String>, label: String, valid: Bool) -> some View {
        TextField(label, text: text)
            .textFieldStyle(.roundedBorder).monospacedDigit().multilineTextAlignment(.center)
            .frame(width: 44)
            .onSubmit { confirm() }
            .onExitCommand { draft = nil }
            .accessibilityLabel(label)
    }

    private func confirm() {
        guard let current = ownDraft, case .valid(let value) = verdict else { return }
        commit(QuickPresetEdit.applying(value, row: row, to: values, editing: current.index))
        draft = nil
    }
}

/// A preset chip: label (edit) + ✕ (remove). Delete removes the focused chip.
@MainActor private struct QuickPresetChip: View {
    let label: String
    let editing: Bool
    let duplicate: Bool
    let canRemove: Bool
    let editLabel: String
    let removeLabel: String
    /// Level rows: the free levels the chip can change to (a menu instead of the inline row).
    let levelChoices: [Int]?
    let edit: () -> Void
    let replace: (Int) -> Void
    let remove: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 5) {
            Group {
                if let levelChoices {
                    Menu {
                        ForEach(levelChoices, id: \.self) { level in Button(PresetLabel.level(level)) { replace(level) } }
                    } label: { text }
                        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()
                } else {
                    Button(action: edit) { text }.buttonStyle(.plain)
                }
            }
            .accessibilityLabel(editLabel)
            .onDeleteCommand { if canRemove { remove() } }
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 14, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!canRemove).opacity(canRemove ? 1 : 0.35)
            .accessibilityLabel(removeLabel)
            .help(removeLabel)
        }
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(Capsule().fill(editing ? WindowTheme.accent.opacity(0.18) : duplicate ? Color.orange.opacity(0.18) : Color.primary.opacity(0.07)))
        .overlay(Capsule().strokeBorder(stroke, lineWidth: editing || duplicate ? 1.2 : 1))
        .accessibilityElement(children: .contain)
    }

    private var text: some View {
        Text(label).font(.callout.weight(.medium)).monospacedDigit().foregroundStyle(Color.primary).lineLimit(1)
    }
    private var stroke: Color {
        if editing { return WindowTheme.accent }
        if duplicate { return .orange }
        return contrast == .increased ? Color.primary.opacity(0.4) : .clear
    }
}

/// A fixed tail pill (lock mark): «Своё», ∞, «До…».
@MainActor private struct QuickPresetLockedChip: View {
    let label: String
    let spoken: String
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(label).font(.callout.weight(.medium)).monospacedDigit().lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .overlay(Capsule().strokeBorder(contrast == .increased ? Color.primary.opacity(0.4) : .clear))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(QuickPresetEdit.lockedLabel(spoken))
        .help(L10n.text("cannot be removed"))
    }
}

@MainActor private struct QuickPresetAddLabel: View {
    var body: some View {
        Label(L10n.text("Add"), systemImage: "plus").font(.callout.weight(.medium)).labelStyle(.titleAndIcon)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .foregroundStyle(WindowTheme.accent)
            .contentShape(Capsule())
    }
}

/// Chips wrap onto the next line.
struct QuickPresetFlow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let rows = arrange(width: width, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: width, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            for (index, x) in row.items {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }
    private struct Line { var y: CGFloat; var height: CGFloat; var items: [(Int, CGFloat)] }
    private func arrange(width: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = [], x: CGFloat = 0, current = Line(y: 0, height: 0, items: [])
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x + size.width > width, !current.items.isEmpty {
                lines.append(current)
                current = Line(y: current.y + current.height + spacing, height: 0, items: []); x = 0
            }
            current.items.append((index, x)); x += size.width + spacing
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty { lines.append(current) }
        return lines
    }
}

/// The quick menu as it will look, 340 pt wide, built from the real pill views. Passive (no hit testing, constant
/// switches, no actions), hidden from VoiceOver, and following the group being edited.
@MainActor struct QuickPresetsPreview: View {
    let presets: QuickPresets
    let row: QuickPresets.Row

    enum Surface: Equatable { case sleepTimer, keepAwake, overview }
    static func surface(for row: QuickPresets.Row) -> Surface {
        switch row {
        case .sleepTimer, .sleepAtCharge: .sleepTimer
        case .keepAwake, .awakeUntilCharge: .keepAwake
        case .overviewAwake: .overview
        }
    }

    var body: some View {
        let surface = Self.surface(for: row)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(AppIdentity.displayName).font(.headline)
                Spacer()
                Image(systemName: "gearshape").foregroundStyle(.secondary)
            }
            QuickPanelTabs(selection: .constant(surface == .overview ? .overview : .awake)).frame(maxWidth: .infinity)
            switch surface {
            case .overview: overview
            case .sleepTimer, .keepAwake:
                CompactSleepTabs(selection: .constant(surface == .sleepTimer ? .timer : .awake))
                sleep(surface)
            }
        }
        .padding(QuickPanelMetrics.padding)
        .frame(width: QuickPanelMetrics.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .environment(\.locale, L10n.locale)
    }

    private func heading(_ title: String, on: Bool = false, symbol: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol) }
            Text(title).font(.system(size: 14, weight: .semibold)).fixedSize()
            if symbol == nil { Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            Toggle(title, isOn: .constant(on)).toggleStyle(.switch).controlSize(.regular).labelsHidden().fixedSize()
        }
        .frame(height: 32)
    }

    @ViewBuilder private func sleep(_ surface: Surface) -> some View {
        let timer = surface == .sleepTimer
        VStack(alignment: .leading, spacing: 10) {
            heading(L10n.text(timer ? "Sleep timer" : "Keep Awake"))
            LazyVGrid(columns: SleepPillGrid.columns, spacing: 6) {
                ForEach(timer ? presets.sleepTimer : presets.keepAwake, id: \.self) { minutes in
                    SleepDurationPill(title: PresetLabel.duration(minutes), selected: false,
                                      id: "preview.duration.\(minutes)", captionID: "preview.duration.\(minutes).caption", action: {})
                }
                ForEach(QuickPresetEdit.fixedTail(timer ? .sleepTimer : .keepAwake), id: \.label) { tail in
                    SleepDurationPill(title: tail.label, selected: false, id: "preview.tail." + tail.label,
                                      captionID: "preview.tail." + tail.label + ".caption", action: {})
                }
            }
            Divider().padding(.vertical, 2)
            heading(L10n.text(timer ? "Sleep at charge" : "Keep awake until charge"))
            HStack(spacing: 6) {
                ForEach(timer ? presets.sleepAtCharge : presets.awakeUntilCharge, id: \.self) { level in
                    SleepAtChargePill(title: PresetLabel.level(level), selected: false, enabled: true,
                                      id: "preview.level.\(level)", action: {})
                }
            }
            if timer {
                Divider().padding(.vertical, 2)
                heading(L10n.text("With lid closed"), on: true)
            }
        }
    }

    /// The Overview's Keep Awake block as `OverviewKeepAwake` draws it (header, segments in their track, ∞, ›) with plain
    /// labels instead of its buttons, so nothing here can be pressed and it is not dimmed.
    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(L10n.text("Keep Awake"), systemImage: "cup.and.saucer").font(.overviewBlockTitle)
                Spacer(minLength: 8)
                Toggle(L10n.text("Keep Awake"), isOn: .constant(false)).toggleStyle(.switch).controlSize(.regular).labelsHidden().fixedSize()
            }.frame(height: 26)
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    ForEach(presets.overviewAwake, id: \.self) { minutes in
                        Text(OverviewKeepAwake.label(minutes)).font(.system(size: 12, weight: .medium))
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 26)
                    }
                }
                .padding(3).background(Color.primary.opacity(0.07), in: Capsule())
                round { Text("∞").font(.system(size: 15, weight: .semibold)) }
                round { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
            }
        }
    }
    private func round<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(width: 34, height: 34).background(Color.primary.opacity(0.07), in: Circle())
    }
}
