"""Behavioral source-preview contracts; every Git operation uses disposable fixtures."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / 'scripts/source_release.py'


class SourceReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'repo'
        self.root.mkdir()
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.write('.gitignore', 'build/\n')
        self.commit_all()
        baseline = self.git('rev-parse', 'HEAD')
        self.config = json.loads((REPO / 'Config/Release.json').read_text())
        self.config['publicBaseline'] = baseline
        # Small real Git tree with the public distribution/build inputs.
        for name in ('LICENSE', 'COPYRIGHT', 'THIRD_PARTY_NOTICES.md',
                     'Helper/THIRD_PARTY_NOTICES.md', 'Package.swift',
                     'scripts/build-local-app.sh', 'scripts/build-xcode.sh',
                     'scripts/generate-xcode-project.py', 'Sources/fixture.swift',
                     'Resources/fixture.txt', 'Tilvero.xcodeproj/project.pbxproj'):
            self.write(name, 'fixture ' + name + '\n')
        (self.root / 'scripts/build-local-app.sh').chmod(0o755)
        self.write('Config/Release.json', json.dumps(self.config))
        self.commit_all()
        self.commit = self.git('rev-parse', 'HEAD')
        self.output = self.base / 'preview'
        self.zip_name = 'Tilvero-0.1.0-beta.1-source.zip'

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args],
                                       stderr=subprocess.PIPE, text=True).strip()

    def commit_all(self):
        self.git('add', '.')
        self.git('commit', '-m', 'fixture')

    def cli(self, *args, success=True):
        result = subprocess.run(['python3', str(SCRIPT), '--root', str(self.root), *map(str, args)],
                                capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def prepare(self):
        self.cli('prepare', '--commit', self.commit, '--output', self.output)
        return self.output / 'source-release.json'

    def refresh_checksums(self, manifest_path, manifest):
        import hashlib
        source = self.output / self.zip_name
        manifest['sourceZIP'] = dict(name=self.zip_name, size=source.stat().st_size,
                                    sha256=hashlib.sha256(source.read_bytes()).hexdigest())
        manifest_path.write_text(json.dumps(manifest))
        (self.output / 'SHA256SUMS').write_text(''.join(
            f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n'
            for p in (source, manifest_path)))

    def test_prepare_exports_committed_tree_and_verifies_after_tag_creation(self):
        self.write('private-untracked.txt', 'excluded')
        self.write('build/Tilvero.app/Contents/MacOS/TilveroApp', 'existing development bundle')
        bundle = self.root / 'build/Tilvero.app/Contents/MacOS/TilveroApp'
        before = bundle.read_bytes()
        manifest_path = self.prepare()
        manifest = json.loads(manifest_path.read_text())
        self.assertEqual(set(p.name for p in self.output.iterdir()),
                         {self.zip_name, 'source-release.json', 'SHA256SUMS'})
        self.assertEqual(manifest['commit'], self.commit)
        self.assertEqual(manifest['artifactType'], 'source-preview')
        self.assertEqual(manifest['license'], 'GPL-3.0-only')
        self.assertIs(manifest['binaryIncluded'], False)
        self.assertIs(manifest['requiresBuild'], True)
        self.assertEqual(manifest['buildRequirements'], {'architecture': 'arm64', 'minimumOS': '26.0'})
        self.assertNotIn('publicationReady', manifest)
        with zipfile.ZipFile(self.output / self.zip_name) as archive:
            self.assertEqual(archive.comment.decode(), self.commit)
            self.assertIn('Tilvero/Helper/THIRD_PARTY_NOTICES.md', archive.namelist())
            self.assertNotIn('Tilvero/private-untracked.txt', archive.namelist())
        self.assertEqual(bundle.read_bytes(), before)
        self.assertFalse(self.output.with_name('preview.incomplete').exists())
        self.git('tag', self.config['tag'], self.commit)
        self.cli('verify', '--manifest', manifest_path)
        self.cli('prepare', '--commit', self.commit, '--output', self.base / 'second', success=False)

    def test_admission_rejects_dirty_old_short_and_mismatched_config(self):
        self.cli('prepare', '--commit', self.commit[:12], '--output', self.output, success=False)
        baseline = self.config['publicBaseline']
        self.cli('prepare', '--commit', baseline, '--output', self.output, success=False)
        self.write('LICENSE', 'dirty')
        self.cli('prepare', '--commit', self.commit, '--output', self.output, success=False)
        self.git('checkout', '--', 'LICENSE')
        alternative = self.base / 'config.json'
        alternative.write_text(json.dumps(dict(self.config, build='2')))
        self.cli('prepare', '--commit', self.commit, '--config', alternative,
                 '--output', self.output, success=False)
        self.assertFalse(self.output.exists())

    def test_output_inside_development_bundle_is_rejected_before_any_write(self):
        self.write('build/Tilvero.app/Contents/MacOS/TilveroApp', 'existing')
        development = self.root / 'build/Tilvero.app'
        before = {str(path.relative_to(development)): path.read_bytes()
                  for path in development.rglob('*') if path.is_file()}
        unsafe = development / 'Contents/preview'
        self.cli('prepare', '--commit', self.commit, '--output', unsafe, success=False)
        self.assertFalse(unsafe.exists())
        self.assertFalse(unsafe.with_name('preview.incomplete').exists())
        self.assertEqual({str(path.relative_to(development)): path.read_bytes()
                          for path in development.rglob('*') if path.is_file()}, before)

    def test_existing_output_or_incomplete_is_never_overwritten(self):
        self.output.mkdir()
        marker = self.output / 'owner-data'
        marker.write_text('preserve')
        self.cli('prepare', '--commit', self.commit, '--output', self.output, success=False)
        self.assertEqual(marker.read_text(), 'preserve')
        marker.unlink()
        self.output.rmdir()
        incomplete = self.output.with_name('preview.incomplete')
        incomplete.mkdir()
        (incomplete / 'failure').write_text('preserve')
        self.cli('prepare', '--commit', self.commit, '--output', self.output, success=False)
        self.assertEqual((incomplete / 'failure').read_text(), 'preserve')

    def test_manifest_rejects_types_unknown_trust_and_config_mismatch(self):
        path = self.prepare()
        original = json.loads(path.read_text())
        changes = [('binaryIncluded', True), ('binaryIncluded', 0), ('requiresBuild', False),
                   ('schemaVersion', True), ('publicationReady', True), ('signingMode', 'developer-id'),
                   ('version', '9.0.0'), ('tag', 'v9.0.0'), ('build', '2'),
                   ('commit', 'a' * 40), ('license', 'MIT'), ('createdAt', 'yesterday'),
                   ('buildRequirements', {'architecture': 'x86_64', 'minimumOS': '26.0'}),
                   ('sourceZIP', {'name': '../escape.zip', 'size': 1, 'sha256': 'a' * 64})]
        for key, value in changes:
            with self.subTest(key=key, value=value):
                modified = dict(original, **{key: value})
                path.write_text(json.dumps(modified))
                # Refresh only manifest hash, preserving the malformed asset record.
                import hashlib
                checks = self.output / 'SHA256SUMS'
                checks.write_text(f"{original['sourceZIP']['sha256']}  {self.zip_name}\n" +
                                  f"{hashlib.sha256(path.read_bytes()).hexdigest()}  source-release.json\n")
                self.cli('verify', '--manifest', path, success=False)

    def test_archive_tamper_is_rejected_even_with_fresh_asset_checksums(self):
        path = self.prepare()
        original = (self.output / self.zip_name).read_bytes()
        manifest = json.loads(path.read_text())
        for mutation in ('unchanged', 'bytes', 'extra', 'duplicate', 'unsafe', 'private', 'missing', 'permissions', 'comment', 'crc'):
            with self.subTest(mutation=mutation):
                source = self.output / self.zip_name
                source.write_bytes(original)
                with zipfile.ZipFile(source) as archive:
                    entries = [(info, archive.read(info.filename)) for info in archive.infolist()]
                    comment = archive.comment
                with warnings.catch_warnings():
                    warnings.simplefilter('ignore', UserWarning)
                    with zipfile.ZipFile(source, 'w', compression=zipfile.ZIP_STORED) as archive:
                        archive.comment = b'x' * 40 if mutation == 'comment' else comment
                        for info, data in entries:
                            if info.filename == 'Tilvero/LICENSE':
                                if mutation == 'missing':
                                    continue
                                if mutation == 'bytes':
                                    data = b'tampered'
                                if mutation == 'permissions':
                                    info.external_attr ^= 0o111 << 16
                            attributes = info.external_attr
                            if mutation == 'crc':
                                info.compress_type = zipfile.ZIP_STORED
                            archive.writestr(info, data)
                            # zipfile supplies default Unix modes when Git's ZIP
                            # uses DOS attributes. Preserve the Git representation.
                            info.external_attr = attributes
                        additions = {'extra': 'Tilvero/extra.txt', 'duplicate': 'Tilvero/LICENSE',
                                     'unsafe': 'Tilvero/../escape', 'private': 'Tilvero/.env'}
                        if mutation in additions:
                            archive.writestr(additions[mutation], b'bad')
                if mutation == 'crc':
                    payload = source.read_bytes()
                    source.write_bytes(payload.replace(b'fixture LICENSE', b'corrupt LICENSE', 1))
                self.refresh_checksums(path, manifest)
                self.cli('verify', '--manifest', path, success=mutation == 'unchanged')

    def test_stale_missing_duplicate_checksums_extra_output_and_missing_git_rejected(self):
        path = self.prepare()
        checks = self.output / 'SHA256SUMS'
        original = checks.read_text()
        for content in ('stale\n', original + original.splitlines()[0] + '\n', ''):
            checks.write_text(content)
            self.cli('verify', '--manifest', path, success=False)
        checks.write_text(original)
        extra = self.output / 'unexpected.dmg'
        extra.write_bytes(b'not allowed')
        self.cli('verify', '--manifest', path, success=False)
        extra.unlink()
        absent = self.base / 'no-git'
        absent.mkdir()
        result = subprocess.run(['python3', str(SCRIPT), '--root', str(absent), 'verify',
                                 '--manifest', str(path)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('committed source', result.stderr.lower())

    def test_private_paths_and_nonregular_tree_entries_rejected(self):
        cases = ('planning/private.md', 'runtime/private.db', 'secret.pfx', 'profile.mobileprovision',
                 'data.db-wal', 'nested/.env.local', 'nested/private.key', 'build/leak.app/payload')
        for number, name in enumerate(cases):
            with self.subTest(name=name):
                self.write(name, 'private')
                self.git('add', '-f', name)
                self.git('commit', '-m', 'private fixture')
                commit = self.git('rev-parse', 'HEAD')
                self.cli('prepare', '--commit', commit, '--output', self.base / f'bad-{number}', success=False)
                self.git('rm', name)
                self.git('commit', '-m', 'remove fixture')
        (self.root / 'link').symlink_to('LICENSE')
        self.commit_all()
        self.cli('prepare', '--commit', self.git('rev-parse', 'HEAD'), '--output', self.output, success=False)

    def test_full_tree_and_raw_blobs_survive_git_archive_attributes(self):
        for attribute in ('LICENSE export-ignore', 'Sources/fixture.swift export-subst'):
            with self.subTest(attribute=attribute):
                self.write('.gitattributes', attribute + '\n')
                if 'export-subst' in attribute:
                    self.write('Sources/fixture.swift', '$Format:%H$\n')
                self.commit_all()
                self.cli('prepare', '--commit', self.git('rev-parse', 'HEAD'),
                         '--output', self.base / ('attribute-' + attribute.split()[-1]), success=False)

    def test_verify_rejects_misbound_tag_and_duplicate_json_keys(self):
        path = self.prepare()
        self.git('tag', self.config['tag'], self.config['publicBaseline'])
        self.cli('verify', '--manifest', path, success=False)
        self.git('tag', '-d', self.config['tag'])
        original = path.read_text()
        path.write_text(original.replace('{', '{"binaryIncluded": true,', 1))
        self.cli('verify', '--manifest', path, success=False)

    def test_missing_license_and_foreign_ancestry_are_rejected(self):
        self.git('rm', 'LICENSE')
        self.git('commit', '-m', 'missing license')
        self.cli('prepare', '--commit', self.git('rev-parse', 'HEAD'), '--output', self.output, success=False)
        self.git('checkout', self.commit, '--', 'LICENSE')
        self.git('commit', '-m', 'restore license')
        self.git('checkout', '--orphan', 'foreign')
        self.git('commit', '-m', 'foreign root')
        self.git('checkout', 'main')
        self.git('merge', 'foreign', '--allow-unrelated-histories', '-m', 'foreign merge')
        self.cli('prepare', '--commit', self.git('rev-parse', 'HEAD'), '--output', self.output, success=False)

    def test_failed_verification_preserves_incomplete_and_bundle_guard_blocks_finalization(self):
        spec = importlib.util.spec_from_file_location('source_release_fixture', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with patch.object(module, 'verify', side_effect=module.ReleaseError('fixture verification failure')):
            with self.assertRaisesRegex(module.ReleaseError, 'fixture verification failure'):
                module.prepare(self.root, self.commit, self.output)
        incomplete = self.output.with_name('preview.incomplete')
        self.assertTrue((incomplete / self.zip_name).is_file())
        self.assertFalse(self.output.exists())
        self.write('build/Tilvero.app/Contents/MacOS/TilveroApp', 'development')
        second = self.base / 'second'
        with patch.object(module.release, 'bundle_digest', side_effect=['before', 'changed']):
            with self.assertRaisesRegex(module.ReleaseError, 'development bundle'):
                module.prepare(self.root, self.commit, second)
        self.assertFalse(second.exists())
        self.assertTrue(second.with_name('second.incomplete').is_dir())


if __name__ == '__main__':
    unittest.main()
