# Compatibility and current support

Tilvero runs on Apple silicon Macs with **macOS 26.0+** and installs from source with
`scripts/install.sh`. A signed, notarized Mac download is a separate deliverable in preparation.

## System requirements

| Requirement | Supported development route |
| --- | --- |
| Mac | Apple silicon / arm64; Intel is not a supported target |
| OS | macOS 26.0 or later |
| Build tools | Full Xcode with a compatible macOS SDK and Swift 6; Command Line Tools alone are not the validated route |
| Interface | Native SwiftUI and AppKit; Russian and English |
| Connectivity | Offline monitoring core; a daily release check (on by default, can be turned off in Settings → Updates) uses HTTPS without an account or telemetry upload |
| Monitoring | Runs without administrator approval or helper enrollment |

The deployment target does not prove every model/OS combination has been tested.
Recorded actual monitoring/UI observations include MacBook Air M5 / Mac17,3 on
macOS 26.6.2. MacBook Air is fanless; a Pro simulator cannot qualify Pro hardware.

Native UI and local-update continuity were also checked on macOS 27.2. Settings →
General → Battery appearance offers the compact macOS 27 battery and retained
macOS 26 appearance; percentage placement remains a separate preference. The
legacy renderer was compared on the current host, not rerun on a macOS 26 host.
This UI acceptance does not renew hardware-control qualification after an OS upgrade.

## Capability matrix

| Capability | Current source | Important limit |
| --- | --- | --- |
| Battery and adapter readings | Implemented; actual local app observations | The 115-field catalog is a schema, not a promise of 115 available measurements |
| Menu bar and main window | Implemented; native UI, keyboard and appearance checks recorded; the redesigned window (0.8.0) was seen on macOS 27.2 only | Not yet seen on macOS 26; full VoiceOver speech acceptance remains open |
| Updates | Native version/build, source-release discovery, notes, retry and daily checking (on by default, can be turned off); qualified Sparkle integration | Development/Lab/trial stay manual; actual signed feed, trusted binary and downloaded-install acceptance remain open |
| Local history and CSV/JSON export | Implemented and fixture-tested; actual history observed | Gaps stay visible; no invented samples; preview exports before sharing |
| Application activity | Read-only process counters, search, filtering and ranking | CPU energy/power estimates cover CPU activity only; accessible processes may be a partial set |
| Sleep & drain | Read-only observation and fixture coverage | New app-observed intervals only; completed real sleep/wake validation remains a device gate |
| Keep Mac Awake | Explicit source-build sessions with visible Stop | Disabled in DEMO and Monitoring Preview; does not override lid, forced or low-battery sleep |
| Sleep Timer | One-shot development sessions with preparation and cancellation | Disabled in DEMO and Monitoring Preview; actual system sleep/wake remains a device check |
| Closed-lid mode | Implemented lid-only backend, dedicated signed helper, journal, lease and guardian; fixture-tested | Normal builds gated; separately signed trial is limited to 120 seconds; physical behavior/restoration not qualified |
| Saved modes | Separate Save / Apply, action previews and per-action outcomes | Saving never applies; unqualified energy/display actions are excluded |
| Charge by time | Plan from the charge level, adapter power and a margin; lifts the macOS limit just in time and restores it; one optional administrator permission (`pmset schedule wake`) for a scheduled wake; fixture-tested | Waking a sleeping Mac on schedule with the lid closed was verified on one Mac (Mac17,3, macOS 27.2, 2026-11-24); macOS Optimized Battery Charging can still hold the charge at 80 % for a while; a limit you change in macOS always wins. Lifting and restoring the limit use the native charge controller, so the same admission (exact Mac/OS/ABI) applies |
| First-run setup | One window on a brand-new install: launch at login, history, the With lid closed switch (`pmset disablesleep` through the sudoers rule, not the gated closed-lid helper) and charge by time, with one macOS administrator dialog (or a prepared Terminal command) for the two that need it; Settings > Setup lists and removes the permissions; fixture-tested | The real administrator dialog, the Terminal route and the login item from a non-/Applications path still need your own device check |
| Native charge controller | User-space PowerUI adapter with a recovery journal | Requires admission on the exact Mac/OS/ABI; cutoff and one-time-full-charge behavior have separate gates |
| Privileged helper and recovery | Source and fixture implementation | Trusted signing, OS enrollment, lifecycle and device acceptance remain open |
| Privileged charge, energy modes and fans | Physical writes disabled by qualification gates | No generally qualified physical-write set; Pro cooling needs real sensor/RPM/Auto/recovery evidence |
| Extended/sub-80% limits and forced discharge | Unavailable | Require independent supported contracts and hardware validation |

Live macOS **Energy Impact is not implemented**. CPU watts are not total
application watts; GPU/other-device consumption and historical per-app sleep
energy attribution are not established by the current collector.

Sleep reports require history collection and observed sleep/wake boundaries.
A before/after charge change does not establish battery-only operation or exact
time asleep. Internal wake counts/reasons are unavailable; current blockers
describe now. Sleep records follow detailed-history retention and erasure, but
are not included in ordinary CSV/JSON exports. Process names/assertion descriptions
are not persisted in battery history.

## Development source and Monitoring Preview

A default `build-local-app.sh` build uses the development identity. It includes
control-related code and bundled, unregistered helpers. The dedicated lid helper has separate identities and storage; building never enrolls either helper. Native charge admission
is a separate normal-user route: a bounded setting/readback/restoration check
never enables helper or fan control. Targets may remain pending until natural
discharge; a pending target is not active. Fans default to System Auto.

The release configuration selects **monitoring** mode. Its future DMG contains no
privileged helper or service registration and disables control actions, keyboard
backlight writes and Keep Mac Awake. These release restrictions should not be
inferred from the behavior of an ordinary source build.

A readable key, model name, successful test/build or simulator result never
qualifies a hardware write. There is no UI or environment override for the
privileged qualification gate. See the [helper architecture](../Helper/README.md) and [closed-lid trial boundary](CLOSED_LID.md).

## Validation and distribution

The 0.8.1 source passed the default suite on 2026-11-24 (**1,406 Swift tests, 3 skipped, 0 failures, and 86 Python release-tool tests**). The earlier Sleep-controls source milestone passed the complete **557 Swift tests and 61 Python release-tool tests**, built SwiftPM Release and Xcode Debug bundles, and verified local ad-hoc integrity. An earlier complete run failed eight protected migration-journal operations; a standalone Foundation probe reproduced unavailable Class B reopen/read operations. A later unchanged-source run passed after those protected operations became available, with the same protection class and `0600` permissions. The precise external authentication/system transition remains unknown. These results apply to the recorded source milestone, not automatically
to a later release commit. [Testing and validation](TESTING.md) summarizes public coverage and its limits.

**Implemented** means code exists. **Fixture-tested** means deterministic inputs
exercise a contract. **Observed** means actual app/device behavior was inspected.
Hardware control additionally needs baseline, bounded mutation, readback, physical
behavior and restoration. Each status is recorded separately.

A trusted downloadable app still requires Developer ID signing, notarization and
an actual quarantined-download/install check. Local ad-hoc **TEST** packages are
internal artifacts. Source availability does not establish trusted distribution.
Signed lifecycle/launch-at-login behavior, physical unplug/sleep transitions and
remaining accessibility checks retain their own acceptance gates.

Local machine snapshots and owner telemetry are not public qualification data.
README gallery captures, when supplied, use injected fixture data and do
not certify a release binary or physical hardware controls.

[Install](../README.md#install) · [Installation](INSTALL.md) ·
[Release preparation](RELEASING.md) · [Roadmap](../ROADMAP.md)
