#!/usr/bin/env python3
"""Generate a dependency-free Xcode project from the same Swift sources as SwiftPM."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parent.parent
objects = {}

def ref(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def add(name, value):
    objects[ref(name)] = value
    return ref(name)

def quote(value):
    return json.dumps(str(value))

def encode(value):
    if isinstance(value, dict):
        return '{ ' + ' '.join(f'{quote(k)} = {encode(v)};' for k, v in value.items()) + ' }'
    if isinstance(value, list):
        return '( ' + ', '.join(encode(v) for v in value) + (',' if value else '') + ' )'
    return quote(value)

files = {}
for path in sorted((root / 'Sources').rglob('*.swift')):
    relative = str(path.relative_to(root))
    files[relative] = add(relative, dict(isa='PBXFileReference', lastKnownFileType='sourcecode.swift', path=relative, sourceTree='<group>'))
icon = add('Icon', dict(isa='PBXFileReference', lastKnownFileType='image.icns', path='Resources/AirPlayer.icns', sourceTree='<group>'))
plist = add('Info', dict(isa='PBXFileReference', lastKnownFileType='text.plist.xml', path='Resources/Info.plist', sourceTree='<group>'))
app_product = add('AppProduct', dict(isa='PBXFileReference', explicitFileType='wrapper.application', path='AirPlayer.app', sourceTree='BUILT_PRODUCTS_DIR'))
cli_product = add('CLIProduct', dict(isa='PBXFileReference', explicitFileType='compiled.mach-o.executable', path='airplayer', sourceTree='BUILT_PRODUCTS_DIR'))
products = add('Products', dict(isa='PBXGroup', children=[app_product, cli_product], name='Products', sourceTree='<group>'))
main_group = add('MainGroup', dict(isa='PBXGroup', children=list(files.values()) + [plist, icon, products], sourceTree='<group>'))

common = dict(MACOSX_DEPLOYMENT_TARGET='14.0', SWIFT_VERSION='6.0', SDKROOT='macosx', CLANG_ENABLE_MODULES='YES')

def config_list(name, extra):
    ids = []
    for config in ['Debug', 'Release']:
        settings = dict(common, **extra)
        settings['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone' if config == 'Debug' else '-O'
        if config == 'Debug':
            settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
        ids.append(add(name + config, dict(isa='XCBuildConfiguration', name=config, buildSettings=settings)))
    return add(name + 'Configurations', dict(isa='XCConfigurationList', buildConfigurations=ids, defaultConfigurationIsVisible='0', defaultConfigurationName='Release'))

project_configs = config_list('Project', {})
app_configs = config_list('App', dict(PRODUCT_NAME='AirPlayer', PRODUCT_MODULE_NAME='AirPlayerApp', EXECUTABLE_NAME='AirPlayerApp', INFOPLIST_FILE='Resources/Info.plist', PRODUCT_BUNDLE_IDENTIFIER='app.airplayer.mac', CODE_SIGN_STYLE='Automatic', ENABLE_HARDENED_RUNTIME='YES', COMBINE_HIDPI_IMAGES='YES', ENABLE_USER_SCRIPT_SANDBOXING='NO'))
cli_configs = config_list('CLI', dict(PRODUCT_NAME='airplayer', PRODUCT_MODULE_NAME='AirPlayerCLI', CODE_SIGN_STYLE='Automatic', ENABLE_HARDENED_RUNTIME='YES', SKIP_INSTALL='YES'))

def source_phase(name, folders):
    builds = []
    for path, file_ref in files.items():
        if any(path.startswith('Sources/' + folder + '/') for folder in folders):
            builds.append(add(name + path, dict(isa='PBXBuildFile', fileRef=file_ref)))
    return add(name + 'Sources', dict(isa='PBXSourcesBuildPhase', buildActionMask='2147483647', files=builds, runOnlyForDeploymentPostprocessing='0'))

cli_target = ref('CLITarget')
proxy = add('CLIProxy', dict(isa='PBXContainerItemProxy', containerPortal=ref('Project'), proxyType='1', remoteGlobalIDString=cli_target, remoteInfo='airplayer'))
dependency = add('CLIDependency', dict(isa='PBXTargetDependency', target=cli_target, targetProxy=proxy))
embedded = add('EmbeddedCLI', dict(isa='PBXBuildFile', fileRef=cli_product, settings=dict(ATTRIBUTES=['CodeSignOnCopy'])))
copy = add('CopyCLI', dict(isa='PBXCopyFilesBuildPhase', buildActionMask='2147483647', dstPath='', dstSubfolderSpec='6', files=[embedded], name='Embed CLI', runOnlyForDeploymentPostprocessing='0'))
add('CLITarget', dict(isa='PBXNativeTarget', buildConfigurationList=cli_configs, buildPhases=[source_phase('CLI', ['AirPlayerCore', 'AirPlayerCLI'])], buildRules=[], dependencies=[], name='airplayer', productName='airplayer', productReference=cli_product, productType='com.apple.product-type.tool'))
icon_build = add('IconBuild', dict(isa='PBXBuildFile', fileRef=icon))
resources = add('AppResources', dict(isa='PBXResourcesBuildPhase', buildActionMask='2147483647', files=[icon_build], runOnlyForDeploymentPostprocessing='0'))
commit_phase = add('BuildCommit', dict(isa='PBXShellScriptBuildPhase', buildActionMask='2147483647', files=[],
    name='Stamp Git commit', inputPaths=[], outputPaths=['$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/BuildCommit.txt'],
    alwaysOutOfDate='1', runOnlyForDeploymentPostprocessing='0', shellPath='/bin/bash',
    shellScript='bash "$SRCROOT/scripts/write-build-commit.sh" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/BuildCommit.txt"\n'))
app_target = add('AppTarget', dict(isa='PBXNativeTarget', buildConfigurationList=app_configs, buildPhases=[source_phase('App', ['AirPlayerCore', 'AirPlayerApp']), resources, copy, commit_phase], buildRules=[], dependencies=[dependency], name='AirPlayer', productName='AirPlayer', productReference=app_product, productType='com.apple.product-type.application'))
add('Project', dict(isa='PBXProject', attributes=dict(LastUpgradeCheck='1600'), buildConfigurationList=project_configs, compatibilityVersion='Xcode 14.0', developmentRegion='en', hasScannedForEncodings='0', knownRegions=['en', 'Base'], mainGroup=main_group, productRefGroup=products, projectDirPath='', projectRoot='', targets=[app_target, cli_target]))
project = root / 'AirPlayer.xcodeproj'
project.mkdir(exist_ok=True)
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + encode(dict(archiveVersion='1', classes={}, objectVersion='56', objects=objects, rootObject=ref('Project'))) + '\n')
schemes = project / 'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
(schemes / 'AirPlayer.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
   <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="AirPlayer.app" BlueprintName="AirPlayer" ReferencedContainer="container:AirPlayer.xcodeproj"/>
  </BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES">
  <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="AirPlayer.app" BlueprintName="AirPlayer" ReferencedContainer="container:AirPlayer.xcodeproj"/></BuildableProductRunnable>
 </LaunchAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(project)
