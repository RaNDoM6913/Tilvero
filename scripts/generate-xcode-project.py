#!/usr/bin/env python3
"""Generate the committed Xcode graph from local sources; no external packages/tools."""
from pathlib import Path
import hashlib, json
root = Path(__file__).resolve().parent.parent
objects = {}
def ident(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def add(object_name, **value):
    key=ident(object_name); objects[key]=value; return key
def ref(path, kind='sourcecode.swift', source='<group>'):
    return add('file:'+path, isa='PBXFileReference', lastKnownFileType=kind, path=path, sourceTree=source)
def build(name, file): return add('build:'+name, isa='PBXBuildFile', fileRef=file)
appFiles=[ref(str(p.relative_to(root))) for p in sorted((root/'Sources/TilveroApp').glob('*.swift'))]
helperFiles=[ref(str(p.relative_to(root))) for p in sorted((root/'Helper').glob('*.swift'))]
resource=ref('Sources/TilveroApp/Resources/Localizable.xcstrings','text.json')
notices=ref('Helper/THIRD_PARTY_NOTICES.md','net.daringfireball.markdown')
appProduct=ref('Tilvero.app','wrapper.application','BUILT_PRODUCTS_DIR')
helperProduct=ref('TilveroHelper','compiled.mach-o.executable','BUILT_PRODUCTS_DIR')
productGroup=add('products',isa='PBXGroup',children=[appProduct,helperProduct],name='Products',sourceTree='<group>')
mainGroup=add('mainGroup',isa='PBXGroup',children=appFiles+helperFiles+[resource,notices,productGroup],sourceTree='<group>')
package=add('package',isa='XCLocalSwiftPackageReference',relativePath='.')
def configs(name,extra):
    rows=[]
    for mode in ['Debug','Release']:
        settings=dict(SDKROOT='macosx',ARCHS='arm64',ONLY_ACTIVE_ARCH='YES',MACOSX_DEPLOYMENT_TARGET='26.0',SWIFT_VERSION='6.0',CLANG_ENABLE_MODULES='YES',ENABLE_HARDENED_RUNTIME='YES',CODE_SIGN_STYLE='Manual',CODE_SIGN_IDENTITY='-',SWIFT_STRICT_CONCURRENCY='complete',SWIFT_OPTIMIZATION_LEVEL='-Onone' if mode=='Debug' else '-O',**extra)
        rows.append(add(name+mode,isa='XCBuildConfiguration',name=mode,buildSettings=settings))
    return add(name+'configs',isa='XCConfigurationList',buildConfigurations=rows,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
def target(name,files,product,productType,libs,extra,phases=None):
    deps=[add(name+':'+lib,isa='XCSwiftPackageProductDependency',productName=lib) for lib in libs]
    framework=add(name+'frameworks',isa='PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[add(name+'link'+lib,isa='PBXBuildFile',productRef=dep) for lib,dep in zip(libs,deps)],runOnlyForDeploymentPostprocessing=0)
    sources=add(name+'sources',isa='PBXSourcesBuildPhase',buildActionMask=2147483647,files=[build(name+file,file) for file in files],runOnlyForDeploymentPostprocessing=0)
    return add(name,isa='PBXNativeTarget',name=name,productName=name,productReference=product,productType=productType,buildConfigurationList=configs(name,extra),buildPhases=[sources,framework]+(phases or []),buildRules=[],dependencies=[],packageProductDependencies=deps)
helper=target('TilveroHelper',helperFiles,helperProduct,'com.apple.product-type.tool',['PowerPrivileged'],{'PRODUCT_BUNDLE_IDENTIFIER':'local.tilvero.prototype.helper','PRODUCT_NAME':'TilveroHelper','SKIP_INSTALL':'YES','CREATE_INFOPLIST_SECTION_IN_BINARY':'YES','INFOPLIST_FILE':'Config/HelperInfo.plist'})
resources=add('resources',isa='PBXResourcesBuildPhase',buildActionMask=2147483647,files=[build('catalog',resource),build('notices',notices)],runOnlyForDeploymentPostprocessing=0)
embedHelper=add('embedHelper',isa='PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath='Contents/Library/HelperTools',dstSubfolderSpec=1,files=[build('embedHelper',helperProduct)],name='Embed helper',runOnlyForDeploymentPostprocessing=0)
launchFiles=[]
for path in sorted((root/'Config/LaunchDaemons').glob('*.plist')):
    file=ref(str(path.relative_to(root)),'text.plist.xml'); objects[mainGroup]['children'].append(file); launchFiles.append(build('daemon'+path.name,file))
embedJobs=add('embedJobs',isa='PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath='Contents/Library/LaunchDaemons',dstSubfolderSpec=1,files=launchFiles,name='Embed launch jobs',runOnlyForDeploymentPostprocessing=0)
app=target('Tilvero',appFiles,appProduct,'com.apple.product-type.application',['PowerCore','PowerTelemetry','PowerPersistence','PowerDiagnostics','PowerSimulator','PowerPrivileged','ChargeBackends','FanBackends'],{'PRODUCT_BUNDLE_IDENTIFIER':'local.tilvero.prototype','PRODUCT_NAME':'Tilvero','EXECUTABLE_NAME':'TilveroApp','INFOPLIST_FILE':'Config/Info.plist','GENERATE_INFOPLIST_FILE':'NO','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/../Frameworks'},[resources,embedHelper,embedJobs])
proxy=add('helperProxy',isa='PBXContainerItemProxy',containerPortal=ident('project'),proxyType=1,remoteGlobalIDString=helper,remoteInfo='TilveroHelper')
objects[app]['dependencies']=[add('helperDependency',isa='PBXTargetDependency',target=helper,targetProxy=proxy)]
project=add('project',isa='PBXProject',attributes={'LastUpgradeCheck':'2700'},buildConfigurationList=configs('project',{}),compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings=0,knownRegions=['en','ru','Base'],mainGroup=mainGroup,productRefGroup=productGroup,projectDirPath='',projectRoot='',targets=[app,helper],packageReferences=[package])
def emit(value, depth=0):
    if isinstance(value,dict): return '{\n'+''.join('\t'*(depth+1)+str(k)+' = '+emit(v,depth+1)+';\n' for k,v in value.items())+'\t'*depth+'}'
    if isinstance(value,list): return '('+', '.join(emit(v,depth) for v in value)+')'
    if isinstance(value,int): return str(value)
    return json.dumps(value,ensure_ascii=False)
p=root/'Tilvero.xcodeproj/project.pbxproj';p.parent.mkdir(exist_ok=True)
p.write_text('// !$*UTF8*$!\n'+emit(dict(archiveVersion=1,classes={},objectVersion=56,objects=objects,rootObject=project))+'\n')
for name,key,productName in [('Tilvero',app,'Tilvero.app'),('TilveroHelper',helper,'TilveroHelper')]:
    scheme=f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{key}" BuildableName="{productName}" BlueprintName="{name}" ReferencedContainer="container:Tilvero.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug"/><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{key}" BuildableName="{productName}" BlueprintName="{name}" ReferencedContainer="container:Tilvero.xcodeproj"/></BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>'''
    out=root/f'Tilvero.xcodeproj/xcshareddata/xcschemes/{name}.xcscheme';out.parent.mkdir(parents=True,exist_ok=True);out.write_text(scheme+'\n')
print(p)
