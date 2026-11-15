# Tilvero GitHub traffic

Snapshot collected on 15 November 2026 UTC from the GitHub API.

| Metric | Value | Scope |
| --- | ---: | --- |
| Git clones | 1521 | Sum of the daily counts below, 27 October (repository creation) through 13 November 2026 UTC; GitHub itself only returns the latest 14 days, so older days are kept in a local file |
| Unique cloners | 398 | The highest `uniques` value GitHub returned for any 14-day window (31 October through 13 November); unique cloners cannot be summed across days, so this is a lower bound for the whole period |
| Source ZIP downloads | 22 | All nine published custom source ZIPs |
| Source ZIP downloads excluding verification | 15 | The twenty-two reported downloads minus seven project verification downloads (the published `v0.2.0`, `v0.3.0-beta.1`, `v0.4.0-beta.1`, `v0.4.0`, `v0.5.0-beta.1`, `v0.6.0` and `v0.6.1` archives were re-downloaded to check them) |
| Downloads of uploaded release assets | 51 | Twenty-two source ZIP downloads, fourteen manifest downloads and fifteen checksum downloads |

The repository was created on 27 October. GitHub returned zero clones for
25–26 October and the following counts for 27 October through 13 November
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

Use the API's window-level `uniques` for the whole period. Adding daily
unique counts can count the same client on more than one day. Clone traffic can
include automation, and GitHub reports these counts without identifying people.

| Release | Source ZIP | Manifest | Checksums |
| --- | ---: | ---: | ---: |
| `v0.1.0-beta.1` | 2 | 2 | 2 |
| `v0.1.0-beta.2` | 3 | 2 | 2 |
| `v0.2.0` | 2 | 1 | 2 |
| `v0.3.0-beta.1` | 3 | 1 | 1 |
| `v0.4.0-beta.1` | 2 | 1 | 1 |
| `v0.4.0` | 2 | 1 | 1 |
| `v0.5.0-beta.1` | 3 | 2 | 2 |
| `v0.6.0` | 3 | 2 | 2 |
| `v0.6.1` | 2 | 2 | 2 |

The `v0.2.0`, `v0.3.0-beta.1`, `v0.4.0-beta.1`, `v0.4.0`, `v0.5.0-beta.1`, `v0.6.0` and `v0.6.1` source ZIP counts each include the download used to check the published
archive; GitHub may update these counters with a delay. The releases contain source and metadata. GitHub lists no uploaded app
or DMG for this snapshot, and the asset counts exclude GitHub's generated source
archives. Successful installations are unmeasured.

For a README badge, label the metric and date. The same client may download a ZIP
and clone the repository, and release downloads and clone traffic cover different
periods.

[GitHub clone traffic API](https://docs.github.com/en/rest/metrics/traffic#get-repository-clones) ·
[GitHub release asset API](https://docs.github.com/en/rest/releases/assets#list-release-assets) ·
[Tilvero releases](https://github.com/RaNDoM6913/Tilvero/releases)
