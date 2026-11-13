# Changelog

## 0.6.0 — Closed Lid Comfort and Live Charts Source Preview — 2026-11-13

The first stable release of the 0.6 line. It contains everything of 0.5.0-beta.1 (charge by time, the one-time charge to
100 %, the new sleep timer editor) plus:

**New**
- Screen and sound with the lid closed: while Keep Awake or the sleep timer holds the Mac awake with the lid closed, Tilvero
  turns the built-in screen down (to 0 % by default) and keeps the volume no louder than 25 %. A quieter setting is never raised.
  Open the lid, or end the session, and both return to what they were, unless you changed them meanwhile. The new row sits
  under the "With lid closed" switch and expands into two sliders in 5 % steps, each with its own switch; Keep Awake and the
  timer have separate settings.
- Live charts: while the quick menu is open on Overview, power and temperature charts update about once a second. The live
  points live in memory only and are never written to history.
- A roomier quick menu: 340 pt wide with 14 pt padding, and taller chart plots in the same cards.

**Improved**
- Keyboard backlight row: a larger percent figure, and the slider and switch no longer jump back while a change is being applied.
- The "With lid closed" switch no longer snaps back or greys out while the administrator permission is checked.
- Running sleep timer header drops its info button instead of crowding the row.

**Fixed**
- Launch memory: reading months of history at launch left up to ~500 MB of temporary data in the heap (peak about 730 MB, and some
  launches stayed at 655 MB). The peak is now about 85 MB on the same history.
- Launch no longer opens Settings or raises a window over your other apps. Tilvero starts quietly in the menu bar; the window opens
  only when you ask for it (the first-run setup is still a page under Settings).
- The screen and volume sliders showed the same blue blob for every value below about 16 %; the fill now grows over the whole range.

This release contains source for Apple silicon with macOS 26.0+ and full Xcode; it
includes no app or DMG. Waking a sleeping Mac on schedule, with the lid closed
as well, still needs your own device check. Automatic installation remains gated.

## 0.5.0-beta.1 — Charge by Time Source Preview — 2026-11-12

- Charge by time: pick a time and a level (85, 90, 95 or 100 %) on the Charge page. The Mac keeps your charge limit and Tilvero lifts it just in time, so the battery reaches the level 10 minutes before the time you set. The start comes from the adapter's power, what the Mac itself draws, a taper above 80 % and a safety margin; the page shows when charging starts and says so when the target cannot be reached. While the Mac sleeps it wakes on a schedule, lifts the limit and goes back to sleep (one optional administrator permission, `pmset schedule wake`; without it the limit is lifted when the Mac is about to sleep). Your previous limit returns when you unplug the adapter or an hour after the time once the battery is full; a limit you change in macOS always wins.
- Charge to 100 % once: one capsule under the slider lifts the limit until the battery is full or the adapter is unplugged, then your limit returns; tap it again to cancel.
- Sleep timer: the running pill opens a cleaner editor with +5 min, +15 min and +1 h pills, the custom-time wheel and an End timer pill; the explanatory line is gone.
- Overview: the power, adapter, system and temperature cards always draw the chart (the Sparkline option is removed); cards show only a title and a value; temperature follows the system unit (new setting System, °C or °F); the keyboard backlight row and the combined power chart use the same heading style as the other cards, and the auto-brightness caption is gone.

This beta contains source for Apple silicon with macOS 26.0+ and full Xcode; it
includes no app or DMG. Waking a sleeping Mac on schedule, with the lid closed
as well, still needs your own device check, and so does lifting the limit from
that wake. Automatic installation remains gated.

## 0.4.0 — Overview and Keep Awake Source Preview — 2026-11-08

The first stable release of the 0.4 line. It contains everything of 0.4.0-beta.1 (the Overview charge-limit
capsule, the chart sizes, the Overview Keep Awake strip, the lid-closed switch of the sleep timer, the charge
limit that survives quitting) plus:

