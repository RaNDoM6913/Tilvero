import SwiftUI

@MainActor struct ModeEditorPanel: View {
    @ObservedObject var model: TilveroModel
    let compact: Bool
    @State private var draft: ModePlan
    @State private var message: String?
    init(model: TilveroModel, compact: Bool = false) {
        self.model = model; self.compact = compact
        _draft = State(initialValue: model.modeLibrary.plan(model.selectedMode))
    }
    private var unsaved: Bool { draft != model.modeLibrary.plan(draft.mode) }
    private var preview: [ModeActionRow] { model.modePreview(draft) }
    private var report: ModeApplicationReport? { model.modeReport.flatMap { $0.plan == draft ? $0 : nil } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L10n.text("Work mode"), selection: $model.selectedMode) {
                ForEach(WorkMode.allCases) { Text(L10n.text($0.title)).tag($0) }
            }.id(L10n.language).onChange(of: model.selectedMode) { _, mode in
                draft = model.modeLibrary.plan(mode); message = nil
            }
            if draft.mode == .normal {
                if !compact { Text(L10n.text("Normal restores only Tilvero-owned settings. Your other system preferences stay unchanged."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            } else {
                Toggle(L10n.text("Request Low Power Mode"), isOn: $draft.lowPower)
                Picker(L10n.text("Charge limit"), selection: $draft.chargeTarget) {
                    Text(L10n.text("Keep current")).tag(Optional<Int>.none)
                    ForEach(Array(Set(model.acceptedTargets + [80,85,90,95,100])).sorted(), id: \.self) {
                        Text("\($0)%").tag(Optional($0))
                    }
                }
                Toggle(L10n.text("Shorter display idle"), isOn: Binding(get: { draft.displayIdleMinutes != nil }, set: {
                    draft.displayIdleMinutes = $0 ? (draft.mode == .economy ? 5 : 2) : nil
                }))
                if draft.displayIdleMinutes != nil {
                    Stepper(value: Binding(get: { draft.displayIdleMinutes ?? 5 }, set: { draft.displayIdleMinutes = $0 }), in: 1...30) {
                        Text(L10n.text("Idle after") + ": \(draft.displayIdleMinutes ?? 5) " + L10n.text("min"))
                    }
                }
                Toggle(L10n.text("Reduce display brightness"), isOn: Binding(get: { draft.brightnessPercent != nil }, set: {
                    draft.brightnessPercent = $0 ? 50 : nil
                }))
                if draft.brightnessPercent != nil {
                    HStack {
                        Slider(value: Binding(get: { Double(draft.brightnessPercent ?? 50) }, set: { draft.brightnessPercent = Int($0) }), in: 10...100, step: 5)
                            .accessibilityLabel(L10n.text("Display brightness"))
                        Text("\(draft.brightnessPercent ?? 50)%").monospacedDigit().frame(width: 40)
                    }
                }
            }
            Text(L10n.text("Action preview")).font(.headline)
            ForEach(preview) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(actionTitle(row.action))
                        Spacer(minLength: 8)
                        Text(L10n.text(row.status.title)).foregroundStyle(row.status == .excluded ? .orange : .secondary)
                    }
                    if !compact {
                        Text(L10n.text(row.detail)).font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.font(.caption).help(L10n.text(row.detail))
            }
            HStack {
                Button(L10n.text("Save mode")) {
                    do { try model.saveMode(draft); message = "Mode saved. No settings were applied." }
                    catch { message = "The mode could not be saved." }
                }.disabled(!unsaved || model.isApplying)
                Spacer()
                Button(L10n.text("Apply available actions")) { Task { await model.applyMode(draft.mode) } }
                    .disabled(unsaved || model.isApplying || model.nativeCharge.isBusy || model.nativeCharge.isQualifying || model.liveControl.isBusy || !preview.contains { $0.status == .available })
            }
            if unsaved {
                Text(L10n.text("Unsaved changes — save before applying.")).font(.caption).foregroundStyle(.secondary)
            }
            if let message { Text(L10n.text(message)).font(.caption).foregroundStyle(.secondary) }
            if let report {
                Divider()
                Text(L10n.text("Last application result")).font(.caption2).foregroundStyle(.secondary)
                Text(L10n.text(model.isDemo ? "Simulation result" : report.isComplete ? "Available actions completed" : "Partial result — see each action"))
                    .font(.caption).bold()
                ForEach(report.rows) { row in
                    Text(actionTitle(row.action) + ": " + L10n.text(row.status.title) + (compact ? "" : ". " + L10n.text(row.detail)))
                        .font(.caption2).foregroundStyle(row.status == .failed ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true).help(L10n.text(row.detail))
                }
            }
            if !compact { Text(L10n.text("Excluded actions do not run. No extra CPU throttling or battery-life gain is claimed."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.disabled(model.isApplying)
    }
    private func actionTitle(_ action: ModeAction) -> String {
        let value: String?
        switch action {
        case .charge: value = draft.chargeTarget.map { "\($0)%" }
        case .displayIdle: value = draft.displayIdleMinutes.map { "\($0) " + L10n.text("min") }
        case .brightness: value = draft.brightnessPercent.map { "\($0)%" }
        default: value = nil
        }
        return L10n.text(action.title) + (value.map { ": " + $0 } ?? "")
    }
}

/// Quick-panel mode selection reads the saved plan. Editing stays in Details.
@MainActor struct SavedModePanel: View {
    @ObservedObject var model: TilveroModel
    private var plan: ModePlan { model.modeLibrary.plan(model.selectedMode) }
    private var preview: [ModeActionRow] { model.modePreview(plan) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L10n.text("Work mode"), selection: $model.selectedMode) {
                ForEach(WorkMode.allCases) { Text(L10n.text($0.title)).tag($0) }
            }.id(L10n.language)
            ForEach(preview.filter { $0.status != .preserved || $0.action == .restore }) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(title(row.action))
                    Spacer(minLength: 8)
                    Text(L10n.text(row.status.title)).foregroundStyle(row.status == .excluded ? .orange : .secondary)
                }.font(.caption).help(L10n.text(row.detail))
            }
            if let report = model.modeReport, report.plan == plan {
                Text(L10n.text(model.isDemo ? "Simulation result" : report.isComplete ? "Available actions completed" : "Partial result — see each action"))
                    .font(.caption).bold()
                ForEach(report.rows.filter { [.applied, .failed, .pending].contains($0.status) }) { row in
                    Text(title(row.action) + ": " + L10n.text(row.status.title))
                        .font(.caption2).foregroundStyle(row.status == .failed ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true).help(L10n.text(row.detail))
                }
            }
            HStack {
                Button(L10n.text("Edit modes…")) { model.selectedSection = .charging; model.openDetails?() }
                Spacer()
                Button(L10n.text("Apply")) { Task { await model.applyMode(model.selectedMode) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isApplying || model.nativeCharge.isBusy || model.nativeCharge.isQualifying || model.liveControl.isBusy || !preview.contains { $0.status == .available })
            }
        }
    }
    private func title(_ action: ModeAction) -> String {
        let value: String?
        switch action {
        case .charge: value = plan.chargeTarget.map { "\($0)%" }
        case .displayIdle: value = plan.displayIdleMinutes.map { "\($0) " + L10n.text("min") }
        case .brightness: value = plan.brightnessPercent.map { "\($0)%" }
        default: value = nil
        }
        return L10n.text(action.title) + (value.map { ": " + $0 } ?? "")
    }
}
