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
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            KeepAwakeSummary(service: model.keepAwake)
            if !model.keepAwake.hasOwnedAssertion {
                HStack {
                    Picker(L10n.text("Duration"), selection: $model.keepAwakeDuration) {
                        ForEach(KeepAwakeDuration.allCases) { duration in
                            Text("\(duration.rawValue) " + L10n.text("min")).tag(duration)
                        }
                    }.labelsHidden().accessibilityLabel(L10n.text("Keep Awake duration"))
                    Spacer(minLength: 8)
                    Button(L10n.text("Start")) {
                        do { try model.keepAwake.start(seconds: model.keepAwakeDuration.seconds); error = nil }
                        catch { self.error = error.localizedDescription }
                    }.disabled(!model.keepAwake.isAvailable).accessibilityIdentifier("keep-awake-start")
                }
            }
            if let error { Text(L10n.text(error)).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if !model.keepAwake.isAvailable {
                Text(L10n.text("Keep Awake is unavailable in this build or simulation.")).font(.caption).foregroundStyle(.secondary)
            } else if !compact {
                Text(L10n.text("Prevents idle system sleep for the chosen duration. The display can turn off; closing the lid or choosing Sleep still works. Quitting ends the session."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.help(L10n.text("The display can turn off. Closing the lid or choosing Sleep still works."))
    }
}

/// Outside the hideable overview blocks on every quick-panel tab and in Details.
@MainActor struct KeepAwakeActivePanel: View {
    @ObservedObject var service: KeepAwakeService
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(L10n.text("Keep Mac Awake"), systemImage: "cup.and.saucer.fill").font(.caption).bold()
                Spacer(minLength: 6)
                if service.isActive {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let seconds = service.remainingSeconds
                        let time = "\(seconds / 60):" + String(format: "%02d", seconds % 60)
                        Text(time).monospacedDigit().font(.caption)
                            .accessibilityLabel(L10n.text("Time remaining") + ": " + time)
                    }
                }
                Button(L10n.text("Stop")) { try? service.stop() }.accessibilityIdentifier("keep-awake-stop")
            }
            if let message = service.message {
                Text(L10n.text(message)).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.10)))
    }
}