- Quick menu: the tabs are Overview, Sleep, Charge, because Sleep and Keep Awake are used more often than the charge limit.
- Keep Awake: tapping the running choice on Overview ends the session, as on the Sleep tab; the countdown ticks live.
- The closed-lid override, Keep Awake, the sleep timer and the charge limit were checked on a real Mac.

This release contains source for Apple silicon with macOS 26.0+ and full Xcode; it
includes no app or DMG. Automatic installation remains gated.

## 0.4.0-beta.1 — Overview and Keep Awake Source Preview — 2026-11-08

- Overview: the macOS charge limit is shown in the battery block as an outlined capsule as wide as the battery icon (the confirmed target, 100 % while the limit is off, a blue dash while macOS has not confirmed it); tapping it opens the Charge page. The separate "Charge limit" block is gone.
- Overview charts: the power, adapter, system and temperature charts come in three heights (Strip, Compact by default, Regular), a single-metric card, two-up tiles or one shared power chart. Value axis with units, zebra bands, hatched recording gaps and an honest dashed empty frame; battery power is marked as a V×A estimate and adapter input as a different boundary. The size is a setting in the quick panel builder.
- Overview Keep Awake: one row with a switch, a strip of 15 min / 30 min / 1 h / 4 h, an until-stopped button and a way to the Sleep page. A choice starts at once, the chosen segment counts down and tapping it again ends the session. A timed session shows "Until HH:mm". Picking another kind of session restarts it without a question. The feature is named the same on Overview and in the Sleep tab.
- Sleep: the timer has its own "With lid closed" switch; one switch covers the sleep timer and Sleep at charge.
- Charge: a confirmed native charge limit is the system's own setting and survives quitting the app; stale and duplicated charge notices were removed.
- Quick menu: larger headings, one shared battery block for the panel and the builder preview, power and adapter captions that name their boundary.

This beta contains source for Apple silicon with macOS 26.0+ and full Xcode; it
includes no app or DMG. The physical 85 % cutoff and the closed-lid override
still need your own device check. Automatic installation remains gated.

## 0.3.0-beta.1 — Sleep and Charge Source Preview — 2026-11-06

- Quick menu: tabs and sleep pills are one capsule control with a sliding accent pill (click or drag), cross-faded pages and one spring for page height and popover size. The menu no longer switches Spaces or raises the details window when it opens.
- Sleep: **Sleep at charge** (sleep once the battery falls to a chosen level) and **Keep awake until charge**, next to the Sleep Timer. Only one of Keep Awake, Sleep Timer, Sleep at charge and Keep awake until charge can run at a time. Compact Until picker with cyclic wheels.
- Keep Awake can also hold the Mac awake with the lid closed (`pmset disablesleep`, through a one-time administrator approval). It never starts Keep Awake by itself.
- Menu bar icon: Keep Awake fills the battery with a configurable colour (blue by default); the fill turns red at 20 % or less.
- Charge: the quick Charge page uses the native macOS charge limit with a slider for 80, 85, 90, 95 and 100 %; letting go applies it. It works on battery power after a one-time validation on a charger (battery below 80 %). The page does not change height while the limit is applied.
- Optional keyboard-backlight row in the quick menu (hidden by default).
- History is decoded as scalars only, so refreshes no longer cause multi-second main-thread work.
- Overview shows capacity retention; sleep endpoints and the discharge forecast accept app-observed IOPowerSources readings.

This beta contains source for Apple silicon with macOS 26.0+ and full Xcode; it
includes no app or DMG. The charge limit was exercised on one Mac (macOS 27.2);
its validation and the closed-lid override still need your own device check.
Automatic installation remains gated.

## 0.2.0 — Source Preview — 2026-11-04

- Refined the sidebar and menu bar battery indicator, and shared the native full-width segmented controls between the app and Lab.
- Improved Overview with a daily charge chart that distinguishes gaps, a weekly capacity estimate based on recorded observations, and clearer power readings.
- Improved the quick Charge tab during refresh and separated the configured charge limit, diagnostic readback and editable draft.
- Added a first-run readiness checklist and an Updates screen for GitHub release discovery.

