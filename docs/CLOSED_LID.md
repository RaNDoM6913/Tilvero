# Closed-lid development trial

The source contains a real lid-only controller, dedicated helper and independent recovery guardian. It uses the root-domain clamshell user-client operation rather than the global `SleepDisabled` override. **Physical closed-lid operation and recovery are not yet qualified.** A successful call or fixture result does not establish physical support.

Ordinary app builds keep this feature gated. Memory simulation is explicit in the laboratory/tests and is never a live fallback. Live XPC admission requires an immutable trial marker plus exact Apple-anchored Team/application/helper trust. Monitoring-only, sibling-controller and unavailable-lease policies continue to deny control.

## Prepare an isolated trial

Use a clean committed checkout on Apple silicon with macOS 26+ and full Xcode. Preparation reads the exact current commit and writes a fresh ignored hidden candidate; it does not build, sign, access a signing key, install, launch or enroll a service:

```sh
python3 scripts/build-lid-trial.py \
  --commit <full-current-commit> --team-id <your-Team-ID>
```

The output contains `Source/` and `lid-trial-receipt.json`, binding original and prepared source hashes to the commit. Existing destinations are preserved. The prepared unsigned marker alone cannot pass runtime trust.

A separately deliberate signing step uses an existing matching certificate and its exact SHA-1 identity; it is not part of default tests or source-release preparation:

```sh
python3 scripts/build-lid-trial.py \
  --commit <full-current-commit> --team-id <your-Team-ID> \
  --build-and-sign --identity <certificate-SHA1>
```

This creates a fresh candidate, checks the certificate/Team, builds the ordinary product sources, retains only the dedicated lid helper, signs and verifies exact requirements. It records `signed-lid-trial-receipt.json` and **never installs, launches or enrolls** the result. An ad-hoc build is not a substitute.

The trial has its own `local.tilvero.lidtrial` identity, preferences and history. Ordinary charging, fan, keyboard and generic-helper controls remain denied. The dedicated helper uses separate `local.tilvero.lidlab.*` jobs and `/Library/Application Support/TilveroClosedLidLab`; it never opens the ordinary charging journal. Each trial is capped independently to **120 seconds**.

## Session and restoration contract

- The exact Awake owner controls the lid session. Stop, owner loss and application sleep/termination preparation restore it before proceeding; an unresolved outcome blocks a clean-exit claim.
- Prepared state is journaled before a native call. A finite app lease and independent guardian reconcile process loss; late replies cannot rearm a revoked owner.
- An accepted operation is reported separately from configuration and physical behavior. Restoration needs a fresh native witness after the clear request, rather than a cached registry value.
- Accepted or ambiguous clears are not repeated blindly. Old-boot records retire without a write. If the lid is closed after clear, a separately journaled ordinary sleep request is at most once.

The shared clamshell bit has no exact mask reader. Same-value/context ABA, queued notifications and hung kernel/OS paths remain practical limits; instantaneous restoration under every failure is not promised.

## Remaining real-device gate

The owner must separately admit a bounded trial with baseline/restoration records, normal macOS service approval and physical lid participation. Before claiming support, verify exact signed positive/negative peers, fresh native baseline, actual closed-lid behavior, Stop, exact Awake-owner loss, expiry, app/helper crash and independent guardian restoration, then ordinary Sleep after clearing the override. Confirm final original state and preserve any unresolved result.

## Owner participation

The trial needs separate admission to use the exact existing signing identity, place the isolated trial bundle under `/Applications`, register its two dedicated jobs and execute the bounded physical checks. Passwords or Touch ID approval stay in normal macOS UI; they are never supplied to the agent.

Save current work and use a hard, ventilated surface. For the first trial, keep the power source stable (AC is convenient but not a code requirement), disconnect external displays and avoid another utility owning a lid override. Other Tilvero instances must be stopped normally before the trial takes its controller lease.

The actual control lives in the **menu bar compact panel**, not the full detail Awake page: **Sleep → Keep Awake → Settings → Enable helper / macOS Settings**. Approve the dedicated services in macOS Login Items when requested. Signed positive/negative peer checks and both guardian/controller jobs must be verified before applying the lid override.

For the first baseline, close and reopen the lid while the override is off; the Mac may sleep/wake. A fresh native baseline is valid for only five seconds. After readiness is established, start Awake and enable **With lid closed** promptly; a refused baseline must be refreshed normally. On instruction, close the lid briefly, reopen before the 120-second deadline and switch the lid mode off once. The recorder must establish actual continuity, clear acceptance and a new native restoration witness.

Use separate bounded trials for ending the exact Awake owner, expiry with the lid closed, trial-app loss, controller loss with a live guardian and guardian restart. Confirm restoration between trials, then ordinary Sleep after clear and final original state. The owner physically closes/opens the lid and confirms observed sleep/wake; the agent handles only the explicitly admitted trial processes.

If restoration stays unknown, open the lid, stop the series and preserve the services/journal for diagnosis. Use Stop/Check restoration once rather than repeating ambiguous writes. If normal recovery cannot be confirmed, save work and use a normal Apple-menu restart, then read-only verification; reboot is not a successful restoration test. Do not clear global sleep settings or delete the recovery journal.

Default tests, local ad-hoc integrity and a source ZIP satisfy none of those physical/signing gates. The helper-free Monitoring Preview distribution remains separate; see [compatibility](COMPATIBILITY.md), [testing](TESTING.md) and [releasing](RELEASING.md).
