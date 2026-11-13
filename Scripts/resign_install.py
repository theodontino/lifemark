#!/usr/bin/env python3
"""LifeRecord local development signing; never uninstall or reset app data."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / 'Scripts' / 'resign-config.json'

class RenewalError(Exception):
    pass

def run(command, log=None, env=None):
    if log:
        with log.open('w') as output:
            result = subprocess.run(command, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RenewalError(f'这一步没有完成，请查看日志：{log}')
        return ''
    result = subprocess.run(command, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()[-2200:]
        raise RenewalError(detail or '命令执行失败。')
    return result.stdout

def hardware(device):
    return device.get('properties', {}).get('hardware', device.get('hardwareProperties', {}))

def select_device(document, device_id, kind):
    rows = document.get('result', {}).get('devices', [])
    matches = [d for d in rows if device_id in (d.get('identifier'), hardware(d).get('udid'))]
    if len(matches) != 1:
        raise RenewalError('没有找到配置中的设备。请连接并解锁设备，不会自动改装到其他设备。')
    device = matches[0]
    if hardware(device).get('reality') == 'simulated' or hardware(device).get('deviceType') != kind:
        raise RenewalError('设备类型不匹配，已停止；不会安装到其他设备。')
    return device

def profile_expiry(app):
    raw = (app / 'embedded.mobileprovision').read_bytes()
    begin = raw.index(b'<?xml')
    end = raw.index(b'</plist>', begin) + len(b'</plist>')
    return plistlib.loads(raw[begin:end])['ExpirationDate'].replace(tzinfo=dt.timezone.utc)

def validate_app(app, bundle, team, device_id=None):
    with (app / 'Info.plist').open('rb') as stream:
        actual = plistlib.load(stream).get('CFBundleIdentifier')
    if actual != bundle:
        raise RenewalError('安装包标识与人生记录不一致，已停止，避免覆盖其他 App。')
    raw = (app / 'embedded.mobileprovision').read_bytes()
    begin = raw.index(b'<?xml'); end = raw.index(b'</plist>', begin) + len(b'</plist>')
    profile = plistlib.loads(raw[begin:end])
    if team not in profile.get('TeamIdentifier', []):
        raise RenewalError('安装包签名账号不一致，已停止。')
    if device_id and device_id not in profile.get('ProvisionedDevices', []):
        raise RenewalError('签名未包含这台设备，不能安装。请保持设备解锁，在 Xcode 中检查账号与设备注册。')
    if profile_expiry(app) <= dt.datetime.now(dt.timezone.utc):
        raise RenewalError('苹果仍返回已过期的签名，请在 Xcode → Settings → Accounts 检查账号登录后再试。')
    run(['codesign', '--verify', '--deep', '--strict', str(app)])

def build_command(scheme, device, paths, team):
    return ['xcodebuild', '-project', str(ROOT / 'LifeRecord.xcodeproj'), '-scheme', scheme,
            '-destination', f'id={device}', '-destination-timeout', '20',
            '-derivedDataPath', str(paths['build']), '-clonedSourcePackagesDirPath', str(paths['packages']),
            '-packageCachePath', str(paths['cache']), '-skipMacroValidation', '-skipPackagePluginValidation',
            '-allowProvisioningUpdates', '-allowProvisioningDeviceRegistration',
            'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_STYLE=Automatic', f'DEVELOPMENT_TEAM={team}', 'build']

def paths_and_env():
    # Reuse this Mac's existing caches when present; otherwise use a dedicated cache.
    base = Path.home() / 'Library' / 'Caches' / 'LifeRecordResign'
    def existing(old, fallback):
        p = Path('/private/tmp') / old
        return p if p.exists() else base / fallback
    paths = {'build': existing('liferecord-ios-xcode', 'Build'),
             'packages': existing('liferecord-xcode-packages', 'Packages'),
             'cache': existing('liferecord-fast-cache', 'PackageCache')}
    env = os.environ.copy()
    module_cache = existing('liferecord-module-cache', 'ModuleCache')
    env['CLANG_MODULE_CACHE_PATH'] = str(module_cache)
    env['SWIFTPM_MODULECACHE_OVERRIDE'] = str(module_cache)
    # Temporary source mirrors are an optional local speedup, never a required dependency.
    mirror = Path('/private/tmp/liferecord-test-mirrors.json')
    if mirror.exists():
        try:
            entries = json.loads(mirror.read_text())['object']
            if entries and all(e['mirror'].startswith('file://') and Path(e['mirror'][7:]).exists() for e in entries):
                env['SWIFTPM_MIRROR_CONFIG'] = str(mirror)
            else:
                env.pop('SWIFTPM_MIRROR_CONFIG', None)
        except (ValueError, KeyError, TypeError):
            env.pop('SWIFTPM_MIRROR_CONFIG', None)
    else:
        env.pop('SWIFTPM_MIRROR_CONFIG', None)
    return paths, env

def workflow(args):
    config = json.loads(CONFIG.read_text())
    phone, team = config['phone_udid'], config['team_id']
    bundle = 'local.liferecord.ios'
    if not (ROOT / 'LifeRecord.xcodeproj').is_dir():
        raise RenewalError('没有找到完整 Xcode 工程。请从完整项目目录运行。')
    run(['xcodebuild', '-version'])
    identities = run(['security', 'find-identity', '-v', '-p', 'codesigning'])
    if 'Apple Development:' not in identities:
        raise RenewalError('本机没有有效开发签名。请打开 Xcode → Settings → Accounts 登录原 Apple 账号。')
    devices = json.loads(run(['xcrun', 'devicectl', 'list', 'devices', '--json-output', '-']))
    targets = [(phone, 'iPhone')]
    if args.watch:
        targets.append((config['watch_udid'], 'appleWatch'))
    for identifier, kind in targets:
        select_device(devices, identifier, kind)
        details = json.loads(run(['xcrun', 'devicectl', 'device', 'info', 'details', '--device', identifier,
                                  '--timeout', '20', '--json-output', '-']))
        device = details.get('result', {})
        # devicectl versions expose device details either directly or under device.
        device = device.get('device', device)
        connection = device.get('properties', {}).get('connection', device.get('connectionProperties', {}))
        state = connection.get('state')
        if state and state != 'connected':
            raise RenewalError(f'{kind} 尚未连接。请解锁并靠近 Mac；手表连接失败时，用数据线连接配对 iPhone。')
    print('设备与本机开发签名检查完成。', flush=True)
    if args.check:
        print('这是只检查模式，没有编译、重新签名或安装。')
        return
    logs = ROOT / 'validation' / 'resign' / dt.datetime.now().strftime('%Y%m%d-%H%M%S')
    logs.mkdir(parents=True, exist_ok=True)
    paths, env = paths_and_env()
    # No simultaneous renewal processes may build or install from the same products directory.
    lock = ROOT / '.resign-install.lock'
    try:
        lock.mkdir()
    except FileExistsError:
        raise RenewalError('另一个重新安装任务可能还在运行。若上次被强行关闭，请确认它已停止，再移除项目中的 .resign-install.lock 文件夹。')
    try:
        watch_app = paths['build'] / 'Build/Products/Debug-watchos/LifeRecordWatch.app'
        if args.watch:
            print('正在为真实手表构建签名；请保持手表解锁…', flush=True)
            run(build_command('LifeRecordWatch', config['watch_udid'], paths, team), logs / 'watch-build.log', env)
            validate_app(watch_app, bundle + '.watch', team, config['watch_udid'])
        print('正在重新编译并签名。首次可能较久，后续会利用缓存…', flush=True)
        run(build_command('LifeRecordiOS', phone, paths, team), logs / 'phone-build.log', env)
        app = paths['build'] / 'Build/Products/Debug-iphoneos/LifeRecord.app'
        validate_app(app, bundle, team, phone)
        print('正在覆盖安装到 iPhone；不卸载、不清空记录…', flush=True)
        run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', phone, str(app), '--timeout', '120'], logs / 'phone-install.log')
        if args.watch:
            # Validate the embedded copy after the phone build before direct watch installation.
            embedded = app / 'Watch/LifeRecordWatch.app'
            validate_app(embedded, bundle + '.watch', team, config['watch_udid'])
            run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', config['watch_udid'], str(embedded), '--timeout', '120'], logs / 'watch-install.log')
        expiry = profile_expiry(app).astimezone(dt.timezone(dt.timedelta(hours=8)))
        print(f'安装成功。手机签名有效至：{expiry:%Y年%m月%d日 %H:%M}（北京时间）')
        print('苹果可能复用仍有效的描述文件；上面显示的是实际期限，不保证每次运行都会延长7天。')
        print(f'日志：{logs}')
        print('请打开手机上的人生记录，确认原记录还在。')
        print('若提示不受信任：设置 → 通用 → VPN与设备管理 → 信任原开发者。')
    finally:
        lock.rmdir()

def main():
    parser = argparse.ArgumentParser(description='人生记录：使用本机原 Apple 开发账号重新签名并覆盖安装，保留本机记录。')
    parser.add_argument('--check', action='store_true', help='仅检查工具、签名和设备，不编译或安装')
    parser.add_argument('--watch', action='store_true', help='同时构建和安装已建立开发连接的真实手表；默认只更新手机')
    args = parser.parse_args()
    try:
        workflow(args)
        return 0
    except (RenewalError, OSError, ValueError, KeyError) as error:
        print(f'\n暂未完成：{error}', file=sys.stderr)
        print('先检查：设备解锁并连接；Xcode里原账号仍登录；网络可用。不要卸载App，也不要改App标识或签名团队。', file=sys.stderr)
        if args.watch:
            print('手表若提示蓝牙开发连接被拒绝，请用数据线把配对iPhone接到Mac；不要解除手表配对。', file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print('\n已停止。未执行卸载或清空数据。', file=sys.stderr)
        return 130

if __name__ == '__main__':
    sys.exit(main())
