import contextlib
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import configure_ios


class ConfigureIOSTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='wgc-ne-setup-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.ios = self.root / 'ios'
        self.project = self.ios / 'Runner.xcodeproj'
        self.project.mkdir(parents=True)
        self.project_file = self.project / 'project.pbxproj'
        self.core = self.root / 'WGCCore.xcframework'
        self.core.mkdir()
        (self.core / 'Info.plist').write_bytes(plistlib.dumps({}))
        self.original_entitlements = {
            'aps-environment': 'development',
            'com.apple.security.application-groups': ['group.example.existing'],
            'keychain-access-groups': ['TEAM.existing'],
        }
        self.write_entitlements('Runner/Runner.entitlements')
        self.effective = {
            name: {
                'PRODUCT_BUNDLE_IDENTIFIER': 'com.example.app',
                'CODE_SIGN_ENTITLEMENTS': 'Runner/Runner.entitlements',
                'DEVELOPMENT_TEAM': 'EXISTINGTEAM',
                'IPHONEOS_DEPLOYMENT_TARGET': '15.0',
            }
            for name in ('Debug', 'Release')
        }
        self.data = {
            'archiveVersion': '1', 'objectVersion': '54', 'classes': {},
            'rootObject': 'PROJECT',
            'objects': {
                'PROJECT': {
                    'isa': 'PBXProject', 'targets': ['APP'],
                    'mainGroup': 'MAIN', 'productRefGroup': 'PRODUCTS',
                },
                'MAIN': {'isa': 'PBXGroup', 'children': []},
                'PRODUCTS': {'isa': 'PBXGroup', 'children': []},
                'APP': {
                    'isa': 'PBXNativeTarget', 'name': 'Runner',
                    'buildConfigurationList': 'CONFIGS', 'buildPhases': [],
                },
                'CONFIGS': {
                    'isa': 'XCConfigurationList',
                    'buildConfigurations': ['DEBUG', 'RELEASE'],
                },
                **{
                    name.upper(): {
                        'isa': 'XCBuildConfiguration', 'name': name,
                        'buildSettings': {'PRODUCT_BUNDLE_IDENTIFIER': 'com.example.app'},
                    }
                    for name in ('Debug', 'Release')
                },
            },
        }
        self.save_project()

    def save_project(self):
        self.project_file.write_bytes(plistlib.dumps(self.data))

    def write_entitlements(self, relative):
        path = self.ios / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(self.original_entitlements))
        return path

    def snapshot(self):
        return {path.relative_to(self.root): path.read_bytes()
                for path in self.root.rglob('*') if path.is_file()}

    def run_setup(self, *options, resolver=None):
        arguments = [
            'configure_ios.py', '--project', str(self.project), '--core', str(self.core),
            '--sdk', str(Path(__file__).resolve().parents[1]), *options,
        ]
        resolve = resolver or (lambda project, configuration: self.effective[configuration])
        with mock.patch.object(sys, 'argv', arguments), \
                mock.patch.object(configure_ios, 'load_build_settings', side_effect=resolve), \
                contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            configure_ios.main()

    def generated_project(self):
        return json.loads(subprocess.check_output([
            'plutil', '-convert', 'json', '-o', '-', str(self.project_file),
        ]))

    def assert_merged(self, relative):
        result = plistlib.loads((self.ios / relative).read_bytes())
        for key, value in self.original_entitlements.items():
            if key != 'keychain-access-groups':
                self.assertEqual(result[key], value)
        self.assertEqual(result['keychain-access-groups'], [
            'TEAM.existing', '$(AppIdentifierPrefix)com.example.app.wgc-ne',
        ])
        self.assertIn('packet-tunnel-provider', result['com.apple.developer.networking.networkextension'])

    def assert_refused_without_writes(self, *options, resolver=None):
        before = self.snapshot()
        with self.assertRaises(SystemExit) as error:
            self.run_setup(*options, resolver=resolver)
        self.assertEqual(error.exception.code, 2)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.ios / 'WGCPacketTunnel').exists())

    def test_provider_identifiers_follow_each_effective_app_configuration(self):
        self.effective['Debug']['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.example.app.debug'
        self.data['objects']['DEBUG']['buildSettings']['PRODUCT_BUNDLE_IDENTIFIER'] = '$(APP_BUNDLE_ID)'
        self.save_project()
        self.run_setup()
        data = self.generated_project()
        objects = data['objects']
        target = next(value for value in objects.values()
                      if value.get('isa') == 'PBXNativeTarget' and value.get('name') == 'WGCPacketTunnel')
        configurations = objects[target['buildConfigurationList']]['buildConfigurations']
        identifiers = {objects[reference]['name']: objects[reference]['buildSettings']['PRODUCT_BUNDLE_IDENTIFIER']
                       for reference in configurations}
        self.assertEqual(identifiers, {
            'Debug': 'com.example.app.debug.PacketTunnel',
            'Release': 'com.example.app.PacketTunnel',
        })
        self.assertEqual(objects['DEBUG']['buildSettings']['PRODUCT_BUNDLE_IDENTIFIER'], '$(APP_BUNDLE_ID)')
        for reference in configurations:
            self.assertEqual(objects[reference]['buildSettings']['DEVELOPMENT_TEAM'], 'EXISTINGTEAM')
        self.assert_merged('Runner/Runner.entitlements')

    def test_explicit_provider_must_belong_to_every_configuration(self):
        self.effective['Debug']['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.example.app.debug'
        self.assert_refused_without_writes('--provider-id', 'com.example.app.PacketTunnel')

    def test_inherited_entitlements_are_merged_without_replacing_existing_capabilities(self):
        self.write_entitlements('Runner/Production.entitlements')
        untouched = (self.ios / 'Runner/Runner.entitlements').read_bytes()
        for settings in self.effective.values():
            settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Production.entitlements'
        self.run_setup()
        self.assert_merged('Runner/Production.entitlements')
        self.assertEqual((self.ios / 'Runner/Runner.entitlements').read_bytes(), untouched)
        objects = self.generated_project()['objects']
        for reference in ('DEBUG', 'RELEASE'):
            self.assertNotIn('CODE_SIGN_ENTITLEMENTS', objects[reference]['buildSettings'])

    def test_default_entitlements_are_selected_only_when_effective_setting_is_unset(self):
        for settings in self.effective.values():
            settings.pop('CODE_SIGN_ENTITLEMENTS')
        self.run_setup()
        self.assert_merged('Runner/Runner.entitlements')
        objects = self.generated_project()['objects']
        for reference in ('DEBUG', 'RELEASE'):
            self.assertEqual(objects[reference]['buildSettings']['CODE_SIGN_ENTITLEMENTS'],
                             'Runner/Runner.entitlements')

    def assert_resolved_root_variable(self, variable):
        for reference in ('DEBUG', 'RELEASE'):
            self.data['objects'][reference]['buildSettings']['CODE_SIGN_ENTITLEMENTS'] = variable + '/Runner/Runner.entitlements'
        self.save_project()
        for settings in self.effective.values():
            settings['CODE_SIGN_ENTITLEMENTS'] = str(self.ios / 'Runner/Runner.entitlements')
        self.run_setup()
        self.assert_merged('Runner/Runner.entitlements')
        self.assertFalse((self.ios / variable).exists())
        objects = self.generated_project()['objects']
        self.assertEqual(objects['DEBUG']['buildSettings']['CODE_SIGN_ENTITLEMENTS'],
                         variable + '/Runner/Runner.entitlements')

    def test_srcroot_brace_variable_uses_the_effective_file(self):
        self.assert_resolved_root_variable('${SRCROOT}')

    def test_project_dir_variable_uses_the_effective_file(self):
        self.assert_resolved_root_variable('$(PROJECT_DIR)')

    def test_configuration_variable_preserves_both_entitlement_files(self):
        for name in ('Debug', 'Release'):
            self.write_entitlements('Runner/' + name + '.entitlements')
            self.effective[name]['CODE_SIGN_ENTITLEMENTS'] = 'Runner/' + name + '.entitlements'
            self.data['objects'][name.upper()]['buildSettings']['CODE_SIGN_ENTITLEMENTS'] = 'Runner/$(CONFIGURATION).entitlements'
        self.save_project()
        self.run_setup()
        for name in ('Debug', 'Release'):
            self.assert_merged('Runner/' + name + '.entitlements')
        self.assertFalse((self.ios / 'Runner/$(CONFIGURATION).entitlements').exists())

    def test_unresolved_entitlement_path_is_rejected_before_writes(self):
        self.effective['Release']['CODE_SIGN_ENTITLEMENTS'] = 'Runner/$(UNRESOLVED).entitlements'
        self.assert_refused_without_writes()

    def test_effective_entitlement_path_cannot_leave_the_project(self):
        self.effective['Release']['CODE_SIGN_ENTITLEMENTS'] = '../outside.entitlements'
        self.assert_refused_without_writes()

    def test_build_setting_resolution_failure_is_rejected_before_writes(self):
        def fail(project, configuration):
            raise ValueError('Unavailable build settings')
        self.assert_refused_without_writes(resolver=fail)

    def test_build_setting_query_selects_runner_from_multiple_targets(self):
        result = subprocess.CompletedProcess([], 0, stdout=json.dumps([
            {'target': 'Other', 'buildSettings': {'PRODUCT_BUNDLE_IDENTIFIER': 'com.other'}},
            {'target': 'Runner', 'buildSettings': self.effective['Release']},
        ]))
        with mock.patch.object(configure_ios.subprocess, 'run', return_value=result):
            self.assertEqual(configure_ios.load_build_settings(self.project, 'Release'), self.effective['Release'])


if __name__ == '__main__':
    unittest.main()
