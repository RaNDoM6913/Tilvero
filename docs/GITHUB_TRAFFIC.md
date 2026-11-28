# Tilvero GitHub traffic

Snapshot collected on 28 November 2026 UTC from the GitHub API.

| Metric | Value | Scope |
| --- | ---: | --- |
| Git clones | 3393 | Sum of the daily counts below, 27 October (repository creation) through 27 November 2026 UTC; GitHub itself only returns the latest 14 days, so older days are kept in a local file |
| Unique cloners | 461 | The highest `uniques` value GitHub returned for any 14-day window (12 November through 25 November); unique cloners cannot be summed across days, so this is a lower bound for the whole period |
| Source ZIP downloads | 41 | All fifteen published custom source ZIPs |
| Source ZIP downloads excluding verification | 28 | The forty-one reported downloads minus thirteen project verification downloads (the published `v0.2.0`, `v0.3.0-beta.1`, `v0.4.0-beta.1`, `v0.4.0`, `v0.5.0-beta.1`, `v0.6.0`, `v0.6.1`, `v0.6.2`, `v0.7.0`, `v0.7.1`, `v0.8.0`, `v0.8.1` and `v0.8.2` archives were re-downloaded to check them) |
| Downloads of uploaded release assets | 437 | Forty-one source ZIP downloads, three hundred sixty-nine manifest downloads and twenty-seven checksum downloads |

The repository was created on 27 October. GitHub returned zero clones for
25–26 October and the following counts for 27 October through 27 November
(the last day is partial).

| Date (UTC) | Clones | Unique cloners that day |
| --- | ---: | ---: |
| 27 October | 20 | 11 |
| 28 October | 35 | 15 |
| 29 October | 56 | 26 |
| 30 October | 62 | 32 |
| 31 October | 33 | 16 |
| 1 November | 30 | 16 |
| 2 November | 33 | 17 |
| 3 November | 66 | 36 |
| 4 November | 297 | 74 |
| 5 November | 88 | 32 |
| 6 November | 225 | 90 |
| 7 November | 232 | 65 |
| 8 November | 86 | 31 |
| 9 November | 39 | 11 |
| 10 November | 26 | 12 |
| 11 November | 13 | 9 |
| 12 November | 91 | 39 |
| 13 November | 89 | 36 |
| 14 November | 53 | 27 |
| 15 November | 83 | 26 |
| 16 November | 20 | 7 |
| 17 November | 105 | 42 |
| 18 November | 36 | 18 |
| 19 November | 438 | 75 |
| 20 November | 569 | 103 |
| 21 November | 125 | 48 |
| 22 November | 104 | 39 |
| 23 November | 89 | 27 |
| 24 November | 143 | 53 |
| 25 November | 55 | 21 |
| 26 November | 26 | 10 |
| 27 November | 26 | 10 |

Use the API's window-level `uniques` for the whole period. Adding daily
unique counts can count the same client on more than one day. Clone traffic can
include automation, and GitHub reports these counts without identifying people.

| Release | Source ZIP | Manifest | Checksums |
| --- | ---: | ---: | ---: |
| `v0.1.0-beta.1` | 3 | 29 | 2 |
| `v0.1.0-beta.2` | 3 | 29 | 2 |
| `v0.2.0` | 2 | 28 | 2 |
| `v0.3.0-beta.1` | 3 | 28 | 1 |
| `v0.4.0-beta.1` | 2 | 28 | 1 |
| `v0.4.0` | 2 | 28 | 1 |
| `v0.5.0-beta.1` | 3 | 29 | 2 |
| `v0.6.0` | 3 | 29 | 2 |
| `v0.6.1` | 2 | 29 | 2 |
| `v0.6.2` | 3 | 29 | 2 |
| `v0.7.0` | 3 | 29 | 2 |
| `v0.7.1` | 4 | 29 | 2 |
| `v0.8.0` | 3 | 13 | 2 |
| `v0.8.1` | 3 | 9 | 2 |
| `v0.8.2` | 2 | 3 | 2 |

The `v0.2.0`, `v0.3.0-beta.1`, `v0.4.0-beta.1`, `v0.4.0`, `v0.5.0-beta.1`, `v0.6.0`, `v0.6.1`, `v0.6.2`, `v0.7.0`, `v0.7.1`, `v0.8.0`, `v0.8.1` and `v0.8.2` source ZIP counts each include the download used to check the published
archive; GitHub may update these counters with a delay. The releases contain source and metadata. GitHub lists no uploaded app
or DMG for this snapshot, and the asset counts exclude GitHub's generated source
archives. Successful installations are unmeasured.

For a README badge, label the metric and date. The same client may download a ZIP
and clone the repository, and release downloads and clone traffic cover different
periods.

[GitHub clone traffic API](https://docs.github.com/en/rest/metrics/traffic#get-repository-clones) ·
[GitHub release asset API](https://docs.github.com/en/rest/releases/assets#list-release-assets) ·
[Tilvero releases](https://github.com/RaNDoM6913/Tilvero/releases)
