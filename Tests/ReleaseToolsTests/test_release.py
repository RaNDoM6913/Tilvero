import importlib.util
import json
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('release', Path(__file__).resolve().parents[2] / 'scripts/release.py')
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
ROOT = Path(__file__).resolve().parents[2]

class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = json.loads((ROOT/'Config/Release.json').read_text())

    def manifest(self,assets):
        import zipfile
        if not any(x['name'].endswith('.dmg') for x in assets):
            p=self.root/'Tilvero-0.1.0-beta.1-arm64-TEST.dmg';p.write_bytes(b'image');assets.append(release.asset_record(p))
        if not any(x['name'].endswith('-source.zip') for x in assets):
            p=self.root/'Tilvero-0.1.0-beta.1-source.zip'
            with zipfile.ZipFile(p,'w') as z:
                z.comment=b'a'*40;z.writestr('Tilvero/LICENSE','fixture')
            assets.append(release.asset_record(p))
        c=dict(self.config);c.pop('publicBaseline')
        return dict(c,schemaVersion=1,signingMode='adhoc',notarization='not-requested',downloadedInstall='unverified',publicationReady=False,commit='a'*40,toolchain='fixture',assets=assets)

    def app(self):
        app = self.root/'Tilvero.app'; (app/'Contents/MacOS').mkdir(parents=True)
        exe = app/'Contents/MacOS/TilveroApp'; exe.write_bytes(b'fixture'); exe.chmod(0o755)
        info = dict(CFBundleIdentifier=self.config['bundleID'], CFBundleExecutable='TilveroApp', CFBundleShortVersionString='0.1.0',CFBundleVersion='1',LSMinimumSystemVersion='26.0',CFBundleIconFile='AppIcon',TilveroDataScope='production',TilveroReleaseMode='monitoring')
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        for p in release.REQUIRED_RESOURCES:
            dest = app/'Contents/Resources'/p; dest.parent.mkdir(parents=True,exist_ok=True); dest.write_bytes(b'fixture')
        return app

    def test_inventory_requires_all_legal_and_icon_resources(self):
        app=self.app(); release.validate_inventory(app,self.config)
        (app/'Contents/Resources/Legal/LICENSE').unlink()
        with self.assertRaisesRegex(release.ReleaseError,'resource'): release.validate_inventory(app,self.config)

    def test_inventory_rejects_helper_and_wrong_identity_or_os(self):
        app=self.app(); helper=app/'Contents/Library/HelperTools'; helper.mkdir(parents=True)
        with self.assertRaisesRegex(release.ReleaseError,'helper'): release.validate_inventory(app,self.config)
        helper.rmdir()
        for key,value in [('CFBundleIdentifier','local.tilvero.prototype'),('LSMinimumSystemVersion','25.0'),('TilveroDataScope','prototype')]:
            path=app/'Contents/Info.plist'; original=plistlib.loads(path.read_bytes()); changed=dict(original);changed[key]=value;path.write_bytes(plistlib.dumps(changed))
            with self.assertRaises(release.ReleaseError): release.validate_inventory(app,self.config)
            path.write_bytes(plistlib.dumps(original))

    def test_unexpected_nested_code_is_rejected(self):
        app=self.app();(app/'Contents/Resources/extra.dylib').write_bytes(b'\xcf\xfa\xed\xfeunexpected code')
        with self.assertRaisesRegex(release.ReleaseError,'nested'):release.validate_inventory(app,self.config)

    def test_arch_and_minos_are_checked_from_executable(self):
        def runner(args): return 'x86_64' if args[0]=='lipo' else 'minos 26.0'
        with self.assertRaisesRegex(release.ReleaseError,'architecture'): release.validate_macho(Path('fixture'),self.config,runner)
        def wrong_os(args): return 'arm64' if args[0]=='lipo' else 'minos 25.0'
        with self.assertRaisesRegex(release.ReleaseError,'minimum'): release.validate_macho(Path('fixture'),self.config,wrong_os)

    def test_public_mode_has_no_adhoc_fallback(self):
        with self.assertRaisesRegex(release.ReleaseError,'Team'): release.validate_signing(self.config,'developer-id',None)
        release.validate_signing(self.config,'adhoc',None)
        c=dict(self.config,teamID='ABCDEFGHIJ')
        for identity in [None,'-','Apple Development: Test']:
            with self.assertRaises(release.ReleaseError): release.validate_signing(c,'developer-id',identity)

    def git(self,*args): return subprocess.check_output(['git','-C',str(self.root),*args],stderr=subprocess.DEVNULL,text=True).strip()
    def test_admission_rejects_dirty_and_ignores_untracked_inputs(self):
        self.git('init','-b','main'); self.git('config','user.name','Fixture');self.git('config','user.email','fixture@example.invalid')
        (self.root/'Config').mkdir(); (self.root/'Config/Release.json').write_text(json.dumps(self.config))
        (self.root/'LICENSE').write_text('fixture');self.git('add','Config','LICENSE');self.git('commit','-m','fixture')
        commit=self.git('rev-parse','HEAD');self.config['publicBaseline']=commit
        # Public baseline is injected for a fixture repository, never inferred from HEAD.
        (self.root/'private-untracked.swift').write_text('never archive me')
        release.admit_source(self.root,commit,self.config,require_config_match=False)
        archive=self.root/'source.tar'; release.export_source(self.root,commit,archive)
        import tarfile
        with tarfile.open(archive) as t: self.assertNotIn('private-untracked.swift',t.getnames())
        (self.root/'LICENSE').write_text('dirty')
        with self.assertRaisesRegex(release.ReleaseError,'dirty'):release.admit_source(self.root,commit,self.config,require_config_match=False)

    def test_final_verifier_rejects_fabricated_commit_and_stale_checksums(self):
        manifest=self.manifest([]);path=self.root/'release.json';path.write_text(json.dumps(manifest))
        (self.root/'SHA256SUMS').write_text('fabricated checksums')
        with self.assertRaises(release.ReleaseError):release.verify_manifest(path)

    def test_checksum_file_must_bind_every_final_file(self):
        manifest=self.manifest([]);path=self.root/'release.json';path.write_text(json.dumps(manifest))
        checks=self.root/'SHA256SUMS';checks.write_text('stale')
        with self.assertRaisesRegex(release.ReleaseError,'checksum'):release.verify_checksum_file(path,manifest)
        paths=[self.root/x['name'] for x in manifest['assets']]+[path]
        checks.write_text(''.join(f'{release.sha(p)}  {p.name}\n' for p in paths))
        release.verify_checksum_file(path,manifest)
        checks.write_text(checks.read_text()+'extra\n')
        with self.assertRaises(release.ReleaseError):release.verify_checksum_file(path,manifest)

    def test_incomplete_or_misbound_manifest_rejected(self):
        path=self.root/'release.json';path.write_text(json.dumps(dict(schemaVersion=1,commit='a'*40,assets=[])))
        with self.assertRaisesRegex(release.ReleaseError,'manifest'):release.verify_records(path)
        m=self.manifest([]);m['tag']='v9.0.0';path.write_text(json.dumps(m))
        with self.assertRaisesRegex(release.ReleaseError,'Tag'):release.verify_records(path)

    def test_invalid_packaging_inputs_leave_no_output(self):
        output=self.root/'should-not-exist.dmg'
        result=subprocess.run(['bash',str(ROOT/'scripts/package-dmg.sh'),'--app',str(self.root/'absent.app'),'--metadata',str(self.root/'absent.json'),'--output',str(output),'--signing-mode','adhoc'],capture_output=True)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(output.exists())

    def test_wrong_source_zip_commit_rejected(self):
        import zipfile
        payload=self.root/'Tilvero-0.1.0-beta.1-source.zip'
        with zipfile.ZipFile(payload,'w') as z:
            z.comment=b'b'*40;z.writestr('Tilvero/LICENSE','fixture')
        manifest=self.manifest([release.asset_record(payload)])
        path=self.root/'release.json';path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(release.ReleaseError,'commit'):release.verify_records(path)

    def test_stale_embedded_metadata_rejected(self):
        app=self.app()
        # Inspect metadata independently from OS codesign in this fixture.
        from unittest.mock import patch
        with patch.object(release,'validate_macho'),patch.object(release,'run',return_value=''):
            with self.assertRaisesRegex(release.ReleaseError,'Stale'):
                release.validate_app(app,self.config,dict(commit='a'*40))

    def test_reused_build_and_nonempty_output_are_rejected(self):
        p=self.root/'build/releases/old';p.mkdir(parents=True)
        (p/'release.json').write_text(json.dumps(dict(build='1',tag='v0.1.0-beta.1')))
        with self.assertRaisesRegex(release.ReleaseError,'build'):
            release.check_prior_builds(self.root,self.config)

    def test_manifest_detects_changed_asset_and_untrusted_public_claim(self):
        payload=self.root/'Tilvero-0.1.0-beta.1-arm64-TEST.dmg';payload.write_bytes(b'image')
        manifest=self.manifest([release.asset_record(payload)])
        path=self.root/'release.json';path.write_text(json.dumps(manifest));release.verify_records(path)
        payload.write_bytes(b'tampered')
        with self.assertRaisesRegex(release.ReleaseError,'hash|size'):release.verify_records(path)
        payload.write_bytes(b'image');manifest['publicationReady']=True;path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(release.ReleaseError,'trusted'):release.verify_records(path)

if __name__=='__main__':unittest.main()
