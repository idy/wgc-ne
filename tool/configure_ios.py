#!/usr/bin/env python3
"""Add a WGC NE PacketTunnel target to an existing Flutter iOS project.

Preserves existing app entitlements and targets. Refuses an existing target or
provider directory; the original project file is backed up before it is changed.
This tool never registers identifiers, changes teams, or signs an application.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import uuid


def new_id():
    return uuid.uuid4().hex[:24].upper()


def openstep(value, level=0):
    indent = '\t' * level
    if isinstance(value, dict):
        return '{\n' + ''.join(indent + '\t' + openstep(str(key)) + ' = ' + openstep(item, level + 1) + ';\n' for key, item in value.items()) + indent + '}'
    if isinstance(value, list):
        return '(\n' + ''.join(indent + '\t' + openstep(item, level + 1) + ',\n' for item in value) + indent + ')'
    text = str(value)
    return text if re.fullmatch(r'[A-Za-z0-9_./]+', text) else json.dumps(text, ensure_ascii=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', required=True, type=Path, help='Path to Runner.xcodeproj')
    parser.add_argument('--core', required=True, type=Path, help='Built WGCCore.xcframework')
    parser.add_argument('--provider-id', help='Defaults to the app ID plus .PacketTunnel')
    parser.add_argument('--keychain-group', help='Suffix after AppIdentifierPrefix; defaults to app ID plus .wgc-ne')
    parser.add_argument('--target', default='WGCPacketTunnel')
    parser.add_argument('--sdk', type=Path, help='Optional local SDK checkout; default is GitHub v0.1.0')
    args = parser.parse_args()
    project = args.project.resolve()
    core = args.core.resolve()
    root = Path(__file__).resolve().parents[1]
    project_file = project / 'project.pbxproj'
    ios = project.parent
    if not project_file.is_file() or not (core / 'Info.plist').is_file():
        parser.error('Xcode project and built WGCCore.xcframework are required')
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*', args.target):
        parser.error('Invalid target name')
    data = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project_file)]))
    objects = data['objects']
    owner = objects[data['rootObject']]
    runners = [identifier for identifier in owner['targets'] if objects[identifier].get('name') == 'Runner']
    if len(runners) != 1:
        parser.error('Expected exactly one Runner target')
    if any(objects[identifier].get('name') == args.target for identifier in owner['targets']):
        parser.error('Target already exists; existing integration was left unchanged')
    app_id = runners[0]
    app = objects[app_id]
    app_configs = objects[app['buildConfigurationList']]['buildConfigurations']
    release = next((objects[c] for c in app_configs if objects[c]['name'] == 'Release'), objects[app_configs[0]])
    bundle = release['buildSettings']['PRODUCT_BUNDLE_IDENTIFIER']
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle):
        parser.error('Runner needs a concrete bundle identifier')
    provider = args.provider_id or bundle + '.PacketTunnel'
    if not provider.startswith(bundle + '.') or not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', provider):
        parser.error('Provider identifier must belong to Runner')
    keychain = args.keychain_group or bundle + '.wgc-ne'
    if not re.fullmatch(r'[A-Za-z0-9.-]+', keychain):
        parser.error('Keychain group must be a suffix without a team prefix or variables')
    shared_group = '$(AppIdentifierPrefix)' + keychain
    folder = ios / args.target
    backup = project_file.with_name('project.pbxproj.wgc-ne-backup')
    if folder.exists() or backup.exists():
        parser.error('Provider directory or backup exists; no files changed')
    adapter = root / 'apple/GoAdapter/WGCCoreEngine.swift'
    if not adapter.is_file():
        parser.error('Go adapter source is missing')

    def add(isa, **fields):
        identifier = new_id()
        objects[identifier] = {'isa': isa, **fields}
        return identifier

    source_ref = add('PBXFileReference', lastKnownFileType='sourcecode.swift', path='PacketTunnelProvider.swift', sourceTree='<group>')
    adapter_ref = add('PBXFileReference', lastKnownFileType='sourcecode.swift', path='WGCCoreEngine.swift', sourceTree='<group>')
    info_ref = add('PBXFileReference', lastKnownFileType='text.plist.xml', path='Info.plist', sourceTree='<group>')
    entitlement_ref = add('PBXFileReference', lastKnownFileType='text.plist.entitlements', path='PacketTunnel.entitlements', sourceTree='<group>')
    config_ref = add('PBXFileReference', lastKnownFileType='text.xcconfig', path='Core.xcconfig', sourceTree='<group>')
    group = add('PBXGroup', path=args.target, sourceTree='<group>', children=[source_ref, adapter_ref, info_ref, entitlement_ref, config_ref])
    objects[owner['mainGroup']]['children'].append(group)
    core_ref = add('PBXFileReference', lastKnownFileType='wrapper.xcframework', path=os.path.relpath(core, ios), sourceTree='SOURCE_ROOT')
    objects[owner['mainGroup']]['children'].append(core_ref)
    product_ref = add('PBXFileReference', explicitFileType='wrapper.app-extension', path=args.target + '.appex', sourceTree='BUILT_PRODUCTS_DIR', includeInIndex='0')
    objects[owner['productRefGroup']]['children'].append(product_ref)
    if args.sdk:
        sdk_path = args.sdk.resolve()
        if not (sdk_path / 'Package.swift').is_file():
            parser.error('Local SDK Package.swift is missing')
        package_ref = add('XCLocalSwiftPackageReference', relativePath=os.path.relpath(sdk_path, ios))
    else:
        package_ref = add('XCRemoteSwiftPackageReference', repositoryURL='https://github.com/idy/wgc-ne.git', requirement={'kind': 'exactVersion', 'version': '0.1.0'})
    owner.setdefault('packageReferences', []).append(package_ref)
    package_product = add('XCSwiftPackageProductDependency', package=package_ref, productName='WGCNE')
    sources = add('PBXSourcesBuildPhase', buildActionMask='2147483647', runOnlyForDeploymentPostprocessing='0', files=[add('PBXBuildFile', fileRef=source_ref), add('PBXBuildFile', fileRef=adapter_ref)])
    frameworks = add('PBXFrameworksBuildPhase', buildActionMask='2147483647', runOnlyForDeploymentPostprocessing='0', files=[add('PBXBuildFile', fileRef=core_ref), add('PBXBuildFile', productRef=package_product)])
    resources = add('PBXResourcesBuildPhase', buildActionMask='2147483647', runOnlyForDeploymentPostprocessing='0', files=[])
    configurations = []
    entitlement_updates = {}
    for reference in app_configs:
        original = objects[reference]
        settings = original['buildSettings']
        entitlement_path = settings.get('CODE_SIGN_ENTITLEMENTS', 'Runner/Runner.entitlements')
        entitlement_path = entitlement_path.removeprefix('$(SRCROOT)/')
        path = (ios / entitlement_path).resolve()
        if ios not in path.parents:
            parser.error('App entitlement path is outside the iOS project')
        current = entitlement_updates.get(path)
        if current is None:
            current = plistlib.loads(path.read_bytes()) if path.exists() else {}
        for key, value in [('keychain-access-groups', shared_group), ('com.apple.developer.networking.networkextension', 'packet-tunnel-provider')]:
            values = current.setdefault(key, [])
            if not isinstance(values, list):
                parser.error('Existing entitlement has an unexpected type')
            if value not in values:
                values.append(value)
        entitlement_updates[path] = current
        settings['CODE_SIGN_ENTITLEMENTS'] = entitlement_path
        minimum = settings.get('IPHONEOS_DEPLOYMENT_TARGET', '0')
        if re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', minimum) and int(minimum.split('.')[0]) < 15:
            settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
        extension = {
            'APPLICATION_EXTENSION_API_ONLY': 'YES', 'CLANG_ENABLE_MODULES': 'YES',
            'CODE_SIGN_STYLE': settings.get('CODE_SIGN_STYLE', 'Automatic'),
            'CODE_SIGN_ENTITLEMENTS': args.target + '/PacketTunnel.entitlements',
            'DEVELOPMENT_TEAM': settings.get('DEVELOPMENT_TEAM', ''),
            'CURRENT_PROJECT_VERSION': '$(FLUTTER_BUILD_NUMBER)',
            'MARKETING_VERSION': '$(FLUTTER_BUILD_NAME)',
            'GENERATE_INFOPLIST_FILE': 'NO', 'INFOPLIST_FILE': args.target + '/Info.plist',
            'IPHONEOS_DEPLOYMENT_TARGET': '15.0', 'PRODUCT_BUNDLE_IDENTIFIER': provider,
            'PRODUCT_NAME': '$(TARGET_NAME)', 'SKIP_INSTALL': 'YES',
            'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator', 'SWIFT_VERSION': '5.0',
            'TARGETED_DEVICE_FAMILY': '1,2',
            'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks'],
            'OTHER_LDFLAGS': ['$(inherited)', '-framework', 'NetworkExtension', '-framework', 'Foundation', '-framework', 'Security', '-framework', 'CoreFoundation', '-framework', 'UIKit', '-framework', 'Network', '-lresolv'],
        }
        configurations.append(add('XCBuildConfiguration', name=original['name'], baseConfigurationReference=config_ref, buildSettings=extension))
    configuration_list = add('XCConfigurationList', buildConfigurations=configurations, defaultConfigurationIsVisible='0', defaultConfigurationName='Release')
    target = add('PBXNativeTarget', name=args.target, productName=args.target, productReference=product_ref, productType='com.apple.product-type.app-extension', buildConfigurationList=configuration_list, buildPhases=[sources, frameworks, resources], buildRules=[], dependencies=[], packageProductDependencies=[package_product])
    owner['targets'].append(target)
    proxy = add('PBXContainerItemProxy', containerPortal=data['rootObject'], proxyType='1', remoteGlobalIDString=target, remoteInfo=args.target)
    app.setdefault('dependencies', []).append(add('PBXTargetDependency', target=target, targetProxy=proxy))
    embed_file = add('PBXBuildFile', fileRef=product_ref, settings={'ATTRIBUTES': ['RemoveHeadersOnCopy']})
    embed = add('PBXCopyFilesBuildPhase', name='Embed WGC NE', buildActionMask='2147483647', runOnlyForDeploymentPostprocessing='0', dstPath='', dstSubfolderSpec='13', files=[embed_file])
    app['buildPhases'].insert(0, embed)

    folder.mkdir()
    (folder / 'PacketTunnelProvider.swift').write_text('import WGCNE\n\nfinal class PacketTunnelProvider: WGCPacketTunnelProvider {\n    override func makeCoreEngine() throws -> CoreEngine {\n        try WGCCoreEngine()\n    }\n}\n')
    shutil.copyfile(adapter, folder / 'WGCCoreEngine.swift')
    (folder / 'Core.xcconfig').write_text('#include "../Flutter/Generated.xcconfig"\n')
    info = {'CFBundleDevelopmentRegion': '$(DEVELOPMENT_LANGUAGE)', 'CFBundleExecutable': '$(EXECUTABLE_NAME)', 'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)', 'CFBundleInfoDictionaryVersion': '6.0', 'CFBundleName': '$(PRODUCT_NAME)', 'CFBundlePackageType': 'XPC!', 'CFBundleShortVersionString': '$(MARKETING_VERSION)', 'CFBundleVersion': '$(CURRENT_PROJECT_VERSION)', 'NSExtension': {'NSExtensionPointIdentifier': 'com.apple.networkextension.packet-tunnel', 'NSExtensionPrincipalClass': '$(PRODUCT_MODULE_NAME).PacketTunnelProvider'}}
    (folder / 'Info.plist').write_bytes(plistlib.dumps(info))
    (folder / 'PacketTunnel.entitlements').write_bytes(plistlib.dumps({'com.apple.developer.networking.networkextension': ['packet-tunnel-provider'], 'keychain-access-groups': [shared_group]}))
    for path, entitlements in entitlement_updates.items():
        if path.exists():
            shutil.copyfile(path, path.with_suffix(path.suffix + '.wgc-ne-backup'))
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(entitlements))
    shutil.copyfile(project_file, backup)
    project_file.write_text('// !$*UTF8*$!\n' + openstep(data) + '\n')
    subprocess.run(['plutil', '-lint', str(project_file)], check=True)
    print('Added ' + provider)
    print('Runtime Keychain group: resolve AppIdentifierPrefix + ' + keychain)
    print('Both targets still require your provisioning/signing configuration.')


if __name__ == '__main__':
    main()
