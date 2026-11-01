"""Exercise local packaging with disposable Swift/signing tool boundaries."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class LaboratoryBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "project"
        self.root.mkdir()
        for name in ("scripts/build-local-app.sh", "scripts/build-lab-app.sh",
                     "scripts/local_app_package.py", "scripts/toolchain.sh"):
            source = ROOT / name
            if source.exists():
                destination = self.root / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)
        self.write("Config/Info.plist", plistlib.dumps({
            "CFBundleName": "Tilvero", "CFBundleDisplayName": "Tilvero",
            "CFBundleExecutable": "TilveroApp", "CFBundleIdentifier": "local.tilvero.prototype",
            "CFBundleIconFile": "AppIcon", "CFBundlePackageType": "APPL",
        }))
        for name, content in {
            "Package.swift": b"// disposable package fixture\n",
            "Sources/TilveroApp/Screen.swift": b"// common production screen\n",
            "Sources/TilveroApp/Resources/Localizable.xcstrings": b"localized content",
            "Helper/main.swift": b"// common helper\n",
            "Config/LaunchDaemons/local.tilvero.helper.plist": b"helper launch metadata",
            "Assets/AppIcon.icns": b"production icon",
            "local-lab/demos/native-time-picker-20261031/Resources/LabIcon.icns": b"dark icon",
            "LICENSE": b"license", "COPYRIGHT": b"copyright",
            "THIRD_PARTY_NOTICES.md": b"notices", "Helper/THIRD_PARTY_NOTICES.md": b"helper notices",
        }.items():
            self.write(name, content)
        self.tools = Path(self.temporary.name) / "tools"
        self.tools.mkdir()
        self.tool("swift", '''import os, pathlib, sys
root = pathlib.Path.cwd()
with (root / 'swift-invoked').open('a') as stream:
    stream.write(' '.join(sys.argv[1:]) + '\\n')
arguments = sys.argv[1:]
binary = root / '.build/fake-release'
if arguments == ['build', '-c', 'release', '--show-bin-path']:
    print(binary)
elif arguments in (['build', '-c', 'release', '--product', 'TilveroApp'],
                    ['build', '-c', 'release', '--product', 'TilveroHelper']):
    binary.mkdir(parents=True, exist_ok=True)
    product = arguments[-1]
    (binary / product).write_bytes(('common-' + product).encode())
    resources = binary / 'Tilvero_TilveroApp.bundle'
    resources.mkdir(exist_ok=True)
    (resources / 'BatteryAssembly.png').write_bytes(b'common production artwork')
    if os.environ.get('MUTATE_SOURCE_INPUT'):
        (root / 'Sources/TilveroApp/Screen.swift').write_text('// changed during compilation')
else:
    raise SystemExit('Unexpected Swift invocation: ' + repr(arguments))
''')
        self.tool("codesign", '''import os, pathlib, sys
arguments = sys.argv[1:]
if '--sign' in arguments:
    path = pathlib.Path(arguments[-1])
    executable = path / 'Contents/MacOS/TilveroApp' if path.is_dir() else path
    executable.write_bytes(executable.read_bytes() + b'-signed')
    if path.is_dir() and os.environ.get('TAMPER_RESOURCE'):
        (path / 'Contents/Resources/Localizable.xcstrings').write_bytes(b'tampered')
''')
        self.tool("plutil", "")
        self.tool("ditto", '''import pathlib, shutil, sys
source, destination = map(pathlib.Path, sys.argv[1:])
shutil.copytree(source, destination)
''')

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)

    def tool(self, name, body):
        path = self.tools / name
        path.write_text("#!" + sys.executable + "\n" + body)
        path.chmod(0o755)

    def build(self, *arguments, environment=None):
        env = dict(os.environ, PATH=str(self.tools) + os.pathsep + os.environ["PATH"])
        env.update(environment or {})
        return subprocess.run(["bash", str(self.root / "scripts/build-local-app.sh"), *arguments],
                              cwd=self.root, env=env, capture_output=True, text=True, timeout=30)

    def test_lab_output_cannot_escape_staging_or_touch_canonical_bundle(self):
        canonical = self.root / "local-lab/builds/Tilvero Lab.app"
        for output in (canonical, self.root / "local-lab/.staging.noindex/../../escaped/Tilvero Lab.app"):
            with self.subTest(output=output):
                result = self.build("--laboratory", "--output", str(output))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("staging", result.stderr.lower())
                self.assertFalse(output.exists())
        self.assertFalse((self.root / "swift-invoked").exists())

    def test_symlinked_staging_ancestor_is_rejected_before_compilation(self):
        staging = self.root / "local-lab/.staging.noindex"
        staging.mkdir(parents=True)
        target = self.root / "local-lab/builds"
        target.mkdir()
        (staging / "alias").symlink_to(target, target_is_directory=True)
        result = self.build("--laboratory", "--output", str(staging / "alias/Tilvero Lab.app"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlink", result.stderr.lower())
        self.assertFalse((target / "Tilvero Lab.app").exists())
        self.assertFalse((self.root / "swift-invoked").exists())

    def test_existing_lab_candidate_is_preserved_without_compilation(self):
        output = self.root / "local-lab/.staging.noindex/previous/Tilvero Lab.app"
        output.mkdir(parents=True)
        (output / "preserve").write_text("original")
        result = self.build("--laboratory", "--output", str(output))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists", result.stderr.lower())
        self.assertEqual((output / "preserve").read_text(), "original")
        self.assertFalse((self.root / "swift-invoked").exists())

    def test_lab_packages_common_binary_and_resources_with_isolated_identity_receipt(self):
        original_info = (self.root / "Config/Info.plist").read_bytes()
        result = self.build("--laboratory")
        self.assertEqual(result.returncode, 0, result.stderr)
        candidates = list((self.root / "local-lab/.staging.noindex").glob("*/Tilvero Lab.app"))
        self.assertEqual(len(candidates), 1)
        app = candidates[0]
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "local.tilvero.lab")
        self.assertEqual(info["TilveroDataScope"], "laboratory")
        self.assertEqual(info["CFBundleExecutable"], "TilveroApp")
        self.assertEqual(info["CFBundleDisplayName"], "Tilvero Lab")
        self.assertEqual(info["CFBundleIconFile"], "LabIcon")
        self.assertNotIn("TilveroReleaseMode", info)
        self.assertEqual((self.root / "Config/Info.plist").read_bytes(), original_info)
        self.assertEqual((app / "Contents/Resources/LabIcon.icns").read_bytes(), b"dark icon")
        self.assertEqual((app / "Contents/Resources/Tilvero_TilveroApp.bundle/BatteryAssembly.png").read_bytes(),
                         b"common production artwork")
        receipt = json.loads((app.parent / "build-receipt.json").read_text())
        self.assertEqual(receipt["artifactType"], "local-laboratory-candidate")
        executable = receipt["copiedInputs"]["Contents/MacOS/TilveroApp"]
        self.assertEqual(executable["sha256"], hashlib.sha256(b"common-TilveroApp").hexdigest())
        self.assertEqual(receipt["packagedFiles"]["Contents/MacOS/TilveroApp"],
                         hashlib.sha256(b"common-TilveroApp-signed").hexdigest())
        self.assertIn("Sources/TilveroApp/Screen.swift", receipt["sourceInputs"])
        self.assertIn("Contents/Resources/Tilvero_TilveroApp.bundle/BatteryAssembly.png", receipt["copiedInputs"])
        self.assertFalse((self.root / "build/Tilvero.app").exists())

    def test_changed_source_during_compilation_cannot_get_success_receipt(self):
        result = self.build("--laboratory", environment={"MUTATE_SOURCE_INPUT": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source inputs changed", result.stderr.lower())
        self.assertEqual(list((self.root / "local-lab/.staging.noindex").rglob("build-receipt.json")), [])

    def test_post_copy_resource_change_cannot_get_success_receipt(self):
        result = self.build("--laboratory", environment={"TAMPER_RESOURCE": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("packaged resource changed", result.stderr.lower())
        self.assertEqual(list((self.root / "local-lab/.staging.noindex").rglob("build-receipt.json")), [])

    def test_default_development_build_keeps_existing_identity_and_resources(self):
        original_info = (self.root / "Config/Info.plist").read_bytes()
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        app = self.root / "build/Tilvero.app"
        self.assertEqual((app / "Contents/Info.plist").read_bytes(), original_info)
        self.assertEqual((app / "Contents/Resources/AppIcon.icns").read_bytes(), b"production icon")
        self.assertFalse((app / "Contents/Resources/LabIcon.icns").exists())


if __name__ == "__main__":
    unittest.main()
