import base64
import importlib.util
import json
import plistlib
from pathlib import Path
import subprocess
import sys
import struct
import hashlib
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'scripts'))
import updater_package as package
import updater_feed as feed

class UpdaterPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = json.loads((ROOT/'Config/Updater.json').read_text())

    def write_config(self):
        path = self.root/'updater.json'; path.write_text(json.dumps(self.config)); return path

    def test_disabled_default_has_no_placeholder_trust(self):
        self.assertFalse(package.load_config(self.write_config())['enabled'])
        self.config['teamID'] = 'EXAMPLE1234'
        with self.assertRaises(package.UpdaterError): package.load_config(self.write_config())

    def test_config_rejects_wrong_identity_profile_and_untrusted_transport(self):
        for field, value in [('bundleID', 'local.tilvero.prototype'), ('profile', 'controller')]:
            original = self.config[field]; self.config[field] = value
            with self.assertRaises(package.UpdaterError): package.load_config(self.write_config())
            self.config[field] = original
        self.config.update(enabled=True, teamID='ABCD123456', publicKey=base64.b64encode(bytes(32)).decode())
        for url in ['http://example.org/appcast.xml', 'https://user:pass@example.org/appcast.xml', 'file:///tmp/appcast.xml']:
            self.config['feedURL'] = url
            with self.assertRaises(package.UpdaterError): package.load_config(self.write_config())

    def test_development_and_lab_cannot_be_promoted_by_release_config(self):
        self.config.update(enabled=True, teamID='ABCD123456', publicKey=base64.b64encode(bytes(32)).decode(), feedURL='https://example.org/monitoring/appcast.xml')
        config = self.write_config()
        for bundle_id, profile in [('local.tilvero.prototype', 'development'), ('io.github.random6913.tilvero.lab', 'monitoring'), (package.BUNDLE_ID, 'controller')]:
            info = self.root/'Info.plist'; info.write_bytes(plistlib.dumps(dict(CFBundleIdentifier=bundle_id, TilveroDataScope='production', TilveroReleaseMode=profile)))
            package.configure(info, config)
            result = plistlib.loads(info.read_bytes())
            self.assertFalse(result['TilveroUpdaterConfiguration']['enabled'])
            self.assertNotIn('SUFeedURL', result)
            self.assertEqual(result['CFBundleIdentifier'], bundle_id)
            self.assertTrue(result['SURequireSignedFeed'])
            self.assertFalse(result['SUAutomaticallyUpdate'])

    def test_signing_is_inside_out_with_existing_identity_and_never_deep(self):
        app = self.root/'Tilvero.app'
        framework = app/'Contents/Frameworks/Sparkle.framework'
        (framework/'Versions/B').mkdir(parents=True)
        (framework/'Versions/B/Autoupdate').write_bytes(b'fixture')
        for name in ['Updater.app', 'XPCServices/Installer.xpc', 'XPCServices/Downloader.xpc']:
            (framework/'Versions/B'/name).mkdir(parents=True)
        with mock.patch.object(package, 'validate_framework'), mock.patch.object(package.subprocess, 'run') as run:
            package.sign_nested(app, 'Existing Developer ID')
        signed = [call.args[0] for call in run.call_args_list if '--sign' in call.args[0]]
        self.assertEqual(Path(signed[0][-1]).name, 'Autoupdate')
        self.assertEqual(Path(signed[-1][-1]).name, 'Sparkle.framework')
        self.assertTrue(all('--deep' not in command for command in signed))

    def test_source_only_or_unaccepted_binary_cannot_generate_feed(self):
        self.config['enabled'] = True
        for manifest in [dict(artifactType='source-preview', binaryIncluded=False), dict(bundleID=package.BUNDLE_ID, mode='monitoring', publicationReady=False)]:
            with mock.patch.object(feed.release, 'verify_manifest', return_value=manifest):
                with self.assertRaises(package.UpdaterError): feed.admitted_release(self.root/'release.json', self.config)

    def test_unsigned_duplicate_trailing_or_wrong_length_feed_rejected(self):
        for value in [b'<rss/>', b'<rss/><!-- sparkle-signatures:\nedSignature: AAA=\nlength: 1\n-->\n', b'<rss/><!-- sparkle-signatures:\nedSignature: AAA=\nlength: 6\n-->\n<evil/>']:
            with self.assertRaises(package.UpdaterError): feed.signed_feed_content(value)

    def test_feed_signing_block_covers_exact_content(self):
        content = b'<rss/>'
        signature = base64.b64encode(bytes(64))
        data = content + b'<!-- sparkle-signatures:\nedSignature: ' + signature + b'\nlength: 6\n-->\n'
        actual, sig = feed.signed_feed_content(data)
        self.assertEqual(actual, content); self.assertEqual(sig.encode(), signature)
        with self.assertRaises(package.UpdaterError): feed.signed_feed_content(data+data)

    def test_code_payload_hash_ignores_only_signature_block_not_executable_bytes(self):
        # Tiny deterministic Mach-O-format payload, not executable code or an
        # updater artifact. It exercises signature bookkeeping normalization.
        path = self.root/'payload'
        header = struct.pack('<IIIIIIII', 0xfeedfacf, 0x0100000c, 0, 2, 1, 16, 0, 0)
        command = struct.pack('<IIII', 0x1d, 16, 55, 4)
        path.write_bytes(header + command + b'payload' + b'sign')
        original = package.code_payload_digest(path)
        path.write_bytes(header + command + b'payload' + b'other signature bytes')
        self.assertEqual(package.code_payload_digest(path), original)
        path.write_bytes(header + command + b'tamper!' + b'sign')
        self.assertNotEqual(package.code_payload_digest(path), original)

    def test_fixed_framework_inventory_rejects_tamper_extra_files_and_escaping_links(self):
        project = self.root/'project'; framework = project/'framework'
        (project/'scripts').mkdir(parents=True); (project/'Config').mkdir()
        framework.mkdir(); (framework/'resource').write_bytes(b'pinned')
        (framework/'alias').symlink_to('resource')
        inventory = {'files': {'resource': {'kind':'resource', 'sha256':hashlib.sha256(b'pinned').hexdigest()}}, 'symlinks': {'alias':'resource'}}
        (project/'Config/Sparkle-2.10.1.inventory.json').write_text(json.dumps(inventory))
        with mock.patch.object(package, '__file__', str(project/'scripts/updater_package.py')):
            package.validate_framework(framework)
            (framework/'resource').write_bytes(b'tampered')
            with self.assertRaises(package.UpdaterError): package.validate_framework(framework)
            (framework/'resource').write_bytes(b'pinned')
            (framework/'extra').write_bytes(b'foreign')
            with self.assertRaises(package.UpdaterError): package.validate_framework(framework)
            (framework/'extra').unlink(); (framework/'alias').unlink(); (framework/'alias').symlink_to('/tmp')
            with self.assertRaises(package.UpdaterError): package.validate_framework(framework)

    def test_public_key_only_verifier_accepts_rfc8032_vector_and_rejects_tamper(self):
        # RFC 8032 section 7.1 TEST 1. No key generation or Keychain access.
        public = bytes.fromhex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a')
        signature = bytes.fromhex('e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b')
        content = self.root/'vector'; content.write_bytes(b'')
        command = ['xcrun', 'swift', str(ROOT/'scripts/verify_updater_signature.swift'), base64.b64encode(public).decode(), base64.b64encode(signature).decode(), str(content)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        content.write_bytes(b'tampered')
        self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
