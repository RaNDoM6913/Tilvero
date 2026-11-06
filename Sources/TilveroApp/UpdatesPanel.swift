import AppKit
import SwiftUI

@MainActor struct UpdatesPanel: View {
    @ObservedObject var service: UpdateCheckService
    let installer: SparkleUpdateInstaller
    let diagnostics: () -> Void
    @State private var showsNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ProductSurface(title: "Updates") {
                HStack(spacing: 14) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable().frame(width: 52, height: 52).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("Installed version")).foregroundStyle(.secondary)
                        Text(service.identity.version ?? L10n.text("Unavailable"))
                            .font(.title2.weight(.semibold)).textSelection(.enabled)
                        if let profileLabel {
                            Text(L10n.text(profileLabel)).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                Divider()
                HStack {
                    Button(action: check) {
                        Label(L10n.text(isChecking ? "Checking for updates…" : "Check for Updates…"), systemImage: "arrow.clockwise")
                    }.disabled(isChecking || installer.installationBlocksQuit)
                    if isChecking {
                        ProgressView().controlSize(.small)
                        Button(L10n.text("Cancel")) { service.cancel() }
                    }
                    Spacer()
                }
                result
                if let snapshot = service.lastSuccess {
                    Text(L10n.text("Last successful check") + ": " + snapshot.checkedAt.formatted(
                        Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ProductSurface(title: "Update preferences") {
                Picker(L10n.text("Update channel"), selection: Binding(get: { service.channel }, set: { service.setChannel($0) })) {
                    Text(L10n.text("Stable releases")).tag(UpdateChannel.stable)
                    Text(L10n.text("Beta and stable releases")).tag(UpdateChannel.beta)
                }.disabled(isChecking || installer.installationBlocksQuit)
                Toggle(L10n.text("Check automatically"), isOn: Binding(get: { service.automaticallyChecks }, set: { service.setAutomaticallyChecks($0) }))
                    .disabled(installer.installationBlocksQuit)
                Text(L10n.text("Checks run while Tilvero is open. Each installation needs your confirmation."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("Checking contacts GitHub or the signed update feed. Battery readings and history are not sent."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !installer.isQualified {
                Text(L10n.text(service.identity.supportsInstallerProfile
                    ? "Signed app updates have not been configured for this build."
                    : "This build is updated manually from its matching source or trial package."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = installer.lastError {
                ProductSurface(title: "Installation postponed") {
                    Text(error).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(L10n.text("Open Diagnostics"), action: diagnostics)
                        Button(L10n.text("View Releases")) { openReleases() }
                    }
                }
            }
        }.accessibilityIdentifier("settings.updates")
    }

    private var profileLabel: String? {
        switch service.identity.profile {
        case .development: nil
        case .lab: "Laboratory build"
        case .trial: "Closed-lid trial build"
        case .monitoring: "Monitoring build"
        case .manual: "Manual update build"
        }
    }
    private var isChecking: Bool {
        if case .checking = service.phase { return true }
        return false
    }
    @ViewBuilder private var result: some View {
        switch service.phase {
        case .idle:
            Text(L10n.text("Check published releases when you are ready.")).foregroundStyle(.secondary)
            releasesButton
        case .checking:
            Text(L10n.text("Reading published release information…")).foregroundStyle(.secondary)
        case .cancelled:
            Text(L10n.text("Update check cancelled."))
            releasesButton
        case .failed(let failure):
            Label(L10n.text("Could not check for updates."), systemImage: "wifi.exclamationmark").font(.headline)
            Text(L10n.text(failureLabel(failure))).foregroundStyle(.secondary)
            HStack {
                Button(L10n.text("Try Again"), action: check)
                releasesButton
            }
        case .succeeded(let snapshot):
            releaseResult(snapshot.result)
        }
    }
    @ViewBuilder private func releaseResult(_ result: UpdateDiscoveryResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.text(availabilityLabel(result.availability)), systemImage: result.availability == .sourceOnly ? "chevron.left.forwardslash.chevron.right" : "shippingbox")
                .font(.headline).fixedSize(horizontal: false, vertical: true)
            if result.availability == .sourceOnly {
                Text(L10n.text("This release contains source code and requires Xcode. There is no app to install in this release."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let release = result.release ?? result.sourceRelease {
                Text(release.name.isEmpty ? release.tag : release.name).font(.subheadline.weight(.medium)).textSelection(.enabled)
                HStack {
                    Button(L10n.text(result.availability == .sourceOnly ? "View Source Release" : "View Release")) {
                        NSWorkspace.shared.open(release.releaseURL)
                    }
                    if !release.notes.isEmpty {
                        Button(L10n.text("Release Notes")) { showsNotes.toggle() }
                    }
                    if installer.isQualified, result.availability == .appAvailable {
                        Button(L10n.text("Install and Restart…")) { installer.checkForUpdates(channel: service.channel) }
                            .disabled(installer.installationBlocksQuit)
                    }
                }
                if showsNotes, !release.notes.isEmpty {
                    Text(release.notes).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                }
            } else { releasesButton }
            if result.availability == .appAvailable, installer.isQualified {
                Text(L10n.text("The signed updater confirms compatibility before offering an installation."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var releasesButton: some View { Button(L10n.text("View Releases")) { openReleases() } }
    private func openReleases() { NSWorkspace.shared.open(URL(string: "https://github.com/RaNDoM6913/Tilvero/releases")!) }
    private func check() {
        showsNotes = false
        if installer.isQualified { installer.checkForUpdates(channel: service.channel) }
        Task { await service.check() }
    }
    private func availabilityLabel(_ value: UpdateAvailability) -> String {
        switch value {
        case .sourceOnly: "Only source code has been published"
        case .appAvailable: "A Mac app release is available"
        case .current: "You have the latest app for this channel"
        case .manual: "This build is updated manually"
        case .noCompatibleRelease: "No compatible app release was found"
        }
    }
    private func failureLabel(_ value: UpdateCheckFailure) -> String {
        switch value {
        case .offline: "The network is unavailable. Try again when you are connected."
        case .timedOut: "The update server did not respond in time."
        case .rateLimited: "The update server is limiting requests. Please try again later."
        case .malformed: "Release information could not be verified."
        case .responseTooLarge: "Release information exceeded the allowed size."
        case .unavailable: "The update server is unavailable. Please try again later."
        }
    }
}
