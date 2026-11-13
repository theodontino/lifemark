import contextlib
import datetime as dt
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import tempfile
import types
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('resign_install', Path(__file__).with_name('resign_install.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class ResignTests(unittest.TestCase):
    def test_does_not_select_a_different_phone(self):
        document = {'result': {'devices': [{'identifier': 'other', 'properties': {'hardware': {'deviceType': 'iPhone', 'reality': 'physical'}}}]}}
        with self.assertRaises(module.RenewalError):
            module.select_device(document, 'configured-phone', 'iPhone')

    def test_rejects_wrong_app_and_unregistered_device(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp)
            (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'another.app'}))
            with self.assertRaisesRegex(module.RenewalError, '标识'):
                module.validate_app(app, 'local.liferecord.ios', 'team', 'phone')
            (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'local.liferecord.ios'}))
            profile = {'TeamIdentifier': ['team'], 'ProvisionedDevices': ['different-phone'], 'ExpirationDate': dt.datetime(2099, 1, 1)}
            (app / 'embedded.mobileprovision').write_bytes(b'CMS-prefix' + plistlib.dumps(profile) + b'CMS-suffix')
            with self.assertRaisesRegex(module.RenewalError, '未包含'):
                module.validate_app(app, 'local.liferecord.ios', 'team', 'phone')

    def exercise(self, check=False, fail_build=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'LifeRecord.xcodeproj').mkdir()
            config = root / 'config.json'
            config.write_text(json.dumps({'phone_udid': 'phone', 'team_id': 'team'}))
            commands = []
            def fake_run(command, log=None, env=None):
                commands.append(command)
                if command[:2] == ['security', 'find-identity']:
                    return 'Apple Development: Test'
                if command[1:4] == ['devicectl', 'list', 'devices']:
                    return json.dumps({'result': {'devices': [{'identifier': 'phone', 'properties': {'hardware': {'deviceType': 'iPhone', 'reality': 'physical'}}}]}})
                if 'details' in command:
                    return json.dumps({'result': {'device': {'properties': {'connection': {'state': 'connected'}}}}})
                if command[0] == 'xcodebuild' and '-scheme' in command and fail_build:
                    raise module.RenewalError('模拟构建失败')
                return ''
            paths = {'build': root / 'build', 'packages': root / 'packages', 'cache': root / 'cache'}
            with patch.object(module, 'ROOT', root), patch.object(module, 'CONFIG', config), patch.object(module, 'run', side_effect=fake_run), patch.object(module, 'paths_and_env', return_value=(paths, {})), patch.object(module, 'validate_app'), patch.object(module, 'profile_expiry', return_value=dt.datetime(2099, 1, 1, tzinfo=dt.timezone.utc)), contextlib.redirect_stdout(io.StringIO()):
                args = types.SimpleNamespace(check=check, watch=False)
                if fail_build:
                    with self.assertRaises(module.RenewalError):
                        module.workflow(args)
                else:
                    module.workflow(args)
            self.assertFalse((root / '.resign-install.lock').exists())
            return commands

    def test_check_never_builds_or_installs(self):
        commands = self.exercise(check=True)
        self.assertFalse(any('-scheme' in command or 'install' in command for command in commands))

    def test_build_failure_does_not_install_and_releases_lock(self):
        commands = self.exercise(fail_build=True)
        self.assertFalse(any('install' in command for command in commands))

    def test_success_only_installs_configured_phone_without_uninstall(self):
        commands = self.exercise()
        installs = [c for c in commands if 'install' in c]
        self.assertEqual(len(installs), 1)
        self.assertEqual(installs[0][installs[0].index('--device') + 1], 'phone')
        self.assertFalse(any('uninstall' in c for c in commands))
        self.assertLess(next(i for i,c in enumerate(commands) if '-scheme' in c), commands.index(installs[0]))

if __name__ == '__main__':
    unittest.main()
