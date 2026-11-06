"""Disposable Git/source fixtures; signing and build boundaries are always injected."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("lid_trial", ROOT / "scripts/build-lid-trial.py")
trial = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(trial)
TEAM = "ABCDEFGHIJ"
IDENTITY = "A" * 40


class LidTrialTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve() / "repo"
        self.root.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Disposable Test")
        self.git("config", "user.email", "fixture@example.invalid")
        for name in trial.REQUIRED:
            self.write(name, b"// fixture input\n")
        self.write(".gitignore", b"/local-lab/\n")
        self.write("Config/Info.plist", plistlib.dumps({
            "CFBundleIdentifier": "local.tilvero.prototype", "CFBundleExecutable": "TilveroApp",
            "TilveroTeamIdentifier": "OTHERTEAM1", "TilveroAppIdentifier": "ordinary.app",
            "TilveroHelperIdentifier": "ordinary.helper", "TilveroReleaseMode": "monitoring"}))
        self.write("Config/TilveroLidHelper-Info.plist", plistlib.dumps({"CFBundleIdentifier": trial.HELPER_ID}))
        for name in trial.LID_PLISTS | {"local.tilvero.helper.plist"}:
            self.write("Config/LaunchDaemons/" + name, b"fixture launch resource")
        self.commit()

    def git(self, *arguments):
        return subprocess.check_output(["git", "-C", str(self.root), *arguments]).decode().strip()

    def write(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "Disposable fixture")
        self.commit_id = self.git("rev-parse", "HEAD")

    def prepare(self, output=None):
        return trial.prepare(self.root, self.commit_id, TEAM, output)

    def test_default_prepares_exact_source_without_build_or_signing_and_isolates_metadata(self):
        original = (self.root / "Config/Info.plist").read_bytes()
        with patch.object(trial, "verify_identity", side_effect=AssertionError("No keychain access")):
            candidate, receipt = self.prepare()
        self.assertTrue(candidate.name.startswith("lid-trial-"))
        self.assertEqual(candidate.parent, self.root / "local-lab/.staging.noindex")
        self.assertEqual(receipt["commit"], self.commit_id)
        self.assertEqual(receipt["build"], "not performed")
        self.assertEqual(receipt["signing"], "not performed")
        self.assertEqual(receipt["preparedInputs"], trial.inventory(candidate / "Source"))
        info = plistlib.loads((candidate / "Source/Config/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], trial.APP_ID)
        self.assertEqual(info["TilveroDataScope"], "lid-trial")
        self.assertTrue(info["TilveroLidTrialHost"])
        self.assertEqual(info["TilveroLidTeamIdentifier"], TEAM)
        self.assertNotIn("TilveroTeamIdentifier", info)
        self.assertNotIn("TilveroReleaseMode", info)
        self.assertEqual((self.root / "Config/Info.plist").read_bytes(), original)
        self.assertFalse((candidate / trial.APP_NAME).exists())
        self.assertFalse((candidate / "Source/local-lab").exists())
        self.assertFalse((candidate / "Source/.git").exists())

    def test_dirty_wrong_commit_and_incomplete_sources_are_rejected(self):
        with self.assertRaises(trial.TrialError):
            trial.prepare(self.root, "0" * 40, TEAM)
        self.write("untracked", b"foreign input")
        with self.assertRaises(trial.TrialError):
            self.prepare()
        (self.root / "untracked").unlink()
        self.write("Package.swift", b"changed")
        with self.assertRaises(trial.TrialError):
            self.prepare()
        self.git("checkout", "--", "Package.swift")
        (self.root / "Sources/TilveroApp/ClosedLidService.swift").unlink()
        self.commit()
        with self.assertRaises(trial.TrialError):
            self.prepare()

    def test_committed_symlinks_and_private_material_are_rejected(self):
        (self.root / "linked.swift").symlink_to("Package.swift")
        self.commit()
        with self.assertRaises(trial.TrialError):
            self.prepare()
        self.git("rm", "linked.swift")
        self.write("identity.p12", b"not an actual identity")
        self.commit()
        with self.assertRaises(trial.TrialError):
            self.prepare()

    def test_output_preserves_existing_candidates_and_rejects_foreign_or_symlink_paths(self):
        staging = self.root / "local-lab/.staging.noindex"
        prior = staging / "lid-trial-prior"
        prior.mkdir(parents=True)
        (prior / "preserve").write_text("original")
        for output in (str(prior), str(self.root / "build/Tilvero.app"),
                       str(staging / "other"), str(staging / "lid-trial-nested/extra")):
            with self.subTest(output=output), self.assertRaises((trial.TrialError, FileExistsError)):
                self.prepare(output)
        alias = staging / "lid-trial-alias"
        alias.symlink_to(prior, target_is_directory=True)
        with self.assertRaises(trial.TrialError):
            self.prepare(str(alias))
        self.assertEqual((prior / "preserve").read_text(), "original")
        self.assertFalse((self.root / "build").exists())

    def test_signing_requires_exact_valid_certificate_and_matching_team_before_build(self):
        for identity, options in (("-", {}), (IDENTITY, {"wrong_team": True}),
                                  (IDENTITY, {"missing_identity": True})):
            candidate, receipt = self.prepare()
            boundary = TrialBoundary(**options)
            with self.subTest(identity=identity, options=options), self.assertRaises(trial.TrialError):
                trial.build_and_sign(self.root, candidate, receipt, identity, boundary)
            self.assertFalse(any(call[0] == "bash" for call in boundary.calls))
            self.assertFalse((candidate / "signed-lid-trial-receipt.json").exists())

    def test_explicit_build_signs_only_dedicated_trial_and_binds_complete_receipt(self):
        candidate, receipt = self.prepare()
        boundary = TrialBoundary()
        app = trial.build_and_sign(self.root, candidate, receipt, IDENTITY, boundary)
        signed = json.loads((candidate / "signed-lid-trial-receipt.json").read_text())
        self.assertEqual(signed["packagedFiles"], trial.bundle_inventory(app))
        self.assertEqual(signed["physicalQualification"], "not performed")
        self.assertEqual(signed["installation"], "not performed")
        self.assertEqual(signed["enrollment"], "not performed")
        self.assertEqual(signed["launch"], "not performed")
        self.assertFalse((app / "Contents/Library/HelperTools/TilveroHelper").exists())
        self.assertEqual((app / "Contents/_CodeSignature/CodeResources").read_bytes(), b"real signing-owned envelope")
        self.assertEqual({p.name for p in (app / "Contents/Library/LaunchDaemons").iterdir()}, trial.LID_PLISTS)
        requirements = [call[call.index("-R") + 1] for call in boundary.calls if "-R" in call]
        self.assertEqual(len(requirements), 2)
        self.assertTrue(all('anchor apple generic' in requirement and TEAM in requirement for requirement in requirements))
        self.assertTrue(any(trial.HELPER_ID in requirement for requirement in requirements))
        self.assertTrue(any(trial.APP_ID in requirement for requirement in requirements))
        self.assertFalse(any("--studio" in call or "--laboratory" in call for call in boundary.calls))
        self.assertFalse(any(call[0] in {"open", "launchctl", "sudo"} for call in boundary.calls))

    def test_prepared_mutation_fails_before_build(self):
        candidate, receipt = self.prepare()
        (candidate / "Source/Package.swift").write_text("changed")
        boundary = TrialBoundary()
        with self.assertRaises(trial.TrialError):
            trial.build_and_sign(self.root, candidate, receipt, IDENTITY, boundary)
        self.assertFalse(any(call[0] == "bash" for call in boundary.calls))

    def test_build_or_signing_mutation_cannot_get_a_success_receipt(self):
        for option in ("mutate_source", "mutate_metadata", "mutate_resource", "symlink_helper", "hardlink_helper"):
            candidate, receipt = self.prepare()
            boundary = TrialBoundary(**{option: True})
            with self.subTest(option=option), self.assertRaises(trial.TrialError):
                trial.build_and_sign(self.root, candidate, receipt, IDENTITY, boundary)
            self.assertFalse((candidate / "signed-lid-trial-receipt.json").exists())
            if option != "mutate_resource":
                self.assertFalse(any("--sign" in call for call in boundary.calls))


class TrialBoundary:
    """No process execution: model only the expected tools and exact output paths."""
    def __init__(self, **options):
        self.options = options
        self.calls = []
        self.app = None

    def __call__(self, arguments, *, cwd=None, data=None):
        self.calls.append(arguments)
        tool = arguments[0]
        if tool == "/usr/bin/security":
            if "find-identity" in arguments:
                return b"" if self.options.get("missing_identity") else ('  1) ' + IDENTITY + ' "Fixture"\n').encode()
            return b"-----BEGIN CERTIFICATE-----fixture-----END CERTIFICATE-----"
        if tool == "/usr/bin/openssl":
            team = "WRONGTEAM1" if self.options.get("wrong_team") else TEAM
            return ('subject= CN=Fixture,OU=' + team + '\nsha1 Fingerprint=' + ':'.join(["AA"] * 20) + '\n').encode()
        if tool == "bash":
            source = Path(cwd)
            self.app = Path(arguments[-1])
            for name, content in {
                "Contents/Info.plist": (source / "Config/Info.plist").read_bytes(),
                "Contents/MacOS/TilveroApp": b"app binary",
                "Contents/Library/HelperTools/TilveroLidHelper": b"lid binary",
                "Contents/Library/HelperTools/TilveroHelper": b"ordinary binary",
                "Contents/Resources/resource": b"resource bytes",
                "Contents/_CodeSignature/CodeResources": b"ad-hoc signing-owned envelope",
            }.items():
                path = self.app / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
            for path in (source / "Config/LaunchDaemons").iterdir():
                destination = self.app / "Contents/Library/LaunchDaemons" / path.name
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(path.read_bytes())
            if self.options.get("mutate_source"):
                (source / "Package.swift").write_text("mutated")
            if self.options.get("mutate_metadata"):
                (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "foreign.app"}))
            helper = self.app / "Contents/Library/HelperTools/TilveroLidHelper"
            if self.options.get("symlink_helper") or self.options.get("hardlink_helper"):
                helper.unlink()
                target = self.app / "Contents/Resources/resource"
                if self.options.get("symlink_helper"):
                    helper.symlink_to(target)
                else:
                    os.link(target, helper)
            return b""
        if tool == "/usr/bin/codesign":
            if "--sign" in arguments:
                target = Path(arguments[-1])
                binary = target / "Contents/MacOS/TilveroApp" if target.is_dir() else target
                binary.write_bytes(binary.read_bytes() + b"signed")
                if target.is_dir():
                    (target / "Contents/_CodeSignature/CodeResources").write_bytes(b"real signing-owned envelope")
                if self.options.get("mutate_resource"):
                    (self.app / "Contents/Resources/resource").write_bytes(b"tampered")
            return b""
        raise AssertionError("Unexpected external boundary: " + repr(arguments))


if __name__ == "__main__":
    unittest.main()
