#!/usr/bin/env python3
"""Prepare or verify an offline source preview. Requires the matching Git source; never builds or publishes."""
import argparse
from contextlib import contextmanager
import datetime
import importlib.util
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('tilvero_release_helpers', ROOT / 'scripts/release.py')
release = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(release)
ReleaseError = release.ReleaseError
MANIFEST = 'source-release.json'
REQUIRED = {
    'LICENSE', 'COPYRIGHT', 'THIRD_PARTY_NOTICES.md', 'Helper/THIRD_PARTY_NOTICES.md',
    'Package.swift', 'Config/Release.json', 'Tilvero.xcodeproj/project.pbxproj',
    'scripts/build-local-app.sh', 'scripts/build-xcode.sh', 'scripts/generate-xcode-project.py',
}
PRIVATE_SUFFIXES = ('.sqlite', '.db', '.p12', '.pfx', '.pem', '.key',
                    '.mobileprovision', '.provisionprofile')
PRIVATE_DIRS = {'build', '.build', '.swiftpm', 'DerivedData', '.git', '__pycache__',
                'history', 'exports', 'runtime', 'xcuserdata'}
FIELDS = {'schemaVersion', 'artifactType', 'commit', 'tag', 'version', 'build', 'channel',
          'license', 'buildRequirements', 'binaryIncluded', 'requiresBuild', 'createdAt', 'sourceZIP'}


@contextmanager
def source_root(root):
    """Scope the existing helper's repository seam to this synchronous invocation."""
    previous = release.ROOT
    release.ROOT = root
    try:
        yield
    finally:
        release.ROOT = previous


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ReleaseError('Duplicate JSON field: ' + key)
        value[key] = item
    return value


def read_json(path):
    return json.loads(path.read_text(), object_pairs_hook=unique_object)


def private_path(name):
    parts = PurePosixPath(name).parts
    return (any(name == item or name.startswith(item) for item in release.FORBIDDEN)
            or any(part in PRIVATE_DIRS or part == '.env' or part.startswith('.env.') for part in parts)
            or name.endswith(PRIVATE_SUFFIXES)
            or re.search(r'\.(?:sqlite|db)-[^/]+$', name) is not None
            or any(part.endswith(('.app', '.dSYM', '.xcarchive')) for part in parts))


def source_inventory(root, commit):
    """Admit only the full regular-file public source tree, including its notices."""
    entries = {}
    for record in release.git(root, 'ls-tree', '-rz', '--full-tree', commit).split('\0'):
        if not record:
            continue
        header, name = record.split('\t', 1)
        mode, kind, blob = header.split()
        parts = PurePosixPath(name).parts
        if (mode not in ('100644', '100755') or kind != 'blob' or not parts
                or name.startswith('/') or '..' in parts or '\\' in name
                or any(ord(char) < 32 for char in name)):
            raise ReleaseError('Unsupported/unsafe committed source path: ' + name)
        if private_path(name):
            raise ReleaseError('Private source path rejected: ' + name)
        entries[name] = (mode, blob)
    missing = REQUIRED - entries.keys()
    if missing or not any(name.startswith('Sources/') for name in entries):
        raise ReleaseError('Missing required source/license/build inputs: ' + ', '.join(sorted(missing)))
    return entries


def committed_config(root, commit):
    if type(commit) is not str or not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ReleaseError('An exact full commit is required')
    try:
        if release.git(root, 'rev-parse', commit + '^{commit}') != commit:
            raise ReleaseError('Source commit mismatch')
        config = json.loads(release.git(root, 'show', commit + ':Config/Release.json'),
                            object_pairs_hook=unique_object)
        return release.load_config_data(config)
    except ReleaseError as error:
        raise ReleaseError('Matching committed source/configuration is required: ' + str(error)) from error


