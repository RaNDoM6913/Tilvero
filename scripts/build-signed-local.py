#!/usr/bin/env python3
"""Prepare a same-checkout Apple-signed local candidate without using a key.

Only --build-sign invokes Xcode and the explicitly selected signing identity.
Never installs, launches, registers, requests approval or changes hardware.
Local development signing does not qualify distribution, updates or controls.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import tempfile


def sibling(name):
    spec = importlib.util.spec_from_file_location("signed_local_" + name.replace("-", "_"), Path(__file__).with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


updater_package = sibling("updater_package")
lid_builder = sibling("build-lid-trial")
APP_ID = "local.tilvero.prototype"
HELPER_ID = "local.tilvero.prototype.helper"
APP_NAME = "Tilvero.app"
RECEIPT = "signed-local-preparation.json"
SIGNED_RECEIPT = "signed-local-verification.json"
SOURCE_TREES = ("Sources", "Helper", "scripts", "Config", "Assets", "Tilvero.xcodeproj")
ROOT_INPUTS = ("Package.swift", "Package.resolved", "LICENSE", "COPYRIGHT", "THIRD_PARTY_NOTICES.md", ".gitignore")
REQUIRED = {"Package.swift", "Package.resolved", "Config/Info.plist", "Config/HelperInfo.plist",
    "Config/Updater.json", "Config/Sparkle-2.10.1.inventory.json", "Config/LaunchDaemons/local.tilvero.helper.plist",
    "Sources/PowerPrivileged/HelperTrust.swift", "Sources/TilveroApp/ReleaseIdentity.swift",
    "Helper/TilveroHelperMain.swift", "scripts/build-signed-local.py",
    "scripts/build-xcode.sh", "scripts/generate-xcode-project.py", "scripts/toolchain.sh",
    "scripts/updater_package.py", "scripts/build-lid-trial.py", "Tilvero.xcodeproj/project.pbxproj"}


class LocalBuildError(ValueError):
    pass


def command(arguments, *, cwd=None, data=None):
    return subprocess.run(arguments, cwd=cwd, input=data, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def sha(data):
    return hashlib.sha256(data).hexdigest()


def no_symlinks(path):
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if current.is_symlink():
            raise LocalBuildError("Paths must not traverse symlinks: " + str(current))


def checkout(root, commit, clean=False):
    root = Path(os.path.abspath(root))
    no_symlinks(root)
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise LocalBuildError("Supply the exact full lowercase HEAD commit")
    def git(*args):
        return command(["git", "-C", str(root), *args]).decode().strip()
    if git("rev-parse", "--show-toplevel") != str(root) or git("rev-parse", "HEAD") != commit:
        raise LocalBuildError("Use the canonical checkout and its exact current HEAD commit")
    if clean and git("status", "--porcelain=v1", "--untracked-files=all"):
        raise LocalBuildError("Actual build/sign requires clean committed exact HEAD; commit stable source and prepare again")
    return root


def source_inventory(root):
    """Bind all compilation/configuration/packaging/project inputs, including new files."""
    result = {}
    paths = [root / name for name in ROOT_INPUTS if (root / name).exists()]
    for name in SOURCE_TREES:
        tree = root / name
        no_symlinks(tree)
        if tree.exists():
            paths.extend(tree.rglob("*"))
    for path in sorted(paths):
        relative = path.relative_to(root)
        if "__pycache__" in relative.parts or "xcuserdata" in relative.parts or path.suffix == ".pyc":
            continue
        if path.is_symlink():
            raise LocalBuildError("Source input must not be a symlink: " + str(relative))
        if path.is_file():
            if path.stat().st_nlink != 1:
                raise LocalBuildError("Source input must not be hardlinked: " + str(relative))
            result[str(relative)] = {"sha256": sha(path.read_bytes()), "mode": path.stat().st_mode & 0o777}
        elif not path.is_dir():
            raise LocalBuildError("Nonregular source input: " + str(relative))
    if not REQUIRED <= result.keys():
        raise LocalBuildError("Required source/configuration/helper/project inputs are missing")
    return result


def reserve(root, output):
    staging = root / "local-lab/.staging.noindex"
    no_symlinks(staging)
    ignored = command(["git", "-C", str(root), "check-ignore", "local-lab/.staging.noindex/signed-local-candidate"])
    if not ignored.strip():
        raise LocalBuildError("Candidate staging must be ignored by Git")
    path = None
    if output is not None:
        path = Path(os.path.abspath(root / output))
        try:
            relative = path.relative_to(staging)
        except ValueError as error:
            raise LocalBuildError("Output must be inside local-lab/.staging.noindex") from error
        if len(relative.parts) != 1 or not path.name.startswith("signed-local-"):
            raise LocalBuildError("Use one fresh signed-local-* staging directory")
        no_symlinks(path)
        if path.exists():
            raise LocalBuildError("Preserve the existing candidate output")
    staging.mkdir(parents=True, exist_ok=True)
    if path is None:
        return Path(tempfile.mkdtemp(prefix="signed-local-", dir=staging))
    path.mkdir()
    return path


def write_json(path, value):
    with path.open("x") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")


def trust_metadata(team):
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise LocalBuildError("Supply the actual ten-character uppercase alphanumeric Team ID")
    return dict(TilveroTeamIdentifier=team, TilveroAppIdentifier=APP_ID, TilveroHelperIdentifier=HELPER_ID)


def prepare(root, commit, team_id, output=None):
    trust = trust_metadata(team_id)
    root = checkout(root, commit)
    inputs = source_inventory(root)
    plists = {}
    for source, name, identifier in (("Config/Info.plist", "AppInfo.plist", APP_ID),
                                     ("Config/HelperInfo.plist", "HelperInfo.plist", HELPER_ID)):
        info = plistlib.loads((root / source).read_bytes())
        if info.get("CFBundleIdentifier") != identifier or any(key.startswith("TilveroLid") for key in info):
            raise LocalBuildError("Ordinary prototype metadata required; lid-trial identity/authority is forbidden")
        info.update(trust)
        if name == "AppInfo.plist":
            if "TilveroReleaseMode" in info:
                raise LocalBuildError("Signed-local preparation must not adopt a release profile")
            # ReleaseIdentity admits this exact ID only with nil/"prototype".
            # Keep the existing Tilvero/History.sqlite and prototype preferences.
            if info.get("TilveroDataScope") not in (None, "prototype"):
                raise LocalBuildError("Prototype app metadata must retain its admitted prototype data scope")
            info["TilveroDataScope"] = "prototype"
        plists[name] = plistlib.dumps(info)
    daemon = plistlib.loads((root / "Config/LaunchDaemons/local.tilvero.helper.plist").read_bytes())
    if daemon.get("MachServices") != {HELPER_ID: True} or daemon.get("BundleProgram") != "Contents/Library/HelperTools/TilveroHelper":
        raise LocalBuildError("Ordinary helper Mach service or executable identity drifted")
    candidate = reserve(root, output)
    for name, data in plists.items():
        with (candidate / name).open("xb") as stream:
            stream.write(data)
    if source_inventory(root) != inputs:
        raise LocalBuildError("Source changed during preparation; preserve failed candidate and prepare again")
    checkout(root, commit)
    receipt = dict(schemaVersion=1, artifactType="prepared-signed-local", createdAt=datetime.now(timezone.utc).isoformat(),
        sourceRoot=str(root), commit=commit, sourceInputs=inputs, trustedMetadata=trust,
        preparedInfo={name: sha(data) for name, data in plists.items()}, dataScope="prototype",
        build="not performed", signing="not performed", installation="not performed", launch="not performed",
        registration="not performed", physicalQualification="not performed", distribution="not qualified")
    write_json(candidate / RECEIPT, receipt)
    return candidate, receipt


def verify_identity(identity, team, run=command):
    try:
        lid_builder.verify_identity(identity, team, run)
    except lid_builder.TrialError as error:
        raise LocalBuildError(str(error)) from error


def requirement(team, identifier):
    return 'anchor apple generic and identifier "' + identifier + '" and certificate leaf[subject.OU] = "' + team + '"'


def verify_prepared(root, candidate, receipt, clean=False):
    if receipt.get("sourceRoot") != str(root):
        raise LocalBuildError("Candidate is bound to another canonical source checkout")
    expected_parent = root / "local-lab/.staging.noindex"
    if candidate.parent != expected_parent or not candidate.name.startswith("signed-local-"):
        raise LocalBuildError("Candidate must remain in its original ignored staging directory")
    no_symlinks(candidate)
    receipt_path = candidate / RECEIPT
    no_symlinks(receipt_path)
    if not receipt_path.is_file() or receipt_path.stat().st_nlink != 1:
        raise LocalBuildError("Preparation receipt must remain a regular unlinked file")
    try:
        saved = json.loads(receipt_path.read_text())
    except (ValueError, OSError) as error:
        raise LocalBuildError("Missing/invalid preparation receipt") from error
    if saved != receipt or receipt.get("trustedMetadata") != trust_metadata(receipt["trustedMetadata"]["TilveroTeamIdentifier"]):
        raise LocalBuildError("Preparation receipt or exact ordinary trust identity changed")
    if receipt.get("dataScope") != "prototype":
        raise LocalBuildError("Signed-local preparation must retain the prototype runtime data boundary")
    if set(receipt.get("preparedInfo", {})) != {"AppInfo.plist", "HelperInfo.plist"}:
        raise LocalBuildError("Prepared compilation metadata inventory changed")
    for name, digest in receipt["preparedInfo"].items():
        path = candidate / name
        no_symlinks(path)
        if not path.is_file() or path.stat().st_nlink != 1 or sha(path.read_bytes()) != digest:
            raise LocalBuildError("Prepared compilation metadata changed")
    if source_inventory(root) != receipt["sourceInputs"]:
        raise LocalBuildError("Source changed after preparation")
    checkout(root, receipt["commit"], clean=clean)


def embedded_helper_info(path):
    """Read the compiled __TEXT,__info_plist section, never an outer plist."""
    data = path.read_bytes()
    # This native Xcode route compiles one arm64 slice. Fail closed on other formats.
    try:
        if len(data) < 32 or struct.unpack_from("<II", data) != (0xfeedfacf, 0x100000c):
            raise LocalBuildError("Expected a thin arm64 helper Mach-O")
        count, length = struct.unpack_from("<II", data, 16)
        position, end, found = 32, 32 + length, []
        if end > len(data):
            raise LocalBuildError("Invalid helper load-command bounds")
        for _ in range(count):
            kind, size = struct.unpack_from("<II", data, position)
            if size < 8 or position + size > end:
                raise LocalBuildError("Invalid helper load command")
            if kind == 0x19:
                if size < 72:
                    raise LocalBuildError("Invalid helper segment")
                sections = struct.unpack_from("<I", data, position + 64)[0]
                if 72 + sections * 80 > size:
                    raise LocalBuildError("Invalid helper section count")
                for index in range(sections):
                    offset = position + 72 + index * 80
                    section, segment = struct.unpack_from("<16s16s", data, offset)
                    if section.rstrip(b"\0") == b"__info_plist" and segment.rstrip(b"\0") == b"__TEXT":
                        length = struct.unpack_from("<Q", data, offset + 40)[0]
                        start = struct.unpack_from("<I", data, offset + 48)[0]
                        if not length or start < end or start + length > len(data):
                            raise LocalBuildError("Invalid embedded helper metadata bounds")
                        found.append(plistlib.loads(data[start:start + length].rstrip(b"\0")))
            position += size
        if position != end or len(found) != 1:
            raise LocalBuildError("Expected exactly one embedded helper Info.plist")
        return found[0]
    except (struct.error, ValueError, plistlib.InvalidFileException) as error:
        raise LocalBuildError("Invalid embedded helper Info.plist") from error


def validate_framework(root, framework):
    inventory = json.loads((root / "Config/Sparkle-2.10.1.inventory.json").read_text())
    if inventory.get("version") != "2.10.1" or framework.is_symlink() or not framework.is_dir():
        raise LocalBuildError("Exact pinned Sparkle 2.10.1 framework required")
    actual = {str(path.relative_to(framework)): path for path in framework.rglob("*") if path.is_symlink() or not path.is_dir()}
    if set(actual) - (inventory["files"].keys() | inventory["symlinks"].keys()):
        raise LocalBuildError("Unexpected Sparkle payload")
    optional = ("Headers", "PrivateHeaders", "Modules", "Versions/B/Headers/", "Versions/B/PrivateHeaders/", "Versions/B/Modules/")
    for name, target in inventory["symlinks"].items():
        path = actual.get(name)
        if path is None and name.startswith(optional):
            continue
        if path is None or not path.is_symlink() or os.readlink(path) != target or not path.resolve().is_relative_to(framework.resolve()):
            raise LocalBuildError("Unexpected or escaping Sparkle symlink: " + name)
    for name, expected in inventory["files"].items():
        path = actual.get(name)
        if path is None and name.startswith(optional):
            continue
        if path is None or path.is_symlink() or not path.is_file() or path.stat().st_nlink != 1:
            raise LocalBuildError("Missing/nonregular pinned Sparkle file: " + name)
        if expected["kind"] != "signature":
            digest = updater_package.code_payload_digest(path) if expected["kind"] == "code" else sha(path.read_bytes())
            if digest != expected["sha256"]:
                raise LocalBuildError("Pinned Sparkle payload changed: " + name)
    return inventory


def bundle_inventory(app, code_paths, signature_paths):
    result = {}
    framework = app / "Contents/Frameworks/Sparkle.framework"
    if app.is_symlink() or not app.is_dir():
        raise LocalBuildError("Expected a regular candidate app")
    for path in sorted(app.rglob("*")):
        name = str(path.relative_to(app))
        if path.is_symlink():
            if not path.is_relative_to(framework):
                raise LocalBuildError("Unexpected bundle symlink")
            result[name] = "symlink:" + os.readlink(path)
        elif path.is_file():
            if path.stat().st_nlink != 1:
                raise LocalBuildError("Hardlinked bundle payload rejected")
            if name in signature_paths:
                continue
            magic = path.read_bytes()[:4]
            if name in code_paths:
                result[name] = updater_package.code_payload_digest(path)
            elif magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf", b"\xbe\xba\xfe\xca"):
                raise LocalBuildError("Unexpected executable payload: " + name)
            else:
                result[name] = sha(path.read_bytes())
        elif not path.is_dir():
            raise LocalBuildError("Nonregular bundle payload")
    if not code_paths <= result.keys():
        raise LocalBuildError("Required executable payload is missing")
    return result


def build_and_sign(root, candidate, receipt, identity, run=command):
    """Explicit future owner action; injected runner is used only by disposable tests."""
    root, candidate = Path(os.path.abspath(root)), Path(os.path.abspath(candidate))
    verify_prepared(root, candidate, receipt, clean=True)
    if not re.fullmatch(r"[A-Fa-f0-9]{40}", identity or ""):
        raise LocalBuildError("An explicit certificate SHA-1 is required; ad-hoc signing is forbidden")
    app, derived = candidate / APP_NAME, candidate / "DerivedData"
    if any(path.exists() or path.is_symlink() for path in (app, derived, candidate / SIGNED_RECEIPT)):
        raise LocalBuildError("Build/sign requires a fresh candidate; preserve existing outputs")
    team = receipt["trustedMetadata"]["TilveroTeamIdentifier"]
    verify_identity(identity, team, run)
    verify_prepared(root, candidate, receipt, clean=True)
    run(["bash", str(root / "scripts/build-xcode.sh"), "--configuration", "Release", "--derived-data", str(derived),
         "--output", str(app), "--app-info", str(candidate / "AppInfo.plist"), "--helper-info", str(candidate / "HelperInfo.plist")], cwd=root)
    verify_prepared(root, candidate, receipt, clean=True)
    helper = app / "Contents/Library/HelperTools/TilveroHelper"
    # Reject bundle links before opening any packaged path.
    no_symlinks(app / "Contents/Info.plist")
    no_symlinks(helper)
    expected_app = dict(receipt["trustedMetadata"], CFBundleIdentifier=APP_ID, TilveroDataScope="prototype")
    for info, expected in ((plistlib.loads((app / "Contents/Info.plist").read_bytes()), expected_app),
                           (embedded_helper_info(helper), dict(receipt["trustedMetadata"], CFBundleIdentifier=HELPER_ID))):
        if any(info.get(key) != value for key, value in expected.items()) or any(key.startswith("TilveroLid") for key in info):
            raise LocalBuildError("Compiled app/embedded helper identity or trust metadata differs")
    framework = app / "Contents/Frameworks/Sparkle.framework"
    pin = validate_framework(root, framework)
    code_paths = {"Contents/MacOS/TilveroApp", "Contents/Library/HelperTools/TilveroHelper", "Contents/Library/HelperTools/TilveroLidHelper"}
    prefix = "Contents/Frameworks/Sparkle.framework/"
    code_paths |= {prefix + name for name, entry in pin["files"].items() if entry["kind"] == "code"}
    signature_paths = {prefix + name for name, entry in pin["files"].items() if entry["kind"] == "signature"}
    nested = sorted([path for path in framework.rglob("*") if not path.is_symlink() and path.suffix in (".xpc", ".app")], key=lambda path: (-len(path.parts), str(path)))
    targets = [framework / "Versions/B/Autoupdate"] + nested + [framework, app / "Contents/Library/HelperTools/TilveroLidHelper", helper, app]
    for target in targets:
        if target.is_dir():
            envelope = target / ("Versions/B/_CodeSignature/CodeResources" if target == framework else "Contents/_CodeSignature/CodeResources")
            signature_paths.add(str(envelope.relative_to(app)))
    before = bundle_inventory(app, code_paths, signature_paths)
    for target in targets:
        arguments = ["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp=none", "--sign", identity]
        if target in (app, helper):
            arguments += ["--identifier", APP_ID if target == app else HELPER_ID]
        run(arguments + [str(target)])
        verify = ["/usr/bin/codesign", "--verify", "--strict"]
        if target in (app, helper):
            verify += ["-R", "=" + requirement(team, APP_ID if target == app else HELPER_ID)]
        run(verify + [str(target)])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    validate_framework(root, framework)
    after = bundle_inventory(app, code_paths, signature_paths)
    if before != after:
        raise LocalBuildError("Unexpected payload mutation during signing")
    verify_prepared(root, candidate, receipt, clean=True)
    signed = dict(receipt, artifactType="verified-signed-local", appPath=str(app), build="completed",
        signing="exact Apple-anchor/Team/identifier requirements verified", certificateSHA1=identity.upper(),
        packagedPayload=after, verification="deep strict integrity verified", notarization="not performed")
    write_json(candidate / SIGNED_RECEIPT, signed)
    return app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--commit", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--build-sign", action="store_true")
    parser.add_argument("--identity", help="Explicit existing certificate SHA-1; only with --build-sign")
    args = parser.parse_args()
    if bool(args.identity) != args.build_sign:
        parser.error("--identity is required only for explicit --build-sign; preparation never accesses the keychain")
    try:
        if args.build_sign:
            checkout(args.root, args.commit, clean=True)
            if not re.fullmatch(r"[A-Fa-f0-9]{40}", args.identity):
                raise LocalBuildError("An explicit certificate SHA-1 is required")
        candidate, receipt = prepare(args.root, args.commit, args.team_id, args.output)
        if args.build_sign:
            build_and_sign(args.root, candidate, receipt, args.identity)
        print(candidate)
    except (LocalBuildError, updater_package.UpdaterError, OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, "Signed-local preparation rejected: " + str(error) + "\n")


if __name__ == "__main__":
    main()
