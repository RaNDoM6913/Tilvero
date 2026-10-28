# Changelog

## Unreleased - compact quick panel

- Match the approved A3 navigation without a visible picker heading or collection-time footer.
- Keep one native charge state, concise pending/charging status and recovery actions. Move repeated technical explanations to Diagnostics/tooltips and omit unqualified full-once from quick actions.
- Keep mode action statuses in the quick panel; retain detailed reasons in the full editor and tooltips. No charge-policy or hardware-authority change.

## Unreleased — native-control development checkpoint

- Use public native SF Symbol layers with continuous measured fill.
- Add a typed user-space PowerUI adapter, journaled native sessions, safe pending targets, external reconciliation and deadlines. Real writes remain behind per-Mac validation; full-once has a separate gate.
- Add a real last-hour chart, conservative discharge forecast and saved overview preferences.
- Add durable Normal / Economy / Maximum autonomy plans with separate Save / Apply, action preview and partial outcomes; preserve background jobs and exclude unqualified energy/display actions.
- Complete overview/native/mode RU/EN strings, refresh native picker labels on language changes, and separate native from helper diagnostics.
- Preserve native discovery when an on-battery policy is unregistered; keep writes gated by independent confirmation.
- Handle the previous limit recalled by enableMCL after disabled100, with fresh battery checks and verified baseline restoration.
- Cutoff, full-once, privileged controls and trusted distribution retain separate gates. This is development source, not a release.

## Unreleased — local launch and system charge-limit readback

- Open the exact local bundle and show both paths when another copy is running; wait for a normal quit before switching and refuse to overwrite a running bundle.
- Read the manual macOS charge limit separately from other registered system requests, with freshness, manual refresh and a link to Apple's Battery settings.
- Keep Tilvero hardware writes and helper enrollment subject to their existing signing, qualification and restoration gates.

## Unreleased — A3 app refinement

- Separate the quick panel into Overview, Charge and Modes with content-based height and bounded scrolling.
- Keep qualified charging actions inside the panel; move sleep analysis to a separate Sleep & drain detail section.
- Record future observed sleep intervals with fresh raw endpoints, explicit incomplete evidence, local retention and shared-history erasure.
- Show current read-only sleep assertions without storing process details or attributing historical energy to applications.
- Refine the menu-bar battery silhouette against the measured system reference and add larger, contrast-adaptive iOS-inspired inside numerals without a tall stretched body.
- Preserve a running development app by accepting a fresh explicit local-build output.

DMG/release work is deferred. No new hardware-write qualification or public binary release is introduced.

## Unreleased — Monitoring Preview preparation

- Prepare the helper-free Monitoring Preview distribution scope: battery monitoring, local history and read-only diagnostics on Apple silicon with macOS 26.0+.
- Add an on-demand GitHub release-asset download report with beta/stable filtering, complete pagination, asset-ID deduplication and explicit unavailable results.
- Add English/Russian download availability, installation, verification and manual-update guidance.

No public binary release, release tag or trusted installation is claimed by this entry. Local ad-hoc **TEST** packages are internal verification artifacts. Physical charging, power-mode and fan control qualification remains separate and unavailable.