def verify_tree_bytes(root, archive, entries):
    # git archive may honor export-ignore/export-subst. A fresh archive comparison
    # alone would accept those omissions/substitutions; also bind every raw blob.
    file_names = {info.filename[len('Tilvero/'):] for info in archive.infolist() if not info.is_dir()}
    if file_names != entries.keys():
        raise ReleaseError('Source ZIP does not contain the full committed tree')
    objects = b''.join((blob + '\n').encode('ascii') for mode, blob in entries.values())
    try:
        blobs = subprocess.check_output(['git', '-C', str(root), 'cat-file', '--batch'], input=objects,
                                        stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as error:
        raise ReleaseError('Committed source blobs unavailable') from error
    offset = 0
    for name, (mode, blob) in entries.items():
        end = blobs.index(b'\n', offset)
        header = blobs[offset:end].decode('ascii').split()
        if len(header) != 3 or header[:2] != [blob, 'blob']:
            raise ReleaseError('Committed source blob mismatch')
        size = int(header[2])
        content = blobs[end + 1:end + 1 + size]
        offset = end + 2 + size
        info = archive.getinfo('Tilvero/' + name)
        if archive.read(info) != content:
            raise ReleaseError('Source ZIP differs from committed source bytes')


def validate_manifest(manifest, config):
    if type(manifest) is not dict or set(manifest) != FIELDS:
        raise ReleaseError('Incomplete/unknown source manifest fields')
    if type(manifest['schemaVersion']) is not int or manifest['schemaVersion'] != 1:
        raise ReleaseError('Unsupported source manifest schema')
    if manifest['artifactType'] != 'source-preview' or manifest['license'] != 'GPL-3.0-only':
        raise ReleaseError('Invalid source artifact type/license')
    if manifest['binaryIncluded'] is not False or manifest['requiresBuild'] is not True:
        raise ReleaseError('Source preview must contain no binary and require a build')
    for key in ('tag', 'version', 'build', 'channel'):
        if type(manifest[key]) is not str or manifest[key] != config[key]:
            raise ReleaseError('Manifest differs from committed release configuration: ' + key)
    requirements = manifest['buildRequirements']
    if type(requirements) is not dict or requirements != {
            'architecture': config['architecture'], 'minimumOS': config['minimumOS']}:
        raise ReleaseError('Source build requirements/configuration mismatch')
    created = manifest['createdAt']
    if type(created) is not str:
        raise ReleaseError('Invalid UTC creation timestamp')
    try:
        timestamp = datetime.datetime.fromisoformat(created.replace('Z', '+00:00'))
    except ValueError as error:
        raise ReleaseError('Invalid UTC creation timestamp') from error
    if timestamp.tzinfo is None or timestamp.utcoffset() != datetime.timedelta(0):
        raise ReleaseError('Invalid UTC creation timestamp')
    asset = manifest['sourceZIP']
    if (type(asset) is not dict or set(asset) != {'name', 'size', 'sha256'}
            or type(asset['name']) is not str
            or asset['name'] != 'Tilvero-' + config['tag'][1:] + '-source.zip'
            or type(asset['size']) is not int or asset['size'] <= 0
            or type(asset['sha256']) is not str or not re.fullmatch(r'[0-9a-f]{64}', asset['sha256'])):
        raise ReleaseError('Invalid source ZIP asset record/name/hash/size')


def verify(root, manifest_path):
    root, manifest_path = Path(root).resolve(), Path(manifest_path).absolute()
    if manifest_path.name != MANIFEST or manifest_path.is_symlink() or not manifest_path.is_file():
        raise ReleaseError('Expected regular ' + MANIFEST)
    manifest = read_json(manifest_path)
    if type(manifest) is not dict or set(manifest) != FIELDS:
        raise ReleaseError('Incomplete/unknown source manifest fields')
    config = committed_config(root, manifest['commit'])
    validate_manifest(manifest, config)
    entries = source_inventory(root, manifest['commit'])
    # The existing verifier reads the repository configuration for its immutable
    # public baseline; reject a different baseline rather than bypass that gate.
    if release.load_config(root / 'Config/Release.json')['publicBaseline'] != config['publicBaseline']:
        raise ReleaseError('Public baseline differs from committed configuration')
    tags = release.git(root, 'tag', '--list').splitlines()
    if config['tag'] in tags and release.git(root, 'rev-parse', config['tag'] + '^{commit}') != manifest['commit']:
        raise ReleaseError('Existing tag differs from source commit')
    asset = manifest['sourceZIP']
    expected = {MANIFEST, 'SHA256SUMS', asset['name']}
    if {path.name for path in manifest_path.parent.iterdir()} != expected:
        raise ReleaseError('Source output must contain exactly ZIP, manifest and SHA256SUMS')
    for name in expected:
        path = manifest_path.parent / name
        if path.is_symlink() or not path.is_file():
            raise ReleaseError('Expected regular source output file: ' + name)
    source = manifest_path.parent / asset['name']
    if source.stat().st_size != asset['size'] or release.sha(source) != asset['sha256']:
        raise ReleaseError('Source ZIP hash/size mismatch')
    with zipfile.ZipFile(source) as archive:
        if archive.comment != manifest['commit'].encode('ascii'):
            raise ReleaseError('Source ZIP commit comment mismatch')
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ReleaseError('Duplicate source ZIP path')
        for name in names:
            relative = name[len('Tilvero/'):] if name.startswith('Tilvero/') else None
            if (relative is None or name.startswith('/') or '..' in PurePosixPath(name).parts
                    or '\\' in name or (relative and private_path(relative))):
                raise ReleaseError('Unsafe/private source ZIP path: ' + name)
        if archive.testzip() is not None:
            raise ReleaseError('Source ZIP CRC failure')
        with source_root(root):
            release.verify_source_zip(source, manifest['commit'])
        verify_tree_bytes(root, archive, entries)
    release.verify_checksum_file(manifest_path, {'assets': [asset]})
    return manifest


def prepare(root, commit, output=None, config_path=None):
    root = Path(root).resolve()
    config = release.load_config(Path(config_path) if config_path else root / 'Config/Release.json')
    release.admit_source(root, commit, config)
    source_inventory(root, commit)
    destination = (Path(output) if output else root / 'build/source-releases' / config['tag']).absolute()
    work = destination.with_name(destination.name + '.incomplete')
    if destination.exists() or destination.is_symlink() or work.exists() or work.is_symlink():
        raise ReleaseError('Output or incomplete output already exists; preserve it and use a fresh output')
    development = root / 'build/Tilvero.app'
    if destination.resolve().is_relative_to(development.resolve()):
        raise ReleaseError('Source output must be outside the development bundle')
    before = release.bundle_digest(development) if development.exists() else None
    destination.parent.mkdir(parents=True, exist_ok=True)
    work.mkdir()
    source = work / ('Tilvero-' + config['tag'][1:] + '-source.zip')
    release.run(['git', '-C', root, 'archive', '--format=zip', '--prefix=Tilvero/',
                 '--output', source, commit])
    manifest = dict(schemaVersion=1, artifactType='source-preview', commit=commit,
                    tag=config['tag'], version=config['version'], build=config['build'],
                    channel=config['channel'], license='GPL-3.0-only',
                    buildRequirements=dict(architecture=config['architecture'], minimumOS=config['minimumOS']),
                    binaryIncluded=False, requiresBuild=True,
                    createdAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    sourceZIP=release.asset_record(source))
    manifest_path = work / MANIFEST
    release.write_json(manifest_path, manifest)
    (work / 'SHA256SUMS').write_text(''.join(f'{release.sha(path)}  {path.name}\n'
                                           for path in (source, manifest_path)))
    verify(root, manifest_path)
    # Recheck admission after packaging, then finalize only if the development
    # bundle still has exactly its prior content (including absent/present state).
    release.admit_source(root, commit, config)
    after = release.bundle_digest(development) if development.exists() else None
    if after != before:
        raise ReleaseError('Existing development bundle changed')
    if destination.exists() or destination.is_symlink():
        raise ReleaseError('Final destination appeared during preparation')
    work.rename(destination)
    return destination / MANIFEST


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT,
                        help='Git source checkout used for complete committed-tree comparison')
    commands = parser.add_subparsers(dest='command', required=True)
    command = commands.add_parser('prepare', help='Export current clean committed source into fresh output')
    command.add_argument('--commit', required=True)
    command.add_argument('--config', type=Path)
    command.add_argument('--output', type=Path)
    command = commands.add_parser('verify', help='Verify source assets against matching committed Git source')
    command.add_argument('--manifest', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == 'prepare':
            path = prepare(args.root, args.commit, args.output, args.config)
        else:
            path = args.manifest
            verify(args.root, path)
        print(json.dumps(dict(status='source-integrity-pass', artifactType='source-preview',
                              binaryIncluded=False, requiresBuild=True, manifest=str(path)), indent=2))
    except (ReleaseError, OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile,
            subprocess.SubprocessError, RuntimeError) as error:
        print(json.dumps(dict(status='blocked', reason=str(error))), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
