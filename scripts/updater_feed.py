#!/usr/bin/env python3
"""Prepare unsigned metadata or validate an owner-signed Monitoring feed locally.

No network publication, private-key access, key generation or signing occurs.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import release
from updater_package import BUNDLE_ID, UpdaterError, https_url, load_config

ROOT = Path(__file__).resolve().parent.parent
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)

def verify_signature(config, signature, path):
    try:
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError()
    except (ValueError, TypeError):
        raise UpdaterError('Missing valid Ed25519 signature') from None
    subprocess.run(['xcrun', 'swift', str(ROOT/'scripts/verify_updater_signature.swift'), config['publicKey'], signature, str(path)], check=True)

def admitted_release(manifest_path, config):
    if not config['enabled']:
        raise UpdaterError('Updater is disabled; configure existing owner trust first')
    manifest = release.verify_manifest(Path(manifest_path))
    required = dict(bundleID=BUNDLE_ID, mode='monitoring', architecture='arm64', teamID=config['teamID'], signingMode='developer-id', notarization='accepted-stapled', downloadedInstall='accepted', publicationReady=True)
    if any(manifest.get(k) != v for k, v in required.items()):
        raise UpdaterError('Feed preparation requires an accepted trusted downloaded Monitoring release')
    if not re.fullmatch(r'[1-9][0-9]*', manifest['build']):
        raise UpdaterError('A monotonically increasing integer build is required')
    record = next(a for a in manifest['assets'] if a['name'].endswith('.dmg'))
    return manifest, record, Path(manifest_path).parent/record['name']

def signed_feed_content(data):
    # Strict subset of Sparkle 2.10.1's signing-block format. No unverified
    # trailing XML or duplicate signature blocks are accepted by this tool.
    marker = b'<!-- sparkle-signatures:\n'
    if data.count(marker) != 1:
        raise UpdaterError('Expected exactly one signed-feed block')
    content, block = data.split(marker)
    match = re.fullmatch(rb'edSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\n?', block)
    if not match or int(match[2]) != len(content):
        raise UpdaterError('Invalid signed-feed length or structure')
    return content, match[1].decode('ascii')

def prepare(args):
    config = load_config(args.config)
    manifest, record, archive = admitted_release(args.release_manifest, config)
    if not https_url(args.download_url) or Path(args.download_url.split('?')[0]).name != record['name']:
        raise UpdaterError('Download URL must be HTTPS and match the admitted archive name')
    signature = Path(args.archive_signature).read_text().strip()
    verify_signature(config, signature, archive)
    path = Path(args.output)
    if path.exists() or path.is_symlink() or not path.name.endswith('.unsigned.xml'):
        raise UpdaterError('Use a fresh *.unsigned.xml output; unsigned feeds are not publishable')
    rss = ET.Element('rss', {'version': '2.0'})
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = 'Tilvero Monitoring Updates'
    ET.SubElement(channel, 'link').text = config['feedURL']
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = 'Tilvero ' + manifest['version']
    ET.SubElement(item, '{'+SPARKLE+'}version').text = manifest['build']
    ET.SubElement(item, '{'+SPARKLE+'}shortVersionString').text = manifest['version']
    ET.SubElement(item, '{'+SPARKLE+'}minimumSystemVersion').text = manifest['minimumOS']
    if manifest['channel'] == 'beta':
        ET.SubElement(item, '{'+SPARKLE+'}channel').text = 'beta'
    ET.SubElement(item, 'enclosure', {'url': args.download_url, 'length': str(record['size']), 'type': 'application/octet-stream',
        '{'+SPARKLE+'}edSignature': signature, '{'+SPARKLE+'}installationType': 'application',
        'tilveroBundleID': BUNDLE_ID, 'tilveroProfile': 'monitoring', 'tilveroTeamID': config['teamID'], 'tilveroArchitecture': 'arm64'})
    ET.indent(rss)
    with path.open('xb') as output:
        output.write(ET.tostring(rss, encoding='utf-8', xml_declaration=True) + b'\n')
    return {'status': 'unsigned-not-publishable', 'path': str(path), 'requires': 'owner signing with the existing Sparkle key, then verify'}

def verify(args):
    config = load_config(args.config)
    manifest, record, archive = admitted_release(args.release_manifest, config)
    feed = Path(args.feed)
    if feed.stat().st_size > 1024*1024:
        raise UpdaterError('Appcast exceeds 1 MiB')
    content, signature = signed_feed_content(feed.read_bytes())
    if b'<!DOCTYPE' in content or b'<!ENTITY' in content:
        raise UpdaterError('DTD/entity declarations are not allowed')
    with tempfile.TemporaryDirectory(prefix='tilvero-feed-verify-') as tmp:
        unsigned = Path(tmp)/'content.xml'; unsigned.write_bytes(content)
        verify_signature(config, signature, unsigned)
    root = ET.fromstring(content)
    items = root.findall('./channel/item')
    if root.tag != 'rss' or not items:
        raise UpdaterError('Feed must contain Monitoring items')
    matching = []
    for item in items:
        enclosures = item.findall('enclosure')
        if len(enclosures) != 1:
            raise UpdaterError('Each item requires exactly one executable enclosure')
        e = enclosures[0].attrib
        required = {'tilveroBundleID': BUNDLE_ID, 'tilveroProfile': 'monitoring', 'tilveroTeamID': config['teamID'], 'tilveroArchitecture': 'arm64', '{'+SPARKLE+'}installationType': 'application'}
        if any(e.get(k) != v for k, v in required.items()) or not https_url(e.get('url')) or not e['url'].split('?')[0].endswith('.dmg'):
            raise UpdaterError('Wrong profile, identity, team, architecture or artifact')
        build = item.findtext('{'+SPARKLE+'}version') or e.get('{'+SPARKLE+'}version', '')
        if not re.fullmatch(r'[1-9][0-9]*', build):
            raise UpdaterError('Invalid build in feed')
        if build == manifest['build']:
            matching.append(e)
    if len(matching) != 1:
        raise UpdaterError('Expected exactly one item for the admitted release build')
    enclosure = matching[0]
    if enclosure.get('length') != str(record['size']) or Path(enclosure['url'].split('?')[0]).name != record['name']:
        raise UpdaterError('Archive name/length differs from the admitted release')
    verify_signature(config, enclosure.get('{'+SPARKLE+'}edSignature'), archive)
    return {'status': 'locally-verified-signed-feed', 'sha256': hashlib.sha256(feed.read_bytes()).hexdigest(), 'publicationPerformed': False}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('prepare', 'verify'):
        p = sub.add_parser(name); p.add_argument('--config', required=True); p.add_argument('--release-manifest', required=True)
        if name == 'prepare':
            p.add_argument('--archive-signature', required=True); p.add_argument('--download-url', required=True); p.add_argument('--output', required=True)
        else:
            p.add_argument('--feed', required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(prepare(args) if args.command == 'prepare' else verify(args)))
    except (UpdaterError, release.ReleaseError, OSError, ValueError, subprocess.CalledProcessError, ET.ParseError) as error:
        parser.exit(1, f'Updater feed rejected: {error}\n')

if __name__ == '__main__':
    main()
