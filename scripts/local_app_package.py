#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 RaNDoM6913

"""Local laboratory staging and provenance; never launches, promotes or publishes."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
import updater_package


class PackageError(Exception):
    pass


LAB_ICON = Path("local-lab/demos/native-time-picker-20261031/Resources/LabIcon.icns")
LAB_METADATA = {
    "CFBundleName": "Tilvero Lab", "CFBundleDisplayName": "Tilvero Lab",
    "CFBundleIdentifier": "local.tilvero.lab", "CFBundleExecutable": "TilveroApp",
    "CFBundleIconFile": "LabIcon", "TilveroDataScope": "laboratory",
}


def sha256(path):
    if path.is_symlink() or not path.is_file():
        raise PackageError("Expected a regular input file: " + str(path))
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def reject_symlinks(root, path):
    relative = path.relative_to(root)
    current = root
    for part in relative.parts:
        current /= part
        if current.is_symlink():
            raise PackageError("Laboratory staging must not traverse a symlink: " + str(current))


def staging_path(root, output=None):
    staging = root / "local-lab/.staging.noindex"
    reject_symlinks(root, staging)
    if output is None:
        staging.mkdir(parents=True, exist_ok=True)
        return Path(tempfile.mkdtemp(prefix="shared-app-", dir=staging)) / "Tilvero Lab.app"
    requested = Path(output)
    if not requested.is_absolute():
        requested = root / requested
    requested = Path(os.path.abspath(requested))
    try:
        relative = requested.relative_to(staging)
    except ValueError as error:
        raise PackageError("Laboratory output must be a fresh candidate inside local-lab/.staging.noindex.") from error
    reject_symlinks(root, requested)
    if len(relative.parts) < 2 or requested.name != "Tilvero Lab.app":
        raise PackageError("Laboratory staging requires a candidate folder containing Tilvero Lab.app.")
    return requested


def source_inputs(root):
    paths = {
        root / name for name in (
            "Package.swift", "Config/Info.plist", "Config/TilveroLidHelper-Info.plist", "Assets/AppIcon.icns", "LICENSE", "COPYRIGHT",
            "THIRD_PARTY_NOTICES.md", "scripts/build-local-app.sh", "scripts/build-lab-app.sh",
            "scripts/local_app_package.py", "scripts/toolchain.sh", "scripts/updater_package.py",
            "Config/Updater.json", "Config/Sparkle-2.10.1.inventory.json",
        )
    }
    for directory in ("Sources", "Helper", "Config/LaunchDaemons"):
        paths.update(path for path in (root / directory).rglob("*") if not path.is_dir())
    paths.add(root / LAB_ICON)
    resolved = root / "Package.resolved"
    if resolved.exists():
        paths.add(resolved)
    return {str(path.relative_to(root)): sha256(path) for path in sorted(paths)}


def write_json(path, value):
    # A caller may select a fresh app in an existing candidate folder; preserve
    # any prior provenance rather than replacing it silently.
    with path.open("x") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")


def prepare(root, output):
    inputs = source_inputs(root)
    app = staging_path(root, output)
    app.parent.mkdir(parents=True, exist_ok=True)
    try:
        app.mkdir()
    except FileExistsError as error:
        raise PackageError("Output already exists; preserve it and choose fresh laboratory staging.") from error
    write_json(app.parent / "source-inputs.json", inputs)
    print(app)


def verify_sources(root, app):
    original = json.loads((app.parent / "source-inputs.json").read_text())
    if source_inputs(root) != original:
        raise PackageError("Source inputs changed during the build; no successful provenance receipt can be issued.")
    return original


def bundle_files(path):
    framework = path / "Contents/Frameworks/Sparkle.framework"
    if framework.exists():
        try: updater_package.validate_framework(framework)
        except updater_package.UpdaterError as error: raise PackageError(str(error)) from error
    result = {}
    for item in sorted(path.rglob("*")):
        if item.is_symlink():
            if not framework.exists() or not item.is_relative_to(framework):
                raise PackageError("Unexpected packaged symlink: " + str(item))
            result[str(item.relative_to(path))] = hashlib.sha256(("symlink:" + os.readlink(item)).encode()).hexdigest()
        elif item.is_file():
            result[str(item.relative_to(path))] = sha256(item)
    return result


def capture(root, app, binary_directory):
    verify_sources(root, app)
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info.update(LAB_METADATA)
    # The immutable launch policy chooses control ownership. A Lab package is
    # the full app and must not inherit a whole-app monitoring release switch.
    info.pop("TilveroReleaseMode", None)
    info_path.write_bytes(plistlib.dumps(info))
    shutil.copy2(root / LAB_ICON, app / "Contents/Resources/LabIcon.icns")

    copies = {}

    def bind(source, destination):
        digest = sha256(source)
        if sha256(app / destination) != digest:
            raise PackageError("Packaged copy differs from its common build input: " + destination)
        copies[destination] = {"source": str(source), "sha256": digest}

    bind(binary_directory / "TilveroApp", "Contents/MacOS/TilveroApp")
    bind(binary_directory / "TilveroHelper", "Contents/Library/HelperTools/TilveroHelper")
    bind(binary_directory / "TilveroLidHelper", "Contents/Library/HelperTools/TilveroLidHelper")
    for source in sorted((root / "Config/LaunchDaemons").glob("*.plist")):
        bind(source, "Contents/Library/LaunchDaemons/" + source.name)
    bind(root / "Sources/TilveroApp/Resources/Localizable.xcstrings", "Contents/Resources/Localizable.xcstrings")
    for name in ("LICENSE", "COPYRIGHT", "THIRD_PARTY_NOTICES.md"):
        bind(root / name, "Contents/Resources/Legal/" + name)
    bind(root / "Helper/THIRD_PARTY_NOTICES.md", "Contents/Resources/Legal/Helper/THIRD_PARTY_NOTICES.md")
    bind(root / "Assets/AppIcon.icns", "Contents/Resources/AppIcon.icns")
    bind(root / LAB_ICON, "Contents/Resources/LabIcon.icns")
    resources = sorted(binary_directory.glob("*TilveroApp*.bundle"))
    if not resources:
        raise PackageError("Common SwiftPM TilveroApp resource bundle is missing.")
    for resource in resources:
        source_files = bundle_files(resource)
        destination = app / "Contents/Resources" / resource.name
        if bundle_files(destination) != source_files:
            raise PackageError("Packaged SwiftPM resource bundle differs from its build input: " + resource.name)
        for name in source_files:
            bind(resource / name, "Contents/Resources/" + resource.name + "/" + name)
    # Signing can change the three bound Mach-O executables, but never copied resources
    # or the configured bundle identity.
    before_signing = bundle_files(app)
    write_json(app.parent / "copied-inputs.json", {"copiedInputs": copies, "beforeSigning": before_signing})


def finish(root, app):
    inputs = verify_sources(root, app)
    copied = json.loads((app.parent / "copied-inputs.json").read_text())
    packaged = bundle_files(app)
    executables = {"Contents/MacOS/TilveroApp", "Contents/Library/HelperTools/TilveroHelper",
                   "Contents/Library/HelperTools/TilveroLidHelper"}
    for name, digest in copied["beforeSigning"].items():
        if name not in executables and packaged.get(name) != digest:
            raise PackageError("Packaged resource changed after copy: " + name)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if any(info.get(key) != value for key, value in LAB_METADATA.items()) or "TilveroReleaseMode" in info:
        raise PackageError("Laboratory bundle identity changed after packaging.")
    write_json(app.parent / "build-receipt.json", {
        "schemaVersion": 1,
        "artifactType": "local-laboratory-candidate",
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "projectRoot": str(root), "appPath": str(app),
        "swiftPMProduct": "TilveroApp",
        "sourceInputs": inputs, "copiedInputs": copied["copiedInputs"],
        "bundleMetadata": info, "packagedFiles": packaged,
        "signing": "local ad-hoc; builder completed codesign --verify --strict",
        "runtimeAcceptance": "not performed by builder",
        "hardwareAcceptance": "not performed by builder",
        "publication": "local-only; no distribution acceptance",
    })


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "capture", "finish"))
    parser.add_argument("--project-root", required=True, type=Path)
    parser.add_argument("--app")
    parser.add_argument("--binary-directory", type=Path)
    arguments = parser.parse_args()
    root = Path(os.path.abspath(arguments.project_root))
    try:
        if arguments.action == "prepare":
            prepare(root, arguments.app)
        else:
            if not arguments.app:
                raise PackageError("--app is required")
            app = staging_path(root, arguments.app)
            if arguments.action == "capture":
                if arguments.binary_directory is None:
                    raise PackageError("--binary-directory is required")
                capture(root, app, arguments.binary_directory)
            else:
                finish(root, app)
    except (PackageError, OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
