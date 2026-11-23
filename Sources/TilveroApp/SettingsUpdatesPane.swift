// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI

/// What the Updates tab reads from `UpdateCheckService` and `SparkleUpdateInstaller`. Plain values, so the whole status
/// matrix is testable.
struct SettingsUpdateInputs: Equatable, Sendable {
    var installedVersion: String?
    var phase: UpdateCheckPhase = .idle
    /// The last successful (dated) check; a failed or cancelled later check keeps it.
    var lastSuccess: UpdateCheckSnapshot?
    /// The installer's last error: installation postponed.
    var installError: String?
    var installerQualified = false
}

enum SettingsUpdateStatus: Equatable, Sendable {
    case current
    case updateAvailable(version: String)
    case checking
    case failed(UpdateCheckFailure)
    case cancelled
    case sourceOnly
    case installPostponed
    case notChecked
    /// This build is updated by hand (`UpdateAvailability.manual`).
    case manual
    /// The feed had no app release for this build (`UpdateAvailability.noCompatibleRelease`).
    case noCompatibleRelease
}

enum SettingsUpdateAction: Equatable, Sendable {
    case check, cancel, retry, install, openRelease, releaseNotes, diagnostics
    var titleKey: String {
        switch self {
        case .check: "Check for Updates…"
        case .cancel: "Cancel"
        case .retry: "Try Again"
        case .install: "Install and Restart…"
        case .openRelease: "Open Release"
        case .releaseNotes: "Release Notes"
        case .diagnostics: "Diagnostics"
        }
    }
}

struct SettingsUpdateDisplay: Equatable, Sendable {
    let status: SettingsUpdateStatus
    let lead: LeadDisplay
    /// The first action is the primary (prominent) one.
    let actions: [SettingsUpdateAction]
    /// The release the status is about (app release, or the source release when only source was published).
    let release: UpdateRelease?
}

enum SettingsUpdates {
    /// Checking › installation postponed › failed › cancelled › the result of the newest successful check › never checked.
    static func status(_ input: SettingsUpdateInputs) -> SettingsUpdateStatus {
        switch input.phase {
        case .checking: return .checking
        default: break
        }
        if input.installError != nil { return .installPostponed }
        switch input.phase {
        case .failed(let failure): return .failed(failure)
        case .cancelled: return .cancelled
        default: break
        }
        guard let result = result(input) else { return .notChecked }
        switch result.availability {
        case .appAvailable:
            guard let release = result.release else { return .notChecked }
            return .updateAvailable(version: release.version ?? String(release.tag.drop(while: { $0 == "v" })))
        case .current: return .current
        case .sourceOnly: return .sourceOnly
        case .manual: return .manual
        case .noCompatibleRelease: return .noCompatibleRelease
        }
    }

    static func result(_ input: SettingsUpdateInputs) -> UpdateDiscoveryResult? {
        if case .succeeded(let snapshot) = input.phase { return snapshot.result }
        return input.lastSuccess?.result
    }

    static func checkedAt(_ input: SettingsUpdateInputs) -> Date? {
        if case .succeeded(let snapshot) = input.phase { return snapshot.checkedAt }
        return input.lastSuccess?.checkedAt
    }

    static func display(_ input: SettingsUpdateInputs, now: Date = Date(), calendar: Calendar = .current,
                        language: String = L10n.language, locale: Locale = L10n.locale) -> SettingsUpdateDisplay {
        let ru = language == "ru"
        let status = status(input)
        let result = result(input)
        let release = result.flatMap { $0.release ?? $0.sourceRelease }
        let installed = input.installedVersion ?? "—"
        let checked = checkedAt(input).map { (ru ? "проверено " : "checked ") + when($0, now: now, calendar: calendar, language: language, locale: locale) }
        var value = installed
        var detail: [String] = []
        let statusKey: String, tone: LeadDisplay.Tone, actions: [SettingsUpdateAction]
        switch status {
        case .current:
            statusKey = "Up to date"; tone = .accent; actions = [.check]
            if let checked { detail.append(checked) }
        case .updateAvailable(let version):
            value = version
            statusKey = "Update available"; tone = .accent
            var list: [SettingsUpdateAction] = [input.installerQualified ? .install : .openRelease]
            if release.map({ !$0.notes.isEmpty }) == true { list.append(.releaseNotes) }
            actions = list
            if let version = input.installedVersion { detail.append((ru ? "установлена " : "installed ") + version) }
            if let checked { detail.append(checked) }
        case .checking:
            statusKey = "Checking (updates)"; tone = .secondary; actions = [.cancel]
            detail.append(L10n.text("Reading published release information…"))
        case .failed(let failure):
            statusKey = "Could not check"; tone = .attention; actions = [.retry]
            detail.append(L10n.text(failureKey(failure)))
        case .cancelled:
            statusKey = "Cancelled (update check)"; tone = .secondary; actions = [.check]
            if let checked { detail.append(checked) }
        case .sourceOnly:
            statusKey = "Source code only"; tone = .neutral; actions = [.openRelease]
            if let release { detail.append(release.name.isEmpty ? release.tag : release.name) }
            if let checked { detail.append(checked) }
        case .installPostponed:
            statusKey = "Installation postponed"; tone = .attention; actions = [.diagnostics]
            if let error = input.installError, !error.isEmpty { detail.append(error) }
        case .notChecked:
            statusKey = "Not checked yet"; tone = .secondary; actions = [.check]
        case .manual:
            statusKey = "Updated manually"; tone = .secondary; actions = [.check]
            if let checked { detail.append(checked) }
        case .noCompatibleRelease:
            statusKey = "No app release"; tone = .secondary; actions = [.check]
            if let checked { detail.append(checked) }
        }
        return SettingsUpdateDisplay(status: status,
                                     lead: LeadDisplay(value: value, status: L10n.text(statusKey), tone: tone,
                                                       detail: detail.joined(separator: " · ")),
                                     actions: actions, release: release)
    }

