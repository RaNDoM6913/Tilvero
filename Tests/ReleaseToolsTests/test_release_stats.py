"""Read-only release reporting contracts; all API responses are fixtures."""

import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "release_stats.py"
spec = importlib.util.spec_from_file_location("release_stats", SCRIPT)
stats = importlib.util.module_from_spec(spec)
if SCRIPT.exists():
    spec.loader.exec_module(stats)


def release(identifier=1, *, beta=False, draft=False):
    return {"id": identifier, "tag_name": f"v{identifier}", "draft": draft,
            "prerelease": beta, "published_at": None if draft else "2026-10-27T00:00:00Z"}


def asset(identifier=1, *, name="Tilvero-0.1.0-beta.1-arm64.dmg", count=7, state="uploaded"):
    return {"id": identifier, "name": name, "state": state, "download_count": count}


class FixtureAPI:
    def __init__(self, routes):
        self.routes = routes
        self.calls = []

    def get_json(self, endpoint):
        self.calls.append(endpoint)
        value = self.routes[endpoint]
        if isinstance(value, Exception):
            raise value
        return value


class ReleaseStatsTests(unittest.TestCase):
    def test_selected_channels_exclude_drafts_and_non_application_assets(self):
        releases = [release(), release(2, beta=True), release(3, draft=True)]
        pages = {1: [[asset(), asset(2, name="SHA256SUMS"), asset(3, name="Other-arm64.dmg"),
                      asset(4, name="Tilvero-source.zip"), asset(5, state="starter"),
                      asset(6, name="Tilvero-0.1.0-arm64.dmg.sha256")]],
                 2: [[asset(20, count=3)]], 3: [[asset(30, count=1000)]]}
        for channel, expected in [("all", 10), ("beta", 3), ("stable", 7)]:
            with self.subTest(channel=channel):
                report = stats.collect_downloads(releases, pages, channel)
                self.assertEqual(report["dmgDownloads"], expected)

    def test_deduplicates_release_and_asset_ids(self):
        report = stats.collect_downloads([release(), release()], {1: [[asset()], [asset()]]}, "all")
        self.assertEqual(report["dmgDownloads"], 7)
        self.assertEqual(len(report["perAsset"]), 1)
        self.assertEqual(len(report["perRelease"]), 1)

    def test_renamed_asset_is_not_counted_and_replacement_has_its_own_id(self):
        report = stats.collect_downloads([release()], {1: [[asset(name="retired.zip"), asset(2, count=2)]]}, "all")
        self.assertEqual(report["dmgDownloads"], 2)
        self.assertEqual(report["perAsset"][0]["assetId"], 2)

    def test_missing_asset_pages_cannot_masquerade_as_empty(self):
        with self.assertRaises(stats.StatsError):
            stats.collect_downloads([release()], {}, "all")

    def test_invalid_counts_fail_instead_of_defaulting_to_zero(self):
        for value in [-1, True, "8", None, 1.2]:
            with self.subTest(value=value), self.assertRaises(stats.StatsError):
                stats.collect_downloads([release()], {1: [[asset(count=value)]]}, "all")

    def test_conflicting_duplicate_cannot_report_a_mixed_snapshot(self):
        with self.assertRaises(stats.StatsError):
            stats.collect_downloads([release()], {1: [[asset(), asset(count=8)]]}, "all")

    def test_rename_or_state_change_during_pagination_invalidates_observation(self):
        for changed in [asset(name="retired.zip"), asset(state="starter")]:
            with self.subTest(changed=changed), self.assertRaises(stats.StatsError):
                stats.collect_downloads([release()], {1: [[asset()], [changed]]}, "all")

    def test_paginates_releases_and_selected_assets_independently(self):
        releases = [release(i) for i in range(1, 101)]
        routes = {"repos/test/repo/releases?per_page=100&page=1": releases,
                  "repos/test/repo/releases?per_page=100&page=2": [release(101, beta=True)]}
        for item in releases:
            routes[f"repos/test/repo/releases/{item['id']}/assets?per_page=100&page=1"] = []
        routes["repos/test/repo/releases/1/assets?per_page=100&page=1"] = [asset(i, count=1) for i in range(1, 101)]
        routes["repos/test/repo/releases/1/assets?per_page=100&page=2"] = [asset(101, count=2)]
        api = FixtureAPI(routes)
        report = stats.fetch_report("test/repo", "stable", api, now="2026-10-27T12:00:00Z")
        self.assertEqual(report["availability"], "available")
        self.assertEqual(report["dmgDownloads"], 102)
        self.assertEqual(report["retrievedAt"], "2026-10-27T12:00:00Z")
        self.assertEqual(len(report["perAsset"]), 101)
        self.assertFalse(any("/101/assets" in call for call in api.calls))

    def test_empty_repository_reports_no_published_dmgs(self):
        api = FixtureAPI({"repos/test/repo/releases?per_page=100&page=1": []})
        report = stats.fetch_report("test/repo", "all", api, now="2026-10-27T12:00:00Z")
        self.assertEqual(report["availability"], "available")
        self.assertEqual(report["dmgDownloads"], 0)
        self.assertEqual(report["perRelease"], [])
        self.assertIn("No published DMGs", stats.render_table(report))

    def test_api_and_invalid_response_failures_are_unavailable_without_partial_counts(self):
        for failure in [stats.StatsError("HTTP 403"), TimeoutError(), {"message": "rate limit"}]:
            with self.subTest(failure=failure):
                api = FixtureAPI({"repos/test/repo/releases?per_page=100&page=1": failure})
                report = stats.fetch_report("test/repo", "all", api, now="2026-10-27T12:00:00Z")
                self.assertEqual(report["availability"], "unavailable")
                self.assertIsNone(report["dmgDownloads"])
                self.assertIsNone(report["retrievedAt"])
                self.assertEqual(report["attemptedAt"], "2026-10-27T12:00:00Z")

    def test_asset_page_failure_does_not_return_partial_total(self):
        api = FixtureAPI({"repos/test/repo/releases?per_page=100&page=1": [release(), release(2)],
                          "repos/test/repo/releases/1/assets?per_page=100&page=1": [asset()],
                          "repos/test/repo/releases/2/assets?per_page=100&page=1": stats.StatsError("HTTP 403")})
        report = stats.fetch_report("test/repo", "all", api)
        self.assertIsNone(report["dmgDownloads"])
        self.assertEqual(report["perAsset"], [])

    def test_unpublished_or_invalid_release_metadata_fails_closed(self):
        for mutation in [{"published_at": None}, {"draft": "false"}, {"prerelease": None}]:
            item = release()
            item.update(mutation)
            if mutation == {"published_at": None}:
                self.assertEqual(stats.collect_downloads([item], {}, "all")["dmgDownloads"], 0)
            else:
                with self.assertRaises(stats.StatsError):
                    stats.collect_downloads([item], {1: [[]]}, "all")

    def test_transport_uses_get_and_redacts_external_error_text(self):
        with patch.object(stats.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "[]", "")) as run:
            self.assertEqual(stats.GhAPI().get_json("repos/test/repo/releases"), [])
            command = run.call_args.args[0]
            self.assertEqual(command[:4], ["gh", "api", "--method", "GET"])
        for stderr in ["HTTP 403 secret-value", "API rate limit exceeded secret-value"]:
            with patch.object(stats.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", stderr)):
                with self.assertRaises(stats.StatsError) as raised:
                    stats.GhAPI().get_json("repos/test/repo/releases")
                self.assertNotIn("secret-value", str(raised.exception))

    def test_transport_timeout_invalid_json_and_missing_gh_are_errors(self):
        for failure in [subprocess.TimeoutExpired("gh", 30), FileNotFoundError()]:
            with patch.object(stats.subprocess, "run", side_effect=failure), self.assertRaises(stats.StatsError):
                stats.GhAPI().get_json("repos/test/repo/releases")
        with patch.object(stats.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "invalid", "")), self.assertRaises(stats.StatsError):
            stats.GhAPI().get_json("repos/test/repo/releases")

    def test_cli_error_exit_does_not_print_zero(self):
        import contextlib
        import io
        output = io.StringIO()
        with patch.object(stats.GhAPI, "get_json", side_effect=stats.StatsError("HTTP 403")), contextlib.redirect_stdout(output):
            code = stats.main(["--repo", "test/repo", "--format", "json"])
        self.assertEqual(code, 2)
        self.assertIsNone(json.loads(output.getvalue())["dmgDownloads"])

    def test_invalid_repo_cannot_be_interpreted_as_gh_options(self):
        with self.assertRaises(stats.StatsError):
            stats.fetch_report("--hostname/example", "all", FixtureAPI({}))


if __name__ == "__main__":
    unittest.main()
