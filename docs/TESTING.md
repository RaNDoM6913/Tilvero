# Testing Tilvero

Run the default checks from a checkout on Apple silicon with macOS 26 or later and a compatible full Xcode installation:

```sh
bash scripts/test.sh
python3 -m unittest discover -s Tests/ReleaseToolsTests
```

The scripts select the installed full Xcode toolchain for their own process. They do not change the system's selected Xcode.

## What the checks cover

- Battery values, availability, source freshness, exact counters and device boundaries.
- Charging intent, pending lower targets, operation uncertainty, persistence and restoration contracts through isolated transports.
- Process sampling, missing coverage, PID reuse, search, ranking and display limits.
- Local history, gaps, retention, identity pairing, sleep records and failed-store recovery.
- Native presentation and layout contracts, localization and passive previews.
- Sleep Timer/Awake mode consent, confirmed preset identity, failed holds/releases, stale session actions, civil-time validation and native popover completion.
- Lid-only controller authority, journal/replay/lease recovery, independent guardian and explicit fixture/live admission boundaries.
- Release tooling: committed-source admission, private-path rejection, source identity, checksums and tamper rejection.

Default automated tests use fixtures for controls. They do not qualify physical charge cutoff, battery discharge, real fan control, privileged enrollment, closed-lid operation or recovery under every OS failure. Closed-lid tests inject all writers; a real signed trial requires the separate [device and restoration checks](CLOSED_LID.md).

The Sleep-controls source milestone passed **557 Swift tests and 61 Python release-tool tests**, plus SwiftPM Release and Xcode Debug app builds. All 13 prototype migration tests passed. The prior first-source-preview baseline passed 362 Swift tests and 45 Python release-tool tests.

An earlier complete run failed 8 migration-journal read/reopen operations with `EPERM` for `completeFileProtectionUnlessOpen`. A standalone Foundation probe reproduced the failure without Tilvero code. Later, fresh protected-file roundtrips and the same previously failing synthetic files reopened/read successfully with unchanged Class B protection and `0600` permissions; the full unchanged-source suite then passed. No protection/permission/entitlement change, test skip or migration bypass was used. The exact external authentication/system transition remains unknown. Verify authenticated host protection availability when reproducing this class of failure rather than weakening file protection. These are local code/fixture results, not Developer ID, notarization, downloaded-install or hardware-support claims.

## Source preview verification

The source-only package contains exactly a source ZIP, `source-release.json` and `SHA256SUMS`. In the downloaded asset directory:

```sh
shasum -a 256 -c SHA256SUMS
```

For a complete byte/mode comparison with the committed Git tree, use a checkout containing the manifest's commit:

```sh
python3 scripts/source_release.py --root /path/to/Tilvero verify \
  --manifest /path/to/downloaded-assets/source-release.json
```

The tool does not publish, build, launch, sign or install an application. A ZIP without its corresponding Git commit cannot establish full committed-tree equality; checksum verification alone establishes file integrity.

The future DMG pipeline is separate. See [releasing](RELEASING.md) for its signing, notarization and actual downloaded-install gates.

## Interface gallery

The README gallery renders the actual SwiftUI views with isolated, injected synthetic data. Every image carries a DEMO DATA label. It does not expose an owner's telemetry, process list, serial number or history; it is not evidence of hardware control or a signed distribution build. Decorative product illustrations are distinct from those native-interface previews.
