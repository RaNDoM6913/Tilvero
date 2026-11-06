#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 RaNDoM6913

"""Configure/validate sealed Sparkle policy; never create keys or publish updates."""
import argparse
import base64
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import hashlib
import os
import struct
from urllib.parse import urlsplit

BUNDLE_ID = 'io.github.random6913.tilvero'
VERSION = '2.10.1'
POLICY = dict(SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False,
              SUAllowsAutomaticUpdates=False, SUEnableSystemProfiling=False,
              SUEnableJavaScript=False, SUVerifyUpdateBeforeExtraction=True,
              SURequireSignedFeed=True, SUSignedFeedFailureExpirationInterval=0)

class UpdaterError(ValueError):
    pass

def https_url(value):
    if not isinstance(value, str):
        return False
    try:
        url = urlsplit(value)
        return url.scheme == 'https' and bool(url.hostname) and not url.username and not url.password and not url.fragment
    except ValueError:
        return False

def load_config(path):
    config = json.loads(Path(path).read_text())
    if set(config) != {'schemaVersion', 'enabled', 'profile', 'bundleID', 'teamID', 'feedURL', 'publicKey'}:
        raise UpdaterError('Unexpected updater configuration fields')
    if config['schemaVersion'] != 1 or type(config['enabled']) is not bool or config['profile'] != 'monitoring' or config['bundleID'] != BUNDLE_ID:
        raise UpdaterError('Only exact production Monitoring is an updater profile')
    if config['enabled']:
        if not isinstance(config['teamID'], str) or not re.fullmatch(r'[A-Z0-9]{10}', config['teamID']):
            raise UpdaterError('An existing owner Team ID is required')
        if not https_url(config['feedURL']):
            raise UpdaterError('An owner-controlled HTTPS feed is required')
        try:
            public = base64.b64decode(config['publicKey'], validate=True)
        except (ValueError, TypeError):
            raise UpdaterError('An existing public Ed25519 key is required') from None
        if len(public) != 32:
            raise UpdaterError('Ed25519 public key must be 32 bytes')
    elif any(config[key] is not None for key in ('teamID', 'feedURL', 'publicKey')):
        raise UpdaterError('Disabled configuration must not contain placeholder trust')
    return config

def configure(info_path, config_path):
    config = load_config(config_path)
    path = Path(info_path)
    info = plistlib.loads(path.read_bytes())
    # Development/Lab builds embed the real framework and stay manual even when
    # a future release config is present; no identity/profile promotion occurs.
    qualified_profile = info.get('CFBundleIdentifier') == BUNDLE_ID and info.get('TilveroDataScope') == 'production' and info.get('TilveroReleaseMode') == 'monitoring'
    enabled = config['enabled'] and qualified_profile
    sealed = dict(enabled=enabled, profile='monitoring', bundleID=BUNDLE_ID,
                  teamID=config['teamID'] or '', feedURL=config['feedURL'] or '', publicKey=config['publicKey'] or '')
    info.update(POLICY)
    info['TilveroUpdaterConfiguration'] = sealed
    for key in ('SUFeedURL', 'SUPublicEDKey'):
        info.pop(key, None)
    if enabled:
        info['SUFeedURL'] = config['feedURL']
        info['SUPublicEDKey'] = config['publicKey']
    path.write_bytes(plistlib.dumps(info))

def code_payload_digest(path):
    """Hash all signed Mach-O payload, normalizing only signature bookkeeping.

    Fat offsets/sizes and __LINKEDIT signature allocation can change when the
    exact pinned code is re-signed. Actual load commands and bytes stay bound.
    """
    data = Path(path).read_bytes()
    if data[:4] == b'\xca\xfe\xba\xbe':
        count = struct.unpack_from('>I', data, 4)[0]
        slices = [struct.unpack_from('>IIIII', data, 8+i*20)[2:4] for i in range(count)]
    elif data[:4] == b'\xcf\xfa\xed\xfe':
        slices = [(0, len(data))]
    else:
        raise UpdaterError('Unexpected pinned framework executable format')
    result = hashlib.sha256()
    for offset, size in slices:
        chunk = data[offset:offset+size]
        if chunk[:4] != b'\xcf\xfa\xed\xfe':
            raise UpdaterError('Expected 64-bit Sparkle executable slice')
        count, length = struct.unpack_from('<II', chunk, 16)
        header = bytearray(chunk[:32]); struct.pack_into('<II', header, 16, 0, 0)
        position = 32; end = len(chunk); commands = []
        for _ in range(count):
            command, command_size = struct.unpack_from('<II', chunk, position)
            if command_size < 8 or position+command_size > 32+length:
                raise UpdaterError('Invalid Mach-O load command')
            row = bytearray(chunk[position:position+command_size])
            if command == 0x1d:  # LC_CODE_SIGNATURE
                end = struct.unpack_from('<I', row, 8)[0]
            else:
                if command == 0x19 and row[8:24].rstrip(b'\0') == b'__LINKEDIT':
                    struct.pack_into('<Q', row, 32, 0)  # vmsize
                    struct.pack_into('<Q', row, 48, 0)  # filesize
                commands.append(row)
            position += command_size
        if end < 32+length or end > len(chunk):
            raise UpdaterError('Invalid Mach-O signature offset')
        result.update(header)
        for row in commands: result.update(row)
        result.update(chunk[32+length:end])
    return result.hexdigest()

