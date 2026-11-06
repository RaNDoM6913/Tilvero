#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 RaNDoM6913

"""Prepare a source-bound isolated lid trial; build/sign only with explicit opt-in.

Never installs, launches, registers services or changes power settings. Run from
a clean Git checkout with the exact full HEAD commit. Preparation needs no key.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import subprocess
import tempfile


APP_ID = "local.tilvero.lidtrial"
HELPER_ID = "local.tilvero.lidlab.helper"
APP_NAME = "Tilvero Lid Trial.app"
RECEIPT = "lid-trial-receipt.json"
LID_PLISTS = {"local.tilvero.lidlab.controller.plist", "local.tilvero.lidlab.guardian.plist"}
GENERATED = {".build", ".swiftpm", "build", "local-lab"}
REQUIRED = {"Package.swift", "scripts/build-local-app.sh", "scripts/build-lid-trial.py",
            "Config/Info.plist", "Config/TilveroLidHelper-Info.plist",
            "Sources/TilveroApp/ReleaseIdentity.swift", "Sources/TilveroApp/AppLaunchPolicy.swift",
            "Sources/TilveroApp/ClosedLidService.swift", "Sources/TilveroLidHelper/TilveroLidHelperMain.swift"}


class TrialError(ValueError):
    pass


def command(arguments, *, cwd=None, data=None):
    return subprocess.run(arguments, cwd=cwd, input=data, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def git(root, *arguments):
    return command(["git", "-C", str(root), *arguments])


def sha(data):
    return hashlib.sha256(data).hexdigest()


def clean_commit(root, commit):
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise TrialError("Supply the exact full lowercase HEAD commit")
    if git(root, "rev-parse", "HEAD").decode().strip() != commit:
        raise TrialError("The requested commit must equal checkout HEAD")
    if git(root, "status", "--porcelain=v1", "--untracked-files=all"):
        raise TrialError("A clean committed source checkout is required")


def committed_files(root, commit):
    result = {}
    for record in git(root, "ls-tree", "-rz", "--full-tree", commit).split(b"\0"):
        if not record:
            continue
        header, raw_name = record.split(b"\t", 1)
        mode, kind, blob = header.decode("ascii").split()
        name = raw_name.decode("utf-8")
        parts = PurePosixPath(name).parts
        if (mode not in {"100644", "100755"} or kind != "blob" or not parts
                or name.startswith("/") or ".." in parts or "\\" in name
                or any(ord(char) < 32 for char in name)
                or any(part in GENERATED | {".git", "__pycache__"} or part.startswith(".env") for part in parts)
                or name.endswith((".p12", ".pfx", ".pem", ".key", ".sqlite", ".db"))):
            raise TrialError("Unsafe/private/nonregular committed input: " + name)
        content = git(root, "cat-file", "blob", blob)
        working = root / name
        if working.is_symlink() or not working.is_file() or working.read_bytes() != content:
            raise TrialError("Working input differs from committed regular source: " + name)
        result[name] = (mode, content)
    if not REQUIRED <= result.keys():
        raise TrialError("Committed trial source is incomplete")
    return result


def no_symlinks(root, path):
    current = root
    for part in path.relative_to(root).parts:
        current /= part
        if current.is_symlink():
            raise TrialError("Trial staging must not traverse symlinks")


def reserve(root, output=None):
    staging = root / "local-lab/.staging.noindex"
    no_symlinks(root, staging)
    if command(["git", "-C", str(root), "check-ignore", "local-lab/.staging.noindex/lid-trial-candidate"]).strip() == b"":
        raise TrialError("Trial staging must be ignored by Git")
    if output is not None:
        path = Path(os.path.abspath(root / output))
        try:
            relative = path.relative_to(staging)
        except ValueError as error:
            raise TrialError("Output must be a fresh lid-trial-* folder inside local-lab/.staging.noindex") from error
        if len(relative.parts) != 1 or not path.name.startswith("lid-trial-"):
            raise TrialError("Output must be one fresh lid-trial-* staging folder")
        no_symlinks(root, path)
        staging.mkdir(parents=True, exist_ok=True)
        path.mkdir()  # Exclusive reservation; preserve every existing candidate.
        return path
    staging.mkdir(parents=True, exist_ok=True)
    return Path(tempfile.mkdtemp(prefix="lid-trial-", dir=staging))


def inventory(source):
    result = {}
    for path in source.rglob("*"):
        relative = path.relative_to(source)
        if relative.parts[0] in GENERATED:
            continue
        if path.is_symlink():
            raise TrialError("Prepared source contains a symlink")
        if path.is_file():
            result[str(relative)] = sha(path.read_bytes())
    return result


def write_json(path, value):
    with path.open("x") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")


def prepare(root, commit, team_id, output=None):
    root = Path(root).resolve()
    if not re.fullmatch(r"[A-Z0-9]{10}", team_id):
        raise TrialError("Supply the ten-character signing Team ID")
    clean_commit(root, commit)
    files = committed_files(root, commit)
    candidate = reserve(root, output)
    source = candidate / "Source"
    source.mkdir()
    for name, (mode, content) in files.items():
        path = source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("xb") as stream:
            stream.write(content)
        path.chmod(0o755 if mode == "100755" else 0o644)
    trust = {"TilveroLidTeamIdentifier": team_id, "TilveroLidAppIdentifier": APP_ID,
             "TilveroLidHelperIdentifier": HELPER_ID}
    for name in ("Config/Info.plist", "Config/TilveroLidHelper-Info.plist"):
        path = source / name
        metadata = plistlib.loads(path.read_bytes())
        metadata.update(trust)
        if name == "Config/Info.plist":
            metadata.update(CFBundleIdentifier=APP_ID, CFBundleName="Tilvero Lid Trial",
                            CFBundleDisplayName="Tilvero Lid Trial", TilveroDataScope="lid-trial",
                            TilveroLidTrialHost=True)
            for key in ("TilveroReleaseMode", "TilveroTeamIdentifier", "TilveroAppIdentifier", "TilveroHelperIdentifier"):
                metadata.pop(key, None)
        elif metadata.get("CFBundleIdentifier") != HELPER_ID:
            raise TrialError("Dedicated helper identity drifted")
        path.write_bytes(plistlib.dumps(metadata))
    clean_commit(root, commit)
    receipt = {"schemaVersion": 1, "artifactType": "prepared-isolated-lid-trial",
               "createdAt": datetime.now(timezone.utc).isoformat(), "commit": commit,
               "originalInputs": {name: sha(content) for name, (_, content) in files.items()},
               "preparedInputs": inventory(source), "trustedMetadata": trust,
               "trialMaximumSeconds": 120, "signing": "not performed", "build": "not performed",
               "installation": "not performed", "launch": "not performed", "enrollment": "not performed",
               "physicalQualification": "not performed"}
    write_json(candidate / RECEIPT, receipt)
    return candidate, receipt


def verify_identity(identity, team_id, run=command):
    if not re.fullmatch(r"[A-Fa-f0-9]{40}", identity):
        raise TrialError("An explicit certificate SHA-1 is required; ad-hoc signing is forbidden")
    identities = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"]).decode()
    if not re.search(r'^\s*\d+\)\s+' + re.escape(identity) + r'\s+"', identities, re.MULTILINE | re.IGNORECASE):
        raise TrialError("The exact certificate is not a valid code-signing identity")
    certificates = run(["/usr/bin/security", "find-certificate", "-a", "-p"])
    for certificate in re.findall(b"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", certificates, re.DOTALL):
        details = run(["/usr/bin/openssl", "x509", "-noout", "-subject", "-fingerprint", "-sha1", "-nameopt", "RFC2253"], data=certificate).decode()
        fingerprint = re.search(r"(?im)^sha1 Fingerprint=([0-9A-F:]+)$", details)
        if fingerprint and fingerprint.group(1).replace(":", "").lower() == identity.lower():
            subject = re.search(r"(?m)^subject=\s*(.+)$", details)
            fields = re.split(r"(?<!\\),", subject.group(1)) if subject else []
            if [field.strip()[3:] for field in fields if field.strip().startswith("OU=")] != [team_id]:
                raise TrialError("The selected certificate Team ID does not match")
            return
    raise TrialError("The selected certificate's Team ID could not be verified")


def bundle_inventory(app):
    if app.is_symlink() or not app.is_dir():
        raise TrialError("Expected a regular trial app directory")
    result = {}
    for path in sorted(app.rglob("*")):
        if path.is_symlink() or (path.is_file() and path.stat().st_nlink != 1):
            raise TrialError("Trial bundle must not contain symlinks or hardlinked files")
        if path.is_file():
            result[str(path.relative_to(app))] = sha(path.read_bytes())
    return result


def build_and_sign(root, candidate, receipt, identity, run=command):
    """Explicit owner action only. Injected subprocess boundary supports fixture tests."""
    team = receipt["trustedMetadata"]["TilveroLidTeamIdentifier"]
    verify_identity(identity, team, run)
    source = candidate / "Source"
    if inventory(source) != receipt["preparedInputs"]:
        raise TrialError("Prepared source changed before build")
    app = candidate / APP_NAME
    if app.exists() or app.is_symlink():
        raise TrialError("Preserve the existing trial app")
    run(["bash", str(source / "scripts/build-local-app.sh"), "--output", str(app)], cwd=source)
    if inventory(source) != receipt["preparedInputs"]:
        raise TrialError("Prepared source changed during build")
    clean_commit(root, receipt["commit"])
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = dict(receipt["trustedMetadata"], CFBundleIdentifier=APP_ID, TilveroDataScope="lid-trial", TilveroLidTrialHost=True)
    if any(info.get(key) != value for key, value in expected.items()):
        raise TrialError("Packaged trial identity/trust metadata differs from prepared source")
    bundle_inventory(app)
    # A lid trial cannot enroll the ordinary charge/fan helper, even accidentally.
    ordinary = app / "Contents/Library/HelperTools/TilveroHelper"
    if ordinary.is_symlink():
        raise TrialError("Unexpected symlinked ordinary helper")
    ordinary.unlink(missing_ok=True)
    launch = app / "Contents/Library/LaunchDaemons"
    for path in launch.iterdir():
        if path.is_symlink() or not path.is_file():
            raise TrialError("Unexpected launch resource")
        if path.name not in LID_PLISTS:
            path.unlink()
    if {path.name for path in launch.iterdir()} != LID_PLISTS:
        raise TrialError("Dedicated lid launch resources are incomplete")
    before = bundle_inventory(app)
    helper = app / "Contents/Library/HelperTools/TilveroLidHelper"
    for target, identifier in ((helper, HELPER_ID), (app, APP_ID)):
        run(["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp=none", "--sign", identity,
             "--identifier", identifier, str(target)])
        requirement = 'anchor apple generic and identifier "' + identifier + '" and certificate leaf[subject.OU] = "' + team + '"'
        run(["/usr/bin/codesign", "--verify", "--strict", "-R", requirement, str(target)])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    after = bundle_inventory(app)
    mutable = {"Contents/MacOS/TilveroApp", "Contents/Library/HelperTools/TilveroLidHelper",
               "Contents/_CodeSignature/CodeResources"}
    if any(after.get(name) != digest for name, digest in before.items() if name not in mutable):
        raise TrialError("A packaged resource changed during signing")
    if set(after) - set(before) - {"Contents/_CodeSignature/CodeResources"}:
        raise TrialError("Unexpected packaged files appeared during signing")
    if inventory(source) != receipt["preparedInputs"]:
        raise TrialError("Prepared source changed during signing")
    clean_commit(root, receipt["commit"])
    signed = dict(receipt, artifactType="signed-isolated-lid-trial", appPath=str(app),
                  signing="exact Apple-anchor/Team/identifier requirements verified", build="completed",
                  certificateSHA1=identity.upper(), packagedFiles=after)
    write_json(candidate / "signed-lid-trial-receipt.json", signed)
    return app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", required=True, help="Exact full clean checkout HEAD")
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--output", help="Fresh local-lab/.staging.noindex/lid-trial-* folder")
    parser.add_argument("--build-and-sign", action="store_true", help="Explicitly build and use the selected signing identity")
    parser.add_argument("--identity", help="Explicit certificate SHA-1; required only with --build-and-sign")
    args = parser.parse_args()
    if args.build_and_sign != bool(args.identity):
        parser.error("--build-and-sign and --identity must be supplied together")
    root = Path(__file__).resolve().parents[1]
    try:
        candidate, receipt = prepare(root, args.commit, args.team_id, args.output)
        if args.build_and_sign:
            app = build_and_sign(root, candidate, receipt, args.identity)
            print("Signed isolated trial prepared: " + str(app))
        else:
            print("Source trial prepared without building or signing: " + str(candidate))
        print("No install, launch, helper enrollment or physical qualification performed.")
    except (TrialError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(2, str(error) + "\n")


if __name__ == "__main__":
    main()
