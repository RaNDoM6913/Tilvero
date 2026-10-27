# Tilvero control and privileged boundary

The application is useful without helper enrollment. This implementation ships with an empty physical-write qualification list in `PowerCore.HardwareQualification`: no UI switch, IPC payload or environment variable can enable unverified hardware writes. No enrollment or hardware mutation was performed during software implementation.

## Implemented software

- Versioned `ChargePolicyEngine`: desired, applied, pending and observed values; conservative lower-limit deferral; deduplicated intents; obsolete-generation rejection; one-shot return on fresh full/not-charging evidence, cancellation, unplug and restart; system-maintenance reporting; external-controller yield. Restoration of journaled original settings remains separate from pending return to an earlier app policy.
- `FanPolicyEngine`: System Auto default, validated per-fan manual bounds, monotonic boost/lease expiry, validated interpolated curves, 2-degree hysteresis, bounded write cadence, stale-sensor/sleep/conflict release and stale-generation rejection. Real platform fan writes are gated. Simulation uses these same policies and is explicitly marked.
- Independent AC/battery profiles and local, no-wake schedules with manual precedence, at-most-once execution, clock-change replay protection and per-component outcomes.
- Typed protocol version 2; 32 KiB request bound; fixed operations; server-issued session tokens bound to effective UID, audit session and XPC connection; active-console-user checks; generation and replay rejection. `readState` returns only actual available setting/charge/fan evidence, owned resources and unresolved recovery state. Heartbeats return lightweight ownership/loop state without repeating discovery subprocesses.
- Bidirectional `NSXPCConnection.setCodeSigningRequirement` plus exact app/helper identifiers, Apple signing anchor and explicit Team ID. A malformed or absent trust configuration fails closed. No path-only, identifier-only or ad-hoc-signature trust exception exists.
- Secure root journal with pre-write baselines, absent-value preservation, prepared/apply/readback/commit, atomic rename/fsync, ownership/mode/symlink/hardlink checks, cross-process lock, persistent unresolved restore evidence and bounded attempts.
- Separate `--guardian` helper process: continuous monotonic lease expiration, owner revocation before restore, startup recovery and a retained revocation tombstone. Failed lock acquisition is retried by the next two-second sweep. Journaled restoration is attempted at most three times per entry; failure remains visible in the journal. This does not establish a hardware recovery deadline.
- Helper-owned one-second `FanPolicyEngine` loop accepts typed manual, curve, boost and Auto policies independently of GUI timers. Fresh mode, target and actual-RPM observations are required; no controlling temperature sensor is invented. Missing/stale sensors, incomplete observations, mode/target/RPM divergence, boost expiry and lost UI lease trigger journaled Auto recovery. Heartbeat renewal never extends boost duration. Root IOKit sleep events request recovery before acknowledging sleep; wake does not silently reacquire manual control. Actual sleep/recovery bounds remain a real-Pro validation gate.
- Fan transitions journal each target/mode substep before mutation, preserving the original baseline and previous owned intermediate target. An interrupted multi-fan transition can restore its own mixed state. Recovery preflights each fan and yields the entire fan if an external register differs; unaffected owned fans still restore. Unresolved foreign state and failed restores retain their journal evidence.
- Native PowerUI private preference/client adapter, exact `pmset -b/-c lowpowermode 0/1` adapter, and isolated standard AppleSMC fan ABI/keys. Discovery performs reads only; no thermal-manager takeover key is used. Private client presence and readable SMC keys do not qualify writes. High Power, extended SMC charging, sub-80%, exact bands and forced discharge remain unavailable pending a specific qualified contract.

The guardian and controller are fixed modes of the same executable. There is no arbitrary command, executable path, preference-domain or SMC-key IPC method. Helper registration uses normal SMAppService and verifies the installed signed application before registering both jobs. Removal requires verified restoration first.

## Packaging and open acceptance gates

Both app and helper need trusted `TilveroTeamIdentifier`, `TilveroAppIdentifier` and `TilveroHelperIdentifier` bundle metadata; the latter matches the advertised Mach service. A real Team ID must come from the owner's signing identity. The unsigned development build intentionally supplies none. The helper must contain its Info.plist as executable bundle metadata when packaged as a command-line executable; merely placing a plist beside it is insufficient.

The controller launchd plist and independent guardian plist are embedded in the app's `Contents/Library/LaunchDaemons`. Their `BundleProgram` points at `Contents/Library/HelperTools/TilveroHelper`; the guardian adds the fixed `--guardian` argument. Actual registration, signed-client rejection/acceptance, approval and removal are not validated without a trusted signing identity.

The real-device charging cutoff/restart/restore, actual energy-mode mutation/restore, and fan-equipped Pro response/Auto recovery gates remain open. No hardware compatibility or instantaneous recovery claim follows from fixture tests or a successful build. The live app must leave these controls disabled until the relevant profile is qualified.

## Local checks

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'ChargePolicyTests|FanProfileTests|BackendContractTests|SimulationTests|PrivilegeBoundaryTests|RecoveryTests'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run TilveroHelper --status
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run TilveroHelper --discover
```

`--status` and `--discover` are safe non-root modes and never enroll a service. A normal non-root invocation exits with status 77 before storage or control operations. Default tests use only pure policies and an injected in-memory hardware fixture; temporary journal tests use a private directory owned by the test user.

Source pins and complete MIT notices: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
