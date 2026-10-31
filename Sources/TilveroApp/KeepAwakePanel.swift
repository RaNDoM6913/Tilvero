import SwiftUI

/// Passive presentation shared by the live panel and the constructor preview.
@MainActor struct KeepAwakeSummary: View {
    @ObservedObject var service: KeepAwakeService
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(L10n.text("Keep Mac Awake"), systemImage: "cup.and.saucer")
            Spacer(minLength: 8)
            Text(L10n.text(service.isActive ? "Active" : service.hasOwnedAssertion ? "Check session" : "Off"))
                .foregroundStyle(service.hasOwnedAssertion && !service.isActive ? .orange : .secondary)
        }.font(.subheadline)
    }
}

@MainActor struct KeepAwakePanel: View {
    @ObservedObject var model: TilveroModel
    var compact = false
    @State private var error: String?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.keepAwake.hasOwnedAssertion {
                KeepAwakeActivePanel(service: model.keepAwake)
                Text(L10n.text("Next session")).font(.subheadline).foregroundStyle(.secondary)
            } else { KeepAwakeSummary(service: model.keepAwake) }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(KeepAwakeDuration.allCases) { duration in
                    choice(durationLabel(duration), option: duration.rawValue)
                }
                choice(L10n.text("Custom…"), option: -1)
                choice(L10n.text("Until…"), option: -2)
            }
            choice("∞  " + L10n.text("Until stopped"), option: 0, accessibility: L10n.text("Until stopped"))
            if model.keepAwakeSelectedOption == -1 {
                HStack {
                    Text(L10n.text("Minutes"))
                    TextField("1–1440", text: $model.keepAwakeCustomMinutes)
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90).accessibilityLabel(L10n.text("Custom duration in minutes"))
                    Spacer(minLength: 0)
                    Text("1–1440").font(.caption).foregroundStyle(.secondary)
                }
            }
            if case .until(let target) = model.keepAwakeDraft {
                DatePicker(L10n.text("Until"), selection: Binding(get: { target }, set: { model.keepAwakeDraft = .until($0) }),
                           displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.field).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(L10n.text("Keep Awake until date and time"))
                Text(KeepAwakePresentation.endTime(target)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("Choose a future date and time within 24 hours. The shown time zone resolves the selected instant."))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.keepAwakeDraft == .untilStopped {
                Text(L10n.text("Until stopped. Quitting Tilvero ends the session."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !model.keepAwake.hasOwnedAssertion {
                Button(L10n.text("Start")) {
                    do { try model.startKeepAwakeDraft(); error = nil }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity, alignment: .trailing)
                    .disabled(!model.canStartKeepAwakeDraft).accessibilityIdentifier("keep-awake-start")
            }
            if let message = error ?? model.keepAwake.message, !model.keepAwake.hasOwnedAssertion,
               model.notice != L10n.text(message) {
                Text(L10n.text(message)).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !model.keepAwake.isAvailable {
                Text(L10n.text("Keep Awake is unavailable in this build or simulation.")).font(.caption).foregroundStyle(.secondary)
            } else if !compact {
                Text(L10n.text("Prevents idle system sleep for the chosen duration. The display can turn off; closing the lid or choosing Sleep still works. Quitting ends the session."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: model.keepAwakeDraft) { _, _ in error = nil }
        .help(L10n.text("The display can turn off. Closing the lid or choosing Sleep still works."))
    }
    private func durationLabel(_ duration: KeepAwakeDuration) -> String {
        duration.rawValue < 60 ? "\(duration.rawValue) " + L10n.text("min") : "\(duration.rawValue / 60) " + L10n.text("h")
    }
    private func choice(_ label: String, option: Int, accessibility: String? = nil) -> some View {
        let selected = model.keepAwakeSelectedOption == option
        return Button { model.selectKeepAwakeOption(option) } label: {
            Text(label).font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.07)))
                .contentShape(Capsule())
        }.buttonStyle(.plain)
            .accessibilityLabel(accessibility ?? label)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("keep-awake-option-\(option)")
    }
}

/// Compact owned-session controls for Overview and the dedicated Awake editor.
/// Stop and failures stay visible when optional extension controls are collapsed.
@MainActor struct KeepAwakeActivePanel: View {
    @ObservedObject var service: KeepAwakeService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var extensionsExpanded = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    if service.isActive, service.expiry != .untilStopped {
                        Button {
                            withAnimation(ProductMotion.animation(reduceMotion: reduceMotion)) { extensionsExpanded.toggle() }
                        } label: {
                            sessionSummary(showsDisclosure: true)
                        }.buttonStyle(.plain)
                            .accessibilityValue(L10n.text(extensionsExpanded ? "Expanded" : "Collapsed"))
                            .accessibilityHint(L10n.text("Extend session"))
                            .accessibilityIdentifier("keep-awake-extensions")
                    } else {
                        sessionSummary(showsDisclosure: false)
                    }
                    Button(L10n.text("Stop")) { try? service.stop() }.accessibilityIdentifier("keep-awake-stop")
                }
                if service.isActive, service.expiry != .untilStopped, extensionsExpanded {
                    HStack(spacing: 6) {
                        ForEach([15, 30, 60], id: \.self) { minutes in
                            Button("+\(minutes) " + L10n.text("min")) { try? service.extend(by: minutes * 60) }
                                .font(.caption).frame(maxWidth: .infinity)
                                .disabled(service.remainingSeconds == 0 || service.remainingSeconds > 86_400 - minutes * 60)
                                .accessibilityIdentifier("keep-awake-extend-\(minutes)")
                        }
                    }
                }
                if let message = service.message {
                    Text(L10n.text(message)).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: service.ownedAssertionID) { _, _ in extensionsExpanded = false }
    }
    private func sessionSummary(showsDisclosure: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Label(L10n.text("Keep Mac Awake"), systemImage: "cup.and.saucer.fill")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    Text(L10n.text(service.isActive ? "Active" : "Check session"))
                        .foregroundStyle(service.isActive ? Color.secondary : Color.orange)
                    if service.isActive {
                        Text(service.expiry == .untilStopped ? L10n.text("Until stopped") : KeepAwakePresentation.countdown(service.remainingSeconds))
                            .monospacedDigit()
                            .accessibilityLabel(service.expiry == .untilStopped ? L10n.text("Until stopped") : L10n.text("Time remaining") + ": " + KeepAwakePresentation.countdown(service.remainingSeconds))
                    }
                }.font(.caption)
                if service.isActive, let end = service.endDate {
                    Text(KeepAwakePresentation.endTime(end)).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if showsDisclosure {
                Image(systemName: extensionsExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

}

enum KeepAwakePresentation {
    static func countdown(_ seconds: Int) -> String {
        let value = max(0, seconds)
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
                            : String(format: "%d:%02d", value / 60, value % 60)
    }
    static func endTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale; formatter.timeZone = timeZone
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        let zone = DateFormatter(); zone.locale = L10n.locale; zone.timeZone = timeZone; zone.dateFormat = "ZZZZ"
        return L10n.text("Until") + " " + formatter.string(from: date) + " · " + zone.string(from: date)
    }
}