def validate_framework(framework):
    framework = Path(framework)
    if framework.is_symlink() or not framework.is_dir():
        raise UpdaterError('Missing regular Sparkle framework')
    inventory = json.loads((Path(__file__).resolve().parents[1]/'Config/Sparkle-2.10.1.inventory.json').read_text())
    actual = {str(p.relative_to(framework)): p for p in framework.rglob('*') if not p.is_dir() or p.is_symlink()}
    allowed = inventory['files'] | inventory['symlinks']
    if set(actual)-set(allowed):
        raise UpdaterError('Unexpected Sparkle framework inventory')
    optional = ('Headers', 'PrivateHeaders', 'Modules', 'Versions/B/Headers/', 'Versions/B/PrivateHeaders/', 'Versions/B/Modules/')
    for name, expected in inventory['symlinks'].items():
        path = actual.get(name)
        if path is None and name.startswith(optional): continue
        if path is None or not path.is_symlink() or os.readlink(path) != expected:
            raise UpdaterError('Unexpected Sparkle framework symlink: '+name)
        if not path.resolve().is_relative_to(framework.resolve()):
            raise UpdaterError('Framework symlink escapes its bundle')
    for name, expected in inventory['files'].items():
        path = actual.get(name)
        if path is None and name.startswith(optional): continue
        if path is None or path.is_symlink() or not path.is_file():
            raise UpdaterError('Missing pinned Sparkle framework file: '+name)
        if expected['kind'] == 'code':
            digest = code_payload_digest(path)
        elif expected['kind'] == 'signature':
            continue  # Codesign binds the current owner signature separately.
        else:
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != expected['sha256']:
            raise UpdaterError('Pinned Sparkle payload differs: '+name)
    return inventory

def embed(app, framework):
    app, framework = Path(app), Path(framework)
    validate_framework(framework)
    if framework.name != 'Sparkle.framework' or not (framework/'Versions/B/Sparkle').is_file():
        raise UpdaterError('Expected the pinned Sparkle.framework')
    info = plistlib.loads((framework/'Resources/Info.plist').read_bytes())
    if info.get('CFBundleShortVersionString') != VERSION:
        raise UpdaterError('Sparkle version does not match the pin')
    destination = app/'Contents/Frameworks/Sparkle.framework'
    if destination.exists():
        raise UpdaterError('Refusing to replace an embedded framework')
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['ditto', str(framework), str(destination)], check=True)

def sign_nested(app, identity):
    """Use an explicitly supplied existing identity, inside out; never --deep."""
    framework = Path(app)/'Contents/Frameworks/Sparkle.framework'
    validate_framework(framework)
    if not framework.is_dir() or not identity or identity == '-':
        raise UpdaterError('A framework and existing Developer ID identity are required')
    # XPC executables/apps precede their enclosing framework. The root application
    # is signed by release.py only after every nested signature is verified.
    nested = sorted([p for p in framework.rglob('*') if not p.is_symlink() and p.suffix in ('.xpc', '.app')], key=lambda p: len(p.parts), reverse=True)
    autoupdate = framework/'Versions/B/Autoupdate'
    if not autoupdate.is_file():
        raise UpdaterError('Missing Sparkle Autoupdate executable')
    for path in [autoupdate] + nested + [framework]:
        subprocess.run(['codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', identity, str(path)], check=True)
        subprocess.run(['codesign', '--verify', '--strict', str(path)], check=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('configure'); p.add_argument('--info', required=True); p.add_argument('--config', required=True)
    p = sub.add_parser('validate-config'); p.add_argument('--config', required=True)
    p = sub.add_parser('embed'); p.add_argument('--app', required=True); p.add_argument('--framework', required=True)
    p = sub.add_parser('sign-nested'); p.add_argument('--app', required=True); p.add_argument('--identity', required=True)
    args = parser.parse_args()
    try:
        if args.command == 'configure': configure(args.info, args.config)
        elif args.command == 'validate-config': load_config(args.config)
        elif args.command == 'embed': embed(args.app, args.framework)
        elif args.command == 'sign-nested': sign_nested(args.app, args.identity)
    except (UpdaterError, OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Updater packaging rejected: {error}\n')

if __name__ == '__main__':
    main()
