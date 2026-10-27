#!/usr/bin/env python3
"""Source-bound, offline-by-default release preparation. Never publishes or creates tags."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REQUIRED_RESOURCES = ('AppIcon.icns', 'Legal/LICENSE', 'Legal/COPYRIGHT', 'Legal/THIRD_PARTY_NOTICES.md', 'Legal/Helper/THIRD_PARTY_NOTICES.md')
FORBIDDEN = ('AGENTS.md','planning/','docs/evidence/','docs/HANDOFF.md','docs/IMPLEMENTATION_STATUS.md','docs/VALIDATION.md','build/','.env','history/','runtime/')
class ReleaseError(Exception): pass

def run(args):
    try: return subprocess.check_output([str(x) for x in args], stderr=subprocess.PIPE,text=True).strip()
    except subprocess.CalledProcessError as e: raise ReleaseError(f'{args[0]} failed: {e.stderr[-2500:]}') from e

def git(root,*args): return run(['git','-C',root,*args])
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def write_json(path,value): path.write_text(json.dumps(value,indent=2,sort_keys=True)+'\n')
def bundle_digest(path):
    h=hashlib.sha256()
    for p in sorted(path.rglob('*')):
        h.update(str(p.relative_to(path)).encode())
        if p.is_symlink():h.update(os.readlink(p).encode())
        elif p.is_file():h.update(p.read_bytes())
    return h.hexdigest()

def asset_record(path): return dict(name=path.name,size=path.stat().st_size,sha256=sha(path))

def load_config(path):
    return load_config_data(json.loads(Path(path).read_text()))

def load_config_data(c):
    expected={'architecture':'arm64','minimumOS':'26.0','mode':'monitoring','bundleID':'io.github.random6913.tilvero','helperID':'io.github.random6913.tilvero.helper','guardianID':'io.github.random6913.tilvero.guardian'}
    for key,value in expected.items():
        if c.get(key)!=value: raise ReleaseError(f'Unsupported release {key}')
    if not re.fullmatch(r'\d+\.\d+\.\d+',c.get('version','')) or not re.fullmatch(r'[1-9]\d*',c.get('build','')): raise ReleaseError('Invalid version/build')
    suffix='-beta.' if c['channel']=='beta' else None
    if c['channel'] not in ('beta','stable') or not re.fullmatch(r'v'+re.escape(c['version'])+(r'-beta\.[1-9]\d*' if suffix else ''),c['tag']): raise ReleaseError('Tag/channel mismatch')
    return c

def validate_signing(config,mode,identity):
    if mode=='adhoc':
        if identity: raise ReleaseError('Ad-hoc mode does not accept a signing identity')
        return
    if not re.fullmatch(r'[A-Z0-9]{10}',config.get('teamID') or ''): raise ReleaseError('Developer ID requires an owner-supplied Team ID')
    if not identity or not identity.startswith('Developer ID Application: ') or not identity.endswith('('+config['teamID']+')'): raise ReleaseError('A matching Developer ID Application identity is required')
    if identity not in run(['security','find-identity','-v','-p','codesigning']): raise ReleaseError('Signing identity is unavailable')

def admit_source(root,commit,config,require_config_match=True):
    if not re.fullmatch(r'[0-9a-f]{40}',commit) or git(root,'rev-parse',commit+'^{commit}')!=commit: raise ReleaseError('An exact full commit is required')
    if git(root,'status','--porcelain','--untracked-files=no'): raise ReleaseError('Tracked source is dirty')
    if git(root,'rev-parse','HEAD')!=commit: raise ReleaseError('Admitted commit must be current HEAD')
    git(root,'merge-base','--is-ancestor',config['publicBaseline'],commit)
    if git(root,'rev-list','--parents','-n','1',config['publicBaseline']).split()!=[config['publicBaseline']]: raise ReleaseError('Public baseline must be parentless')
    if len(git(root,'rev-list','--max-parents=0',commit).splitlines())!=1: raise ReleaseError('Private/foreign ancestry is not admitted')
    paths=git(root,'ls-tree','-r','--name-only',commit).splitlines()
    for p in paths:
        if any(p==f or p.startswith(f) for f in FORBIDDEN) or p.endswith(('.sqlite','.p12','.pem','.key')): raise ReleaseError('Private source path rejected: '+p)
    if require_config_match and json.loads(git(root,'show',commit+':Config/Release.json'))!=config: raise ReleaseError('Release config differs from committed source')
    if config['tag'] in git(root,'tag','--list').splitlines(): raise ReleaseError('Tag already used; use a fresh version/build')

def export_source(root,commit,path):
    if path.exists(): raise ReleaseError('Source archive destination exists')
    run(['git','-C',root,'archive','--format=tar','--output',path,commit])

def validate_inventory(app,c):
    try: info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    except Exception as e: raise ReleaseError('Missing/invalid Info.plist') from e
    expected=dict(CFBundleIdentifier=c['bundleID'],CFBundleExecutable='TilveroApp',CFBundleShortVersionString=c['version'],CFBundleVersion=c['build'],LSMinimumSystemVersion=c['minimumOS'],TilveroDataScope='production',TilveroReleaseMode='monitoring',CFBundleIconFile='AppIcon')
    for key,value in expected.items():
        if info.get(key)!=value: raise ReleaseError('App metadata mismatch: '+key)
    executable=app/'Contents/MacOS/TilveroApp'
    if not executable.is_file() or not os.access(executable,os.X_OK): raise ReleaseError('Missing executable/permissions')
    for p in REQUIRED_RESOURCES:
        resource=app/'Contents/Resources'/p
        if not resource.is_file() or resource.stat().st_size==0: raise ReleaseError('Missing resource: '+p)
    if (app/'Contents/Library').exists(): raise ReleaseError('Monitoring package contains helper/service contents')
    if any(k.startswith('TilveroHelper') or k=='SMPrivilegedExecutables' for k in info): raise ReleaseError('Monitoring package contains helper trust metadata')
    for p in app.rglob('*'):
        if p.is_symlink(): raise ReleaseError('Unexpected app symlink')
        if p.is_file() and p!=executable:
            with p.open('rb') as f: magic=f.read(4)
            if magic in (b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca'):raise ReleaseError('Unexpected nested executable code')
    return info

def validate_macho(executable,c,runner=run):
    if runner(['lipo','-archs',executable]).split()!=[c['architecture']]: raise ReleaseError('Wrong executable architecture')
    output=runner(['xcrun','vtool','-show-build',executable])
    if not re.search(r'\bminos\s+'+re.escape(c['minimumOS'])+r'\b',output): raise ReleaseError('Wrong executable minimum OS')

def validate_app(app,c,metadata=None,public=False):
    validate_inventory(app,c); validate_macho(app/'Contents/MacOS/TilveroApp',c)
    run(['codesign','--verify','--deep','--strict',app])
    entitlements=run(['codesign','-d','--entitlements',':-',app])
    if '<key>com.apple.security.get-task-allow</key>' in entitlements and '<true/>' in entitlements: raise ReleaseError('Debug entitlement rejected')
    if metadata is not None:
        path=app/'Contents/Resources/ReleaseMetadata.json'
        if not path.is_file() or json.loads(path.read_text())!=metadata: raise ReleaseError('Stale release metadata')
    if metadata is not None and metadata.get('signingMode')=='adhoc':
        display=subprocess.run(['codesign','-dv','--verbose=4',str(app)],capture_output=True,text=True,check=True).stderr
        if 'Signature=adhoc' not in display:raise ReleaseError('TEST app is not ad-hoc signed as recorded')
    if public:
        # codesign writes display information to stderr.
        p=subprocess.run(['codesign','-dv','--verbose=4',str(app)],capture_output=True,text=True,check=True)
        out=p.stderr
        if 'Authority=Developer ID Application:' not in out or 'TeamIdentifier='+c['teamID'] not in out or 'runtime' not in out or 'Timestamp=' not in out: raise ReleaseError('Developer ID/runtime/timestamp verification failed')

def verify_records(path):
    manifest=json.loads(path.read_text())
    required={'schemaVersion','commit','tag','version','build','channel','architecture','minimumOS','bundleID','toolchain','signingMode','notarization','downloadedInstall','publicationReady','assets','mode','teamID','helperID','guardianID'}
    allowed=required|{'createdAt'}
    if not required <= set(manifest) or set(manifest)-allowed:raise ReleaseError('Incomplete/unknown manifest fields')
    config=load_config_data(manifest)
    if manifest['signingMode'] not in ('adhoc','developer-id') or manifest['notarization'] not in ('not-requested','accepted-stapled') or manifest['downloadedInstall'] not in ('unverified','accepted') or type(manifest['publicationReady']) is not bool:raise ReleaseError('Invalid manifest distribution state')
    if manifest['signingMode']=='adhoc' and manifest['notarization']!='not-requested':raise ReleaseError('Ad-hoc artifact cannot claim notarization')
    assets=manifest['assets']
    if not isinstance(assets,list) or len(assets)!=2 or sum(x.get('name','').endswith('.dmg') for x in assets)!=1 or sum(x.get('name','').endswith('-source.zip') for x in assets)!=1:raise ReleaseError('Manifest must bind one DMG and matching source ZIP')
    if manifest.get('schemaVersion')!=1 or not re.fullmatch(r'[0-9a-f]{40}',manifest.get('commit','')): raise ReleaseError('Invalid manifest source binding')
    if manifest.get('publicationReady') and (manifest.get('signingMode')!='developer-id' or manifest.get('notarization')!='accepted-stapled' or manifest.get('downloadedInstall')!='accepted'): raise ReleaseError('No trusted downloaded-install acceptance')
    expected_names={'Tilvero-'+manifest['tag'][1:]+'-arm64'+('-TEST' if manifest['signingMode']=='adhoc' else '')+'.dmg','Tilvero-'+manifest['tag'][1:]+'-source.zip'}
    if {x.get('name') for x in assets}!=expected_names:raise ReleaseError('Manifest asset name/tag mismatch')
    names=set()
    for asset in manifest['assets']:
        if set(asset)!={'name','size','sha256'} or type(asset['size']) is not int or asset['size']<=0 or not re.fullmatch(r'[0-9a-f]{64}',asset['sha256']):raise ReleaseError('Invalid manifest asset record')
        name=asset['name']
        if Path(name).name!=name or name in names: raise ReleaseError('Invalid/duplicate asset name')
        names.add(name);p=path.parent/name
        if not p.is_file() or p.stat().st_size!=asset['size'] or sha(p)!=asset['sha256']: raise ReleaseError('Asset hash/size mismatch: '+name)
        if name.endswith('-source.zip'):
            with zipfile.ZipFile(p) as z:
                if z.comment.decode()!=manifest['commit']:raise ReleaseError('Source ZIP commit mismatch')
                for entry in z.namelist():
                    relative=entry[len('Tilvero/'):] if entry.startswith('Tilvero/') else entry
                    if not entry.startswith('Tilvero/') or '..' in Path(entry).parts or any(relative==f or relative.startswith(f) for f in FORBIDDEN):raise ReleaseError('Unexpected private source ZIP path')
                if 'Tilvero/LICENSE' not in z.namelist():raise ReleaseError('Missing source license')
    return manifest

def verify_source_zip(path,commit):
    # Compare the complete archive contents/permissions to the immutable Git tree;
    # a ZIP comment or LICENSE presence alone is not corresponding-source proof.
    if git(ROOT,'rev-parse',commit+'^{commit}')!=commit:raise ReleaseError('Source commit unavailable')
    baseline=load_config(ROOT/'Config/Release.json')['publicBaseline']
    git(ROOT,'merge-base','--is-ancestor',baseline,commit)
    if git(ROOT,'rev-list','--parents','-n','1',baseline).split()!=[baseline] or len(git(ROOT,'rev-list','--max-parents=0',commit).splitlines())!=1:raise ReleaseError('Source archive has private/foreign ancestry')
    with tempfile.TemporaryDirectory(prefix='tilvero-source-verify-') as tmp:
        expected=Path(tmp)/'source.zip'
        run(['git','-C',ROOT,'archive','--format=zip','--prefix=Tilvero/','--output',expected,commit])
        with zipfile.ZipFile(path) as actual,zipfile.ZipFile(expected) as target:
            if len(actual.namelist())!=len(set(actual.namelist())) or sorted(actual.namelist())!=sorted(target.namelist()):raise ReleaseError('Source archive tree mismatch')
            for name in target.namelist():
                if actual.read(name)!=target.read(name) or actual.getinfo(name).external_attr!=target.getinfo(name).external_attr:raise ReleaseError('Source archive content/permissions mismatch')

def verify_checksum_file(path,manifest):
    files=[path.parent/x['name'] for x in manifest['assets']]+[path]
    expected={f'{sha(p)}  {p.name}' for p in files}
    checks=path.parent/'SHA256SUMS'
    if not checks.is_file():raise ReleaseError('Missing final checksum file')
    lines=checks.read_text().splitlines()
    if len(lines)!=len(expected) or set(lines)!=expected:raise ReleaseError('Final checksum file mismatch')

def manifest_metadata(manifest):
    keys=('commit','tag','version','build','channel','bundleID','minimumOS','architecture','mode','toolchain','signingMode')
    return {key:manifest[key] for key in keys}

def verify_manifest(path):
    manifest=verify_records(path)
    source=next(path.parent/x['name'] for x in manifest['assets'] if x['name'].endswith('-source.zip'))
    verify_source_zip(source,manifest['commit'])
    verify_checksum_file(path,manifest)
    dmg=next(path.parent/x['name'] for x in manifest['assets'] if x['name'].endswith('.dmg'))
    public=manifest['signingMode']=='developer-id'
    if public:
        if manifest['notarization']!='accepted-stapled':raise ReleaseError('Developer ID image is not finalized')
        run(['xcrun','stapler','validate',dmg])
        run(['spctl','--assess','--type','open','--context','context:primary-signature',dmg])
    inspect_dmg(dmg,manifest,manifest_metadata(manifest),public)
    return manifest

def mount_matches(devices,mount):
    return any(x.get('mount-point') and Path(x['mount-point']).resolve()==mount.resolve() for x in devices)

def inspect_dmg(path,c,metadata,public=False):
    """Mount read-only, inspect actual image, copy app and verify sealed contents."""
    run(['codesign','--verify','--strict',path])
    with tempfile.TemporaryDirectory(prefix='tilvero-inspect-') as tmp:
        mount=Path(tmp)/'mount'; mount.mkdir()
        attached=False
        try:
            out=run(['hdiutil','attach','-readonly','-nobrowse','-mountpoint',mount,'-plist',path]);attached=True
            devices=plistlib.loads(out.encode()).get('system-entities',[])
            if not mount_matches(devices,mount): raise ReleaseError('Image did not mount at inspection point')
            # diskutil proves the mounted volume is read-only, not just the command flag.
            disk=plistlib.loads(run(['diskutil','info','-plist',mount]).encode())
            if disk.get('WritableVolume') is not False: raise ReleaseError('Mounted image is not read-only')
            names={p.name for p in mount.iterdir()}
            if not {'Tilvero.app','Applications','INSTALL.txt','Legal','.VolumeIcon.icns'} <= names or names-{'Tilvero.app','Applications','INSTALL.txt','Legal','.VolumeIcon.icns','.fseventsd','.Trashes','.DS_Store'}: raise ReleaseError('Unexpected DMG inventory')
            link=mount/'Applications'
            if not link.is_symlink() or os.readlink(link)!='/Applications': raise ReleaseError('Invalid Applications shortcut')
            validate_app(mount/'Tilvero.app',c,metadata,public)
            copied=Path(tmp)/'Tilvero.app';run(['ditto',mount/'Tilvero.app',copied]);validate_app(copied,c,metadata,public)
            # This copy is disposable. Prove a changed sealed resource is rejected.
            with (copied/'Contents/Resources/Legal/COPYRIGHT').open('ab') as f:f.write(b'\nTAMPER TEST\n')
            p=subprocess.run(['codesign','--verify','--strict',str(copied)],capture_output=True)
            if p.returncode==0: raise ReleaseError('Tampered bundle unexpectedly verified')
        finally:
            if attached:run(['hdiutil','detach',mount])

def check_prior_builds(root,c):
    for path in (root/'build/releases').glob('*/release.json'):
        previous=json.loads(path.read_text())
        if int(previous['build'])>=int(c['build']):raise ReleaseError('Release build number already used locally; increment build')

def preflight(args):
    c=load_config(args.config);validate_signing(c,args.signing_mode,args.identity);admit_source(ROOT,args.commit,c);check_prior_builds(ROOT,c)
    return c

def prepare(args):
    c=preflight(args)
    if args.signing_mode=='developer-id' and not args.notary_profile: raise ReleaseError('Public preparation requires a Keychain notary profile')
    tag=c['tag'];destination=ROOT/'build/releases'/(tag+('-TEST' if args.signing_mode=='adhoc' else ''))
    if destination.exists():raise ReleaseError('Release output already exists; preserve it and use a new build/output')
    development=ROOT/'build/Tilvero.app';before=bundle_digest(development) if development.exists() else None
    destination.parent.mkdir(parents=True,exist_ok=True)
    # Failed work stays .incomplete with no ready filename at the final destination.
    work=destination.with_name(destination.name+'.incomplete')
    if work.exists():raise ReleaseError('Incomplete output already exists; inspect it before retry')
    work.mkdir();archive=work/'source.tar';export_source(ROOT,args.commit,archive)
    source=work/'source';source.mkdir()
    with tarfile.open(archive) as t:
        if any(x.name.startswith('/') or '..' in Path(x.name).parts or x.issym() or x.islnk() for x in t.getmembers()):raise ReleaseError('Unsafe source archive')
        t.extractall(source)
    # All generated input comes from this admitted archive plus the verified commit.
    toolchain=run(['bash','-c','source "$1/scripts/toolchain.sh"; xcodebuild -version; swift --version','tilvero',str(source)])
    metadata=dict(commit=args.commit,tag=tag,version=c['version'],build=c['build'],channel=c['channel'],bundleID=c['bundleID'],minimumOS=c['minimumOS'],architecture=c['architecture'],mode=c['mode'],toolchain=toolchain,signingMode=args.signing_mode)
    write_json(source/'Config/ReleaseMetadata.json',metadata)
    stage=work/'stage';stage.mkdir();app=stage/'Tilvero.app'
    env=dict(os.environ);env['TILVERO_RELEASE_COMMIT']=args.commit
    log=work/'build.log'
    with log.open('w') as f:
        result=subprocess.run(['bash',str(source/'scripts/build-xcode.sh'),'--configuration','Release','--derived-data',str(work/'DerivedData'),'--output',str(app),'--release-config',str(source/'Config/Release.json')],stdout=f,stderr=subprocess.STDOUT,env=env)
    if result.returncode:raise ReleaseError('Release build failed; inspect '+str(log))
    if args.signing_mode=='developer-id':run(['codesign','--force','--options','runtime','--timestamp','--sign',args.identity,app])
    else:run(['codesign','--force','--sign','-',app])
    validate_app(app,c,metadata,args.signing_mode=='developer-id')
    stem='Tilvero-'+tag[1:]+'-arm64'+('-TEST' if args.signing_mode=='adhoc' else '')
    dmg=work/(stem+'.dmg');partial=work/(stem+'.unverified.dmg')
    run(['bash',source/'scripts/package-dmg.sh','--app',app,'--metadata',source/'Config/ReleaseMetadata.json','--output',partial,'--signing-mode',args.signing_mode])
    notary='not-requested'
    if args.signing_mode=='adhoc':run(['codesign','--sign','-',partial])
    if args.signing_mode=='developer-id':
        run(['codesign','--sign',args.identity,'--timestamp',partial])
        response=json.loads(run(['xcrun','notarytool','submit',partial,'--keychain-profile',args.notary_profile,'--wait','--output-format','json']))
        write_json(work/'notary-result.json',response)
        if response.get('status')!='Accepted':raise ReleaseError('Notarization was not Accepted')
        notary_log=run(['xcrun','notarytool','log',response['id'],'--keychain-profile',args.notary_profile]);(work/'notary-log.json').write_text(notary_log)
        run(['xcrun','stapler','staple',partial]);run(['xcrun','stapler','validate',partial]);notary='accepted-stapled'
    inspect_dmg(partial,c,metadata,args.signing_mode=='developer-id');partial.rename(dmg)
    sourcezip=work/('Tilvero-'+tag[1:]+'-source.zip');run(['git','-C',ROOT,'archive','--format=zip','--prefix=Tilvero/','--output',sourcezip,args.commit])
    manifest=dict(schemaVersion=1,**metadata,helperID=c['helperID'],guardianID=c['guardianID'],teamID=c['teamID'],notarization=notary,downloadedInstall='unverified',publicationReady=False,createdAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),assets=[asset_record(dmg),asset_record(sourcezip)])
    manifest_path=work/'release.json';write_json(manifest_path,manifest);verify_records(manifest_path)
    (work/'SHA256SUMS').write_text(''.join(f'{sha(p)}  {p.name}\n' for p in [dmg,sourcezip,manifest_path]))
    verify_source_zip(sourcezip,args.commit);verify_checksum_file(manifest_path,manifest)
    if before is not None and bundle_digest(development)!=before:raise ReleaseError('Existing development executable changed')
    write_json(work/'package-checks.json',dict(developmentBundleUnchanged=True,developmentBundleSHA256=before,readOnlyMount=True,mountedAndCopiedSignatures=True,tamperRejected=True,applicationsShortcut=True,publicInstallAccepted=False))
    work.rename(destination)
    return dict(status='local-test-ready' if args.signing_mode=='adhoc' else 'awaiting-downloaded-install',directory=str(destination),manifest=str(destination/'release.json'),publicationReady=False)

def main():
    parser=argparse.ArgumentParser(description=__doc__);sub=parser.add_subparsers(dest='command',required=True)
    for name in ('preflight','prepare'):
        p=sub.add_parser(name);p.add_argument('--commit',required=True);p.add_argument('--config',default=str(ROOT/'Config/Release.json'));p.add_argument('--signing-mode',choices=['adhoc','developer-id'],required=True);p.add_argument('--identity');p.add_argument('--notary-profile')
    p=sub.add_parser('verify');p.add_argument('--manifest',type=Path,required=True)
    p=sub.add_parser('draft');p.add_argument('--manifest',type=Path,required=True);p.add_argument('--notes',type=Path,required=True)
    args=parser.parse_args()
    try:
        if args.command=='preflight':preflight(args);result=dict(status='preflight-pass',publicationReady=False)
        elif args.command=='prepare':result=prepare(args)
        elif args.command=='verify':verify_manifest(args.manifest);result=dict(status='integrity-pass',publicationReady=False)
        else:
            verify_manifest(args.manifest)
            raise ReleaseError('Draft creation requires separate owner publication admission and trusted downloaded-install evidence; no GitHub write performed')
        print(json.dumps(result,indent=2))
    except (ReleaseError,OSError,ValueError,KeyError,subprocess.SubprocessError) as e:
        print(json.dumps(dict(status='blocked',reason=str(e),publicationReady=False)),file=sys.stderr);return 1
    return 0
if __name__=='__main__':sys.exit(main())
