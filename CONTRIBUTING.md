# Contributing to Tilvero

Small, focused changes are welcome. Discuss new control paths or larger product changes in an issue before implementation; roadmap entries are proposals until their scope is agreed.

## Set up

Use an Apple silicon Mac with macOS 26.0+ and compatible full Xcode/Swift 6. From the repository directory:

```sh
bash scripts/test.sh
bash scripts/build-local-app.sh
open build/Tilvero.app
```

The scripts select Xcode per process when available. The alternative native project build is `bash scripts/build-xcode.sh`; run only one app bundle at a time. See the [README](README.md) for diagnostics and explicit demo mode.

## Find the right boundary

| Path | Responsibility |
| --- | --- |
| `Sources/PowerCore` | Domain contracts and policies |
| `Sources/PowerTelemetry` | Qualified, read-only platform observations |
| `Sources/PowerPersistence` | Local history, retention and export |
| `Sources/PowerDiagnostics` | Diagnostic report construction |
| `Sources/PowerPrivileged`, `Helper` | Trust, authority, journaling and recovery |
| `Sources/ChargeBackends`, `Sources/FanBackends` | Narrow platform control adapters |
| `Sources/PowerSimulator` | Explicitly labeled simulation |
| `Sources/TilveroApp` | Native app presentation and interaction |

Keep domain logic independent from privilege and platform code. Preserve Russian/English localization, accessibility and native menu behavior. Use English for code, comments and engineering documentation; bug reports may be in English or Russian.

## Verify the behavior you change

- Add meaningful tests for changed contracts, failure modes and recovery behavior. Test files live under `Tests/`; prefer deterministic fixtures over real hardware dependencies.
- Run `bash scripts/test.sh` for a stable behavioral changeset and the applicable build script for app changes. Documentation-only changes need link/content checks, not an unchanged test-suite replay.
- Distinguish source/fixture results, actual app observations and real-device validation in the pull request. Report commands and results honestly, including unavailable checks.
- When support or milestone scope changes, update [compatibility](docs/COMPATIBILITY.md) and the [roadmap](ROADMAP.md) with concise results and unresolved gates. Keep private execution records local.

Default tests must **never change charging, fan, power or sleep settings**, enroll a helper, or schedule a wake. Simulation must remain opt-in, visibly labeled and excluded from live history. Real-device control tests need separate, explicit authorization, a bounded plan and restoration evidence. Readable hardware keys are not permission to write them.

Changes to privilege, signing, authority, journals or recovery require review of the affected boundary. Do not add arbitrary privileged commands, generic key writers, password collection or trust bypasses. Preserve requested/applied/observed state and the empty physical-write qualification set until its device gates are deliberately met. See [helper documentation](Helper/README.md).

## Keep private data local

Do not commit local databases, exports, runtime logs, signing material or owner-specific evidence. Check the diff and `.gitignore` before submitting. Redact serials, hardware/identity tokens, usernames and unrelated file paths from any evidence you choose to share. Issue reports should contain the smallest relevant excerpt, not a full diagnostic dump.

Keep changes focused, preserve existing work and include the user-visible result, verification and limitations in your pull request. Add third-party code only with a compatible license and required notices in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
