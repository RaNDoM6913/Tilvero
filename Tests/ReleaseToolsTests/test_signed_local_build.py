"""Disposable source fixtures; no real build, signing, keychain or system actions."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/build-signed-local.py"
TEAM = "ABCDEFGHIJ"
IDENTITY = "A" * 40


def macho(info=None):
    content = plistlib.dumps(info) if info is not None else b"fixture-code"
    size = 152 if info is not None else 72
    header = struct.pack("<8I", 0xfeedfacf, 0x100000c, 0, 2, 1, size, 0, 0)
    segment = struct.pack("<II16sQQQQIIII", 0x19, size, b"__TEXT", 0, 4096,
                          0, 32 + size + len(content), 7, 5, int(info is not None), 0)
    section = b""
    if info is not None:
        section = struct.pack("<16s16sQQIIIIIIII", b"__info_plist", b"__TEXT", 0,
                              len(content), 32 + size, 0, 0, 0, 0, 0, 0, 0)
    return header + segment + section + content


class SignedLocalTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.exists(), "Missing source-bound signed-local preparation route")
        spec = importlib.util.spec_from_file_location("signed_local", SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve() / "repo"
        self.root.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Disposable Test")
        self.git("config", "user.email", "fixture@example.invalid")
        for name in self.module.REQUIRED:
            self.write(name, b"fixture input\n")
        self.write(".gitignore", b"/local-lab/\n")
        for name in ("build-xcode.sh", "toolchain.sh", "generate-xcode-project.py", "updater_package.py", "build-signed-local.py", "build-lid-trial.py"):
            self.write("scripts/" + name, (ROOT / "scripts" / name).read_bytes())
        # Real default metadata and the owning runtime contract are fixture inputs.
        self.write("Config/Info.plist", (ROOT / "Config/Info.plist").read_bytes())
        self.write("Sources/TilveroApp/ReleaseIdentity.swift", (ROOT / "Sources/TilveroApp/ReleaseIdentity.swift").read_bytes())
        self.write("Config/HelperInfo.plist", plistlib.dumps({"CFBundleIdentifier": self.module.HELPER_ID}))
        self.write("Config/LaunchDaemons/local.tilvero.helper.plist", plistlib.dumps({
            "BundleProgram": "Contents/Library/HelperTools/TilveroHelper",
            "MachServices": {self.module.HELPER_ID: True}}))
        self.write("Config/Updater.json", (ROOT / "Config/Updater.json").read_bytes())
        self.write("Sources/TilveroApp/Screen.swift", b"// source fixture\n")
        self.write("Helper/main.swift", b"// helper fixture\n")
        self.write("Tilvero.xcodeproj/project.pbxproj", b"// generated graph fixture\n")
        self.sparkle = {"Versions/B/Sparkle": macho(), "Versions/B/Autoupdate": macho(),
            "Versions/B/Updater.app/Contents/MacOS/Updater": macho(),
            "Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer": macho(),
            "Versions/B/Resources/Info.plist": plistlib.dumps({"CFBundleShortVersionString": "2.10.1"})}
        inventory = {"version": "2.10.1", "files": {}, "symlinks": {"Versions/Current": "B", "Sparkle": "Versions/Current/Sparkle"}}
        for name, data in self.sparkle.items():
            code = data[:4] == b"\xcf\xfa\xed\xfe"
            path = self.root / "scratch-code"
            path.write_bytes(data)
            digest = self.module.updater_package.code_payload_digest(path) if code else self.module.sha(data)
            inventory["files"][name] = {"kind": "code" if code else "resource", "sha256": digest}
        path.unlink()
        self.write("Config/Sparkle-2.10.1.inventory.json", json.dumps(inventory).encode())
        self.git("add", ".")
        self.git("commit", "-qm", "Disposable source fixture")
        self.commit = self.git("rev-parse", "HEAD")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args]).decode().strip()

    def write(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def prepare(self, output=None):
        return self.module.prepare(self.root, self.commit, TEAM, output)

    def test_prepare_has_no_build_sign_or_keychain_effects_and_preserves_originals(self):
        before = self.module.source_inventory(self.root)
        with patch.object(self.module, "verify_identity", side_effect=AssertionError("keychain")), patch.object(self.module, "command", wraps=self.module.command) as calls:
            candidate, receipt = self.prepare()
        self.assertTrue(all(call.args[0][0] == "git" for call in calls.call_args_list))
        self.assertEqual(candidate.parent, self.root / "local-lab/.staging.noindex")
        self.assertTrue(candidate.name.startswith("signed-local-"))
        self.assertFalse((candidate / "Source").exists())
        self.assertFalse((candidate / "Tilvero.app").exists())
        self.assertEqual(before, self.module.source_inventory(self.root))
        self.assertEqual(receipt["sourceRoot"], str(self.root))
        self.assertEqual(receipt["sourceInputs"], before)
        for name, identifier in (("AppInfo.plist", self.module.APP_ID), ("HelperInfo.plist", self.module.HELPER_ID)):
            info = plistlib.loads((candidate / name).read_bytes())
            self.assertEqual(info["CFBundleIdentifier"], identifier)
            self.assertEqual(info["TilveroTeamIdentifier"], TEAM)
            self.assertEqual(info["TilveroAppIdentifier"], self.module.APP_ID)
            self.assertEqual(info["TilveroHelperIdentifier"], self.module.HELPER_ID)
            self.assertFalse(any(key.startswith("TilveroLid") for key in info))
        self.assertEqual(plistlib.loads((candidate / "AppInfo.plist").read_bytes())["TilveroDataScope"], "prototype")
        self.assertEqual(receipt["dataScope"], "prototype")
        for key in ("build", "signing", "installation", "launch", "registration", "physicalQualification"):
            self.assertEqual(receipt[key], "not performed")

    def test_prepared_scope_preserves_real_prototype_runtime_data_boundary(self):
        # Primary runtime contract: ReleaseIdentity.init admits nil/"prototype"
        # for this ID. PrototypeMigrationTests.testReleaseIdentityChoosesDistinctStoreAndRejectsUnknownMetadata
        # asserts prototype history remains Tilvero/History.sqlite, distinct from
        # Tilvero/Production/History.sqlite. These Python tests do not execute Swift.
        source_info = plistlib.loads((ROOT / "Config/Info.plist").read_bytes())
        self.assertEqual(source_info["CFBundleIdentifier"], self.module.APP_ID)
        self.assertIn(source_info.get("TilveroDataScope"), (None, "prototype"))
        source_path = self.root / "Config/Info.plist"
        for scope in (None, "prototype"):
            admitted = dict(source_info)
            if scope is None:
                admitted.pop("TilveroDataScope", None)
            else:
                admitted["TilveroDataScope"] = scope
            source_path.write_bytes(plistlib.dumps(admitted))
            original = source_path.read_bytes()
            candidate, receipt = self.prepare()
            info = plistlib.loads((candidate / "AppInfo.plist").read_bytes())
            self.assertEqual(info["CFBundleIdentifier"], source_info["CFBundleIdentifier"])
            self.assertEqual(info["TilveroDataScope"], "prototype")
            self.assertEqual(receipt["dataScope"], "prototype")
            self.assertIn("Sources/TilveroApp/ReleaseIdentity.swift", receipt["sourceInputs"])
            self.assertEqual(source_path.read_bytes(), original)
        for scope in ("production", "laboratory", "lid-trial", "", False, 1, ["prototype"]):
            source_path.write_bytes(plistlib.dumps(dict(source_info, TilveroDataScope=scope)))
            with self.subTest(scope=scope), self.assertRaises(self.module.LocalBuildError):
                self.prepare()

    def test_prepare_allows_dirty_snapshot_but_build_requires_clean_exact_commit(self):
        self.write("Sources/TilveroApp/Screen.swift", b"// changed\n")
        candidate, receipt = self.prepare()
        boundary = Boundary(self)
        with self.assertRaises(self.module.LocalBuildError):
            self.module.build_and_sign(self.root, candidate, receipt, IDENTITY, boundary)
        self.assertEqual(boundary.calls, [])

    def test_invalid_team_commit_paths_existing_outputs_and_symlinks_rejected(self):
        for team in ("", "abcDEFGHIJ", "123", 'ABCDE\"FGHI'):
            with self.subTest(team=team), self.assertRaises(self.module.LocalBuildError):
                self.module.prepare(self.root, self.commit, team)
        with self.assertRaises(self.module.LocalBuildError):
            self.module.prepare(self.root, "0" * 40, TEAM)
        for path in (self.root / "outside", self.root / "local-lab/.staging.noindex/other", self.root / "local-lab/.staging.noindex/signed-local-one/nested"):
            with self.subTest(path=path), self.assertRaises(self.module.LocalBuildError):
                self.prepare(path)
        candidate, _ = self.prepare()
        with self.assertRaises((self.module.LocalBuildError, FileExistsError)):
            self.prepare(candidate)
        staging = self.root / "local-lab/.staging.noindex"
        external = Path(self.temporary.name) / "external"
        external.mkdir()
        (staging / "signed-local-link").symlink_to(external, target_is_directory=True)
        with self.assertRaises(self.module.LocalBuildError):
            self.prepare(staging / "signed-local-link")
        (self.root / "Sources/link").symlink_to(external, target_is_directory=True)
        with self.assertRaises(self.module.LocalBuildError):
            self.prepare()

    def test_source_or_prepared_metadata_drift_aborts_before_any_external_effect(self):
        for mutation in ("source", "metadata", "receipt", "new-source", "project"):
            candidate, receipt = self.prepare()
            target = {"source": self.root / "Package.swift", "metadata": candidate / "HelperInfo.plist",
                "receipt": candidate / self.module.RECEIPT, "new-source": self.root / "Sources/new.swift",
                "project": self.root / "Tilvero.xcodeproj/project.pbxproj"}[mutation]
            original = target.read_bytes() if target.exists() else None
            target.write_bytes(b"changed")
            boundary = Boundary(self)
            with self.subTest(mutation=mutation), self.assertRaises(self.module.LocalBuildError):
                self.module.build_and_sign(self.root, candidate, receipt, IDENTITY, boundary)
            self.assertEqual(boundary.calls, [])
            target.unlink() if original is None else target.write_bytes(original)
        candidate, receipt = self.prepare()
        target = candidate / self.module.RECEIPT
        external_receipt = Path(self.temporary.name) / "receipt-copy.json"
        external_receipt.write_bytes(target.read_bytes())
        target.unlink()
        target.symlink_to(external_receipt)
        boundary = Boundary(self)
        with self.assertRaises(self.module.LocalBuildError):
            self.module.build_and_sign(self.root, candidate, receipt, IDENTITY, boundary)
        self.assertEqual(boundary.calls, [])

    def test_build_sign_exact_trust_and_pinned_nested_order_without_installation(self):
        candidate, receipt = self.prepare()
        boundary = Boundary(self)
        app = self.module.build_and_sign(self.root, candidate, receipt, IDENTITY, boundary)
        signed = json.loads((candidate / self.module.SIGNED_RECEIPT).read_text())
        self.assertEqual(signed["build"], "completed")
        self.assertEqual(signed["signing"], "exact Apple-anchor/Team/identifier requirements verified")
        for key in ("installation", "launch", "registration", "physicalQualification"):
            self.assertEqual(signed[key], "not performed")
        build = next(args for args in boundary.calls if args[0] == "bash")
        self.assertEqual(build[1], str(self.root / "scripts/build-xcode.sh"))
        self.assertEqual(build[build.index("--app-info") + 1], str(candidate / "AppInfo.plist"))
        self.assertEqual(build[build.index("--helper-info") + 1], str(candidate / "HelperInfo.plist"))
        requirements = [args[args.index("-R") + 1] for args in boundary.calls if "-R" in args]
        self.assertEqual(set(requirements), {self.module.requirement(TEAM, self.module.APP_ID), self.module.requirement(TEAM, self.module.HELPER_ID)})
        targets = [Path(args[-1]) for args in boundary.calls if "--sign" in args]
        framework = app / "Contents/Frameworks/Sparkle.framework"
        self.assertLess(targets.index(framework / "Versions/B/Autoupdate"), targets.index(framework))
        self.assertLess(targets.index(framework / "Versions/B/Updater.app"), targets.index(framework))
        self.assertEqual(targets[-1], app)
        self.assertTrue(all("--timestamp=none" in args for args in boundary.calls if "--sign" in args))
        self.assertFalse(any(args[0] in {"open", "launchctl", "sudo", "osascript", "sfltool"} for args in boundary.calls))

    def test_identity_embedded_metadata_payload_and_verification_fail_closed(self):
        for option in ("bad_identity", "wrong_team", "missing_embedded", "wrong_embedded", "changed_source", "changed_resource", "changed_code", "bad_pin", "bad_verify"):
            candidate, receipt = self.prepare()
            boundary = Boundary(self, option)
            with self.subTest(option=option), self.assertRaises((self.module.LocalBuildError, subprocess.CalledProcessError)):
                self.module.build_and_sign(self.root, candidate, receipt, "-" if option == "bad_identity" else IDENTITY, boundary)
            self.assertFalse((candidate / self.module.SIGNED_RECEIPT).exists())
            if option in {"missing_embedded", "wrong_embedded", "changed_source", "bad_pin"}:
                self.assertFalse(any("--sign" in args for args in boundary.calls))
            if option == "changed_source":
                self.write("Package.swift", b"fixture input\n")

    def test_generator_default_keeps_helper_embedded_info_and_allows_override(self):
        subprocess.run([sys.executable, str(self.root / "scripts/generate-xcode-project.py")], check=True, capture_output=True)
        project = subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(self.root / "Tilvero.xcodeproj/project.pbxproj")])
        objects = json.loads(project)["objects"]
        target = next(value for value in objects.values() if value.get("isa") == "PBXNativeTarget" and value.get("name") == "TilveroHelper")
        rows = objects[target["buildConfigurationList"]]["buildConfigurations"]
        for row in rows:
            settings = objects[row]["buildSettings"]
            self.assertEqual(settings["CREATE_INFOPLIST_SECTION_IN_BINARY"], "YES")
            self.assertEqual(settings["INFOPLIST_FILE"], "$(TILVERO_HELPER_INFO_PLIST)")
            self.assertEqual(settings["TILVERO_HELPER_INFO_PLIST"], "Config/HelperInfo.plist")

    def test_xcode_wrapper_forwards_prepared_metadata_and_rejects_release_conflicts(self):
        candidate, _ = self.prepare()
        tools = Path(self.temporary.name) / "tools"
        tools.mkdir()
        tool = tools / "xcodebuild"
        tool.write_text("#!" + sys.executable + "\nimport json,sys,pathlib\npathlib.Path('invocation.json').write_text(json.dumps(sys.argv[1:]))\n")
        tool.chmod(0o755)
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"])
        arguments = ["bash", str(self.root / "scripts/build-xcode.sh"), "--derived-data", str(candidate / "DerivedData"),
            "--app-info", str(candidate / "AppInfo.plist"), "--helper-info", str(candidate / "HelperInfo.plist")]
        result = subprocess.run(arguments, cwd=self.root, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        invocation = json.loads((self.root / "invocation.json").read_text())
        self.assertIn("TILVERO_HELPER_INFO_PLIST=" + str(candidate / "HelperInfo.plist"), invocation)
        built_info = plistlib.loads((candidate / "DerivedData/UpdaterInfo.plist").read_bytes())
        self.assertEqual(built_info["TilveroTeamIdentifier"], TEAM)
        self.assertFalse(built_info["TilveroUpdaterConfiguration"]["enabled"])
        (self.root / "invocation.json").unlink()
        result = subprocess.run(arguments + ["--release-config", "unreadable"], cwd=self.root, env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "invocation.json").exists())
        # The wrapper's established default path still uses only the default app input.
        result = subprocess.run(["bash", str(self.root / "scripts/build-xcode.sh"), "--derived-data", str(candidate / "DefaultDerivedData")], cwd=self.root, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        default_invocation = json.loads((self.root / "invocation.json").read_text())
        self.assertFalse(any(argument.startswith("TILVERO_HELPER_INFO_PLIST=") for argument in default_invocation))
        default_info = plistlib.loads((candidate / "DefaultDerivedData/UpdaterInfo.plist").read_bytes())
        self.assertEqual(default_info["CFBundleIdentifier"], self.module.APP_ID)
        self.assertNotIn("TilveroTeamIdentifier", default_info)


class Boundary:
    def __init__(self, test, option=None):
        self.test, self.option, self.calls = test, option, []
        self.app = None

    def __call__(self, arguments, *, cwd=None, data=None):
        self.calls.append(arguments)
        if arguments[0] == "/usr/bin/security":
            if "find-identity" in arguments:
                return ('  1) ' + IDENTITY + ' "Fixture Apple Development"\n').encode()
            return b"-----BEGIN CERTIFICATE-----fixture-----END CERTIFICATE-----"
        if arguments[0] == "/usr/bin/openssl":
            team = "WRONGTEAM1" if self.option == "wrong_team" else TEAM
            return ('subject= CN=Fixture,OU=' + team + '\nsha1 Fingerprint=' + ':'.join(["AA"] * 20) + '\n').encode()
        if arguments[0] == "bash":
            self.app = Path(arguments[arguments.index("--output") + 1])
            app_info = Path(arguments[arguments.index("--app-info") + 1]).read_bytes()
            info = plistlib.loads(Path(arguments[arguments.index("--helper-info") + 1]).read_bytes())
            if self.option == "wrong_embedded":
                info["TilveroTeamIdentifier"] = "WRONGTEAM1"
            files = {"Contents/Info.plist": app_info, "Contents/MacOS/TilveroApp": macho(),
                "Contents/Library/HelperTools/TilveroHelper": macho(None if self.option == "missing_embedded" else info),
                "Contents/Library/HelperTools/TilveroLidHelper": macho(),
                "Contents/Resources/resource": b"original resource"}
            for name, data in files.items():
                path = self.app / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            framework = self.app / "Contents/Frameworks/Sparkle.framework"
            for name, content in self.test.sparkle.items():
                path = framework / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
            (framework / "Versions/Current").symlink_to("B", target_is_directory=True)
            (framework / "Sparkle").symlink_to("Versions/Current/Sparkle")
            if self.option == "bad_pin":
                (framework / "Versions/B/Sparkle").write_bytes(macho() + b"wrong")
            if self.option == "changed_source":
                (self.test.root / "Package.swift").write_bytes(b"changed")
            return b""
        if arguments[0] == "/usr/bin/codesign":
            if "--sign" in arguments and self.option in {"changed_resource", "changed_code"}:
                path = self.app / ("Contents/Resources/resource" if self.option == "changed_resource" else "Contents/MacOS/TilveroApp")
                path.write_bytes(path.read_bytes() + b"tampered")
            if "--verify" in arguments and self.option == "bad_verify":
                raise subprocess.CalledProcessError(1, arguments)
            return b""
        raise AssertionError("Unexpected external action: " + repr(arguments))


if __name__ == "__main__":
    unittest.main()
