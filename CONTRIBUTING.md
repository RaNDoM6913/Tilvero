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

## Branch and review workflow

`main` is the accepted integration baseline. Use a focused `codex/<topic>` branch
for a coherent feature, fix or milestone. Reuse that branch for related refinements
and review fixes; a new chat, worker or test run does not need a new branch.

Normally keep one active work branch. A second is useful for an independent
parallel objective; use separate worktrees when writers would otherwise interfere.
Avoid permanent `develop`, staging or release branches unless maintaining an
additional supported version requires one. Small documentation and workflow
housekeeping can use a separate commit on the current work branch.

Use ignored `/local-lab/` for isolated component demos, screenshots, experimental
pages and preview builds. A component workbench is useful for design decisions;
an integration worktree is useful when the chosen change needs the complete app.
Keep demo data and bundle identity isolated from production. Transfer selected
changes onto the feature branch for normal verification and review; a demo is
not release acceptance. Commit coherent changes regularly and push the focused
branch when authorized and useful for backup or review.

The normal delivery path is **focused branch → pull request → checks and review →
accepted integration into `main` → branch cleanup**:

- Keep one PR per coherent objective. Describe the user-visible result, verification
  and remaining limits using the PR template. Do not mix unrelated product work.
- Run focused checks while developing, then the required complete suite and app
  builds on the stable behavioral changeset. Reuse unchanged evidence; rerun when
  relevant changes or failures require it. Documentation-only changes need content
  and link checks.
- Meaningful behavioral changes need an independent review of the complete changed
  scope. Control/authority/recovery boundaries need early focused review as well.
  Complete the agreed native/device acceptance; a local install or fixture pass
  does not by itself make a feature ready to merge.
- Prefer a normal PR merge that preserves the feature's commit history. Continue
  corrections on the same branch; avoid force-pushing published work.
- Once integration is verified, remove inactive fully merged feature branches with
  safe deletion and remove unused worktrees. Preserve attached branches, unique
  commits and explicitly retained archives. Never use forced deletion as cleanup.

These are contribution rules, not a claim that GitHub branch protection or required
CI checks are configured. Remote publication and integration still require the
repository owner's authorization. Never push all local branches or private archives.

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
