# Updates distribution boundary

Tilvero embeds the genuine [Sparkle 2.10.1 framework](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1), pinned to revision `ab7d71291238df6e0492143b120c9b696a35f603` in SwiftPM and Xcode. Its upstream binary artifact checksum is `4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a`. Full upstream and bundled-component notices travel in `THIRD_PARTY_NOTICES.md` and app Legal resources. Sparkle, rather than Tilvero code, performs download, signature verification, extraction, replacement and relaunch.

GitHub release metadata is informational. A source ZIP, GitHub-generated source archive, release note or metadata record never becomes an executable update. The executable route uses a separately configured, signed appcast. The current `Config/Updater.json` is deliberately disabled and contains no placeholder Team ID, feed or public key. This is software integration with a closed distribution gate; no trusted public app, feed, key, notarization, downloaded-install qualification or physical-device result is claimed.

## Admitted installation

The first installer host must satisfy all of these checks against its actual bundle:

- Exact `io.github.random6913.tilvero`, production data scope, Monitoring profile, integer build and no app helper/service contents.
- Valid Apple Developer ID Application signature and the configured actual Team ID. Ad hoc, development, Lab and lid-trial identities remain manual.
- Sealed updater configuration with an existing 32-byte Ed25519 public key and HTTPS feed. Feed signing and pre-extraction verification are required; feed-signing failures never expire into a permissive fallback.
- Automatic checks, downloads, installation options, profiling and release-note JavaScript disabled. The app's separately persisted opt-in informational scheduler never grants installation permission.

A signed appcast candidate must additionally have a strictly greater integer build, an application DMG, valid signed-feed status and enclosure attributes `tilveroBundleID`, `tilveroProfile=monitoring`, `tilveroTeamID` and `tilveroArchitecture=arm64` matching the installed profile. Sparkle validates archive signatures and the replacement app signature. Stable/beta selection adds only the beta channel; it never changes feed/profile/identity or admits a downgrade.

The updater delegate pins the actual runtime feed to the sealed URL even when legacy `SUFeedURL` preferences exist, and the check gate verifies that effective URL. Local feed verification binds the admitted build's audience, display version and minimum OS to its release manifest and rejects duplicate or conflicting canonical fields. A beta item must explicitly retain `beta`; stable uses the default audience.

## Consent, recovery and quit

Opening Updates, checking metadata, checking an appcast and reading notes perform no termination recovery. The custom native `SPUUserDriver` provides an explicit **Install and Restart…** choice before its first `.install` reply. It explains that this starts authenticated download/preparation and that an installer already started may finish after host exit, including an unexpected exit. This is an installation choice, not a download-only promise.

Every initial, resumed, ready-to-install and retry-termination handoff requires explicit choice, a fresh read-only readiness snapshot, acquisition of the model's installation exclusion/lease, shared verified recovery and another fresh readiness snapshot. The lease and mutation exclusion remain held while staging. The final ready prompt asks again before the planned restart. Cancellation or blockers return `.skip`, which cancels staged installation; the driver never returns `.dismiss`, because Sparkle defines that choice as potentially retaining installation on quit.

Ordinary application quit is blocked while an installation is staging unless a freshly validated install handoff permits termination. A retry after canceled/delayed termination asks again and repeats readiness. Sparkle's relaunch-postponement delegate is only defense in depth: its documentation explicitly says some routes do not invoke it. The user-driver gates and application termination gate cover those routes independently.

No silent or install-on-next-normal-quit mode is exposed. Force termination, host crash or OS failure after explicit installation has started cannot be represented as a cancelable download-only state; Sparkle may complete an already-authorized replacement. The first Monitoring profile forbids controller ownership, and unknown native/helper/lid state blocks admission before that first handoff. This does not qualify controller updates or guarantee recovery under every process/OS failure.

## Build paths

`build-local-app.sh` embeds the pinned framework from SwiftPM artifacts under `Contents/Frameworks`, retains its upstream signature and applies disabled updater policy to development/Lab bundles. `build-xcode.sh` supplies a generated app-only Info.plist and Xcode links/embeds the exact package product with Code Sign On Copy. Neither build promotes bundle identity or release profile. Direct Xcode development builds remain unqualified without a sealed release configuration.

For a future Developer ID release, `release.py` keeps its existing clean exact-commit, fresh-version, source-export, Monitoring, notarization and downloaded-install gates. It signs Sparkle's Autoupdate tool, XPC services, Updater app and framework inside out with the explicitly supplied existing owner identity before signing the outer app. No `--deep` signing, key generation, credential acquisition or protection bypass is added. Strict nested verification remains required. `Config/Sparkle-2.10.1.inventory.json` binds every resource, permitted standard symlink and executable payload from the checksum-verified upstream artifact. Payload hashing covers Mach-O load commands and code/data while normalizing only signature allocation bookkeeping, so owner re-signing does not permit substituted executable code.

## Preparing a future feed

Do not change the immutable source-only `v0.1.0-beta.2` assets. Select a fresh version/tag and increasing build, provide the owner-controlled Team ID, HTTPS Monitoring feed and existing public key in `Config/Updater.json`, then commit those public configuration values through the normal feature/release review. Private keys never belong in this repository. `Config/Updater.schema.json` describes the public format; `updater_package.py validate-config` applies stricter transport/key/profile checks.

First produce and accept an actual Developer ID signed, notarized, downloaded Monitoring binary with `release.py`. The future preparation tool requires that accepted release manifest and verifies the actual image through the existing release validator. Separately obtain the archive's Ed25519 signature using the owner's existing signing process. This implementation has not accessed that private key.

```sh
python3 scripts/updater_feed.py prepare \
  --config Config/Updater.json \
  --release-manifest <accepted-release-directory>/release.json \
  --archive-signature <existing-archive-signature-text-file> \
  --download-url <HTTPS-URL-matching-the-admitted-DMG-name> \
  --output <new-path>/appcast.unsigned.xml
```

Preparation writes only a fresh `.unsigned.xml`, explicitly unsuitable for publication. Its single item includes the exact profile attributes above. Have the owner-controlled existing Sparkle signing process sign the final appcast bytes; do not edit after signing. This repository's verifier uses CryptoKit and only a public key, because Sparkle's `sign_update --verify` implementation still loads signing keys. It does not touch Keychain.

```sh
source scripts/toolchain.sh
python3 scripts/updater_feed.py verify \
  --config Config/Updater.json \
  --release-manifest <accepted-release-directory>/release.json \
  --feed <owner-signed-appcast.xml>
```

Verification checks signed-feed structure/length/signature, exact profile and admitted build, archive name/length and actual archive signature. It never publishes. Owner-controlled hosting, authenticated feed retrieval, quarantined downloaded upgrade/relaunch, cancellation, offline/tamper and compatible rollback acceptance remain required before distribution can be called ready. Rollback compatibility is separate from permission to downgrade software/data or undo hardware ownership.

## Primary contracts

- [Sparkle user driver](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUserDriver.html): install/dismiss/skip and resumed stages.
- [Sparkle updater delegate](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html): relaunch delegate limitations and channel filtering.
- [Sparkle customization](https://sparkle-project.org/documentation/customization/): signing, profiling and automatic-update policy.
- [Sparkle package manifest at the pin](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Package.swift): binary URL/checksum.