This release contains source for Apple silicon with macOS 26.0+ and full Xcode.
Automatic installation remains gated. Native charge, fan and closed-lid
controls require their separate device and recovery checks.

## 0.1.0-beta.2 — Sleep Controls Source Preview — 2026-11-02

- One-shot Sleep Timer with visible countdown, cancellation, pre-sleep preparation and an owned idle-sleep hold until expiry.
- Compact Timer/Awake controls with master switches, 36 pt presets, native Custom/Until wheels, explicit mode-replacement consent and exact-session action guards.
- Confirmed preset identity survives extensions; Timer Custom commits after native popover closure.
- A dedicated lid-only native backend, signed XPC boundary, durable journal, app lease and independent recovery guardian. Live admission is restricted to a separately signed trial capped at 120 seconds; physical behavior and restoration remain unqualified.
- Shared-source laboratory flavor with isolated data, injected fixture controls and source-bound local packaging. Experimental Studio artifacts remain private.
- Reproducible isolated trial preparation and stricter rejection of private laboratory paths in source exports.

This is source only. It includes no app/DMG, helper enrollment or hardware-support certification. The public binary profile remains helper-free monitoring; trusted signing, notarization and device gates are separate.

## 0.1.0-beta.1 — Source Preview — 2026-10-31

First source prerelease for Apple silicon and macOS 26.0+. This preview contains
source only; a signed, notarized Monitoring Preview DMG remains a separate release gate.

### Monitoring and reports

- Native menu bar panel and detail window for battery, charging, power, cooling information, application activity, history and diagnostics.
- Source-aware 115-field catalog with freshness, explicit unavailable values, exact raw counters, separate nominal/full-charge capacities and device-scoped inferred readings.
- Separate battery power, reported system load and adapter input/capability, with recorded sparklines and observation statistics.
- Searchable application activity with CPU-load filters, top-three/all views and ranking before display limits. CPU energy/power estimates are explicitly partial; total application consumption and live Energy Impact are not implemented.
- Local minute history, hourly summaries and CSV/JSON export with preview and identifier redaction. Collection gaps and battery boundaries remain visible.
- Read-only Sleep & drain reports for newly observed intervals and current sleep blockers, with incomplete evidence retained and process descriptions excluded from history.

### Native interface

- Refined native page layouts, Russian/English localization, configurable menu bar indicator and a quick-panel constructor with show/hide, drag and keyboard reorder.
- Overview, Charge, Modes and Awake quick-panel destinations; content-sized presentation, recorded last-hour chart and conservative discharge forecast.
- Dedicated Settings sections and Activity search/filter/sort controls. Passive historical native-session details live in Diagnostics; unresolved actions remain visible.
- Exact-bundle launching, running-app overwrite protection and fresh `.noindex` candidate destinations to keep inactive copies out of Spotlight.

### Development controls and safety

- Explicit Keep Mac Awake sessions with visible Stop and no automatic restart activation; disabled in simulation and Monitoring Preview.
- Durable Normal / Economy / Maximum autonomy plans with separate Save / Apply, action previews and partial outcomes; unqualified energy/display actions remain excluded.
- User-space native charge adapter with original-state journals, pending lower targets, external reconciliation and per-Mac admission. One-time full charging and physical cutoff retain separate validation gates.
- Privileged helper, peer authentication and recovery source/fixture coverage. Privileged charging, energy-mode and fan writes remain unqualified; fans default to System Auto.
- Clearly labeled DEMO simulation separate from live data/history; no administrator approval needed for monitoring.

### Source release preparation

- English/Russian project and installation guides, compatibility matrix and source-build instructions.
- Monitoring-only release configuration with a separate production identity/store, helper-free packaging and fail-closed signing/notarization checks.
- On-demand GitHub DMG download reporting with pagination, asset deduplication and explicit unavailable results; no in-app telemetry.
- GPL-3.0-only source, original artwork and documentation with preserved third-party notices.

See [testing and validation](docs/TESTING.md) for public coverage and evidence
boundaries, and Git history for earlier changes. Local ad-hoc TEST packages and
successful software tests do not establish trusted distribution or physical
hardware-control support.