    /// «сегодня 09:12», «вчера 18:40», «4 нояб. 09:12» / "today 9:12 AM", "yesterday 6:40 PM", "Nov 4, 9:12 AM".
    static func when(_ date: Date, now: Date, calendar: Calendar, language: String, locale: Locale) -> String {
        let ru = language == "ru"
        var calendar = calendar
        calendar.locale = locale
        let time = date.formatted(.dateTime.hour().minute().locale(locale))
        if calendar.isDate(date, inSameDayAs: now) { return (ru ? "сегодня " : "today ") + time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return (ru ? "вчера " : "yesterday ") + time
        }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(locale))
    }

    /// The previous panel's failure sentences.
    static func failureKey(_ failure: UpdateCheckFailure) -> String {
        switch failure {
        case .offline: "The network is unavailable. Try again when you are connected."
        case .timedOut: "The update server did not respond in time."
        case .rateLimited: "The update server is limiting requests. Please try again later."
        case .malformed: "Release information could not be verified."
        case .responseTooLarge: "Release information exceeded the allowed size."
        case .unavailable: "The update server is unavailable. Please try again later."
        }
    }

    static let releasesURL = URL(string: "https://github.com/RaNDoM6913/Tilvero/releases")!
}

/// Settings › Updates: lead (version and status), one action tile, channel and automatic checks. The same service and
/// installer calls as the previous Updates panel, under the same conditions.
@MainActor struct SettingsUpdatesPane: View {
    var model: TilveroModel
    @ObservedObject var service: UpdateCheckService
    @State private var showsNotes = false

    var body: some View {
        let installer = model.updateInstaller
        let input = SettingsUpdateInputs(installedVersion: service.identity.version, phase: service.phase,
                                         lastSuccess: service.lastSuccess, installError: installer.lastError,
                                         installerQualified: installer.isQualified)
        let display = SettingsUpdates.display(input)
        let blocked = installer.installationBlocksQuit
        SettingsScroll {
            SettingsUpdatesContent(display: display, showsNotes: $showsNotes, busy: blocked, perform: perform)
            SettingsRowsTile {
                SettingsRow(label: L10n.text("Channel (updates)")) {
                    Picker(L10n.text("Update channel"), selection: Binding(get: { service.channel }, set: { service.setChannel($0) })) {
                        Text(L10n.text("Stable (channel)")).tag(UpdateChannel.stable)
                        Text(L10n.text("Beta and stable (channel)")).tag(UpdateChannel.beta)
                    }
                    .pickerStyle(.segmented).fixedSize().labelsHidden()
                    .disabled(display.status == .checking || blocked)
                    .accessibilityIdentifier("settings.updates.channel")
                }
                SettingsRowDivider()
                SettingsRow(label: L10n.text("Check automatically")) {
                    Toggle(L10n.text("Check automatically"), isOn: Binding(get: { service.automaticallyChecks },
                                                                           set: { service.setAutomaticallyChecks($0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                        .disabled(blocked)
                        .accessibilityIdentifier("settings.updates.automatic")
                }
            }
        }
    }

    private func perform(_ action: SettingsUpdateAction, release: UpdateRelease?) {
        let installer = model.updateInstaller
        switch action {
        case .check, .retry:
            showsNotes = false
            if installer.isQualified { installer.checkForUpdates(channel: service.channel) }
            Task { await service.check() }
        case .cancel: service.cancel()
        case .install: installer.checkForUpdates(channel: service.channel)
        case .openRelease: NSWorkspace.shared.open(release?.releaseURL ?? SettingsUpdates.releasesURL)
        case .releaseNotes: showsNotes.toggle()
        case .diagnostics: model.openUpdateDiagnostics()
        }
    }
}

/// Lead and action tile of the Updates tab (value input only).
struct SettingsUpdatesContent: View {
    let display: SettingsUpdateDisplay
    @Binding var showsNotes: Bool
    var busy = false
    let perform: @MainActor (SettingsUpdateAction, UpdateRelease?) -> Void

    var body: some View {
        LeadLine(lead: display.lead) {
            if display.status == .checking { ProgressView().controlSize(.small) }
        }
        WindowTile {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ForEach(display.actions.dropFirst(), id: \.self) { action in
                        Button(L10n.text(action.titleKey)) { perform(action, display.release) }
                            .disabled(isDisabled(action))
                            .accessibilityIdentifier("settings.updates." + String(describing: action))
                    }
                    Spacer(minLength: 8)
                    if let primary = display.actions.first {
                        Button(L10n.text(primary.titleKey)) { perform(primary, display.release) }
                            .buttonStyle(.borderedProminent)
                            .disabled(isDisabled(primary))
                            .accessibilityIdentifier("settings.updates." + String(describing: primary))
                    }
                }
                if showsNotes, let notes = display.release?.notes, !notes.isEmpty {
                    Text(notes).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// As before: no new check or installation while an installation holds the app.
    private func isDisabled(_ action: SettingsUpdateAction) -> Bool {
        switch action {
        case .check, .retry, .install: busy
        case .cancel, .openRelease, .releaseNotes, .diagnostics: false
        }
    }
}
