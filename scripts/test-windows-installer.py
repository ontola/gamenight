"""Exercise a real Velopack install and the production update/data/process helpers.
Uses a unique test app ID, private feed and disposable data, never GameNight's install.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import uuid


def wait_for(predicate, message, seconds=60):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    raise RuntimeError(message)


def run(*args, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed ({result.returncode}):\n{result.stdout}\n{result.stderr}')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--vpk', default='vpk')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    stage, installed, data = root / 'stage', root / 'installed', root / 'data'
    stage.mkdir()
    data.mkdir()
    shutil.copy2(args.binary, stage / 'Smoke.exe')
    (stage / 'pinpals').mkdir()
    (stage / 'pinpals/main.lua').write_text('original content')
    app_id = 'GameNightSmoke.' + uuid.uuid4().hex
    for version in ['1.0.0', '2.0.0']:
        (stage / 'version.txt').write_text(version)
        run(args.vpk, 'pack', '--packId', app_id, '--packVersion', version,
            '--packDir', str(stage), '--mainExe', 'Smoke.exe', '--channel', 'win-test',
            '--shortcuts', 'None', '--outputDir', str(root / version))
    setup = next((root / '1.0.0').glob('*Setup.exe'))
    run(str(setup), '--silent', '--installto', str(installed))
    exe = installed / 'current/Smoke.exe'
    wait_for(exe.is_file, 'Installation did not produce Smoke.exe')
    (data / 'settings.json').write_text('preserve this setting')
    env = dict(os.environ, GAMENIGHT_DATA_DIR=str(data))

    def start(feed):
        for name in ['exit', 'running.json', 'children-closed', 'updater.log']:
            (data / name).unlink(missing_ok=True)
        env['GAMENIGHT_SMOKE_FEED'] = str(feed)
        process = subprocess.Popen([str(exe)], env=env, creationflags=subprocess.CREATE_NO_WINDOW)
        wait_for(lambda: (data / 'running.json').is_file(), 'Installed app failed to start')
        report = json.loads((data / 'running.json').read_text())
        return process, report

    def log_contains(text):
        log = data / 'updater.log'
        return log.exists() and text in log.read_text()

    def close(process, report):
        (data / 'exit').write_text('exit')
        process.wait(timeout=30)
        assert (data / 'children-closed').is_file(), 'Update began before process cleanup'
        # tasklist reports only the exact fixture child PID; unrelated processes are untouched.
        out = run('tasklist', '/FI', f"PID eq {report['child']}", '/FO', 'CSV', '/NH').stdout
        assert f'"{report["child"]}"' not in out, 'Hidden child survived shutdown'

    try:
        process, report = start(root / 'offline-feed')
        assert report['version'] == '1.0.0'
        wait_for(lambda: log_contains('skipped'), 'Offline update did not fail gracefully')
        close(process, report)
        # A failed checksum must leave the installed app intact.
        corrupt = root / 'corrupt-feed'
        shutil.copytree(root / '2.0.0', corrupt)
        for package in corrupt.glob('*.nupkg'):
            package.write_bytes(b'broken download')
        process, report = start(corrupt)
        wait_for(lambda: log_contains('skipped'), 'Corrupt download was not rejected')
        close(process, report)
        assert (installed / 'current/version.txt').read_text() == '1.0.0'
        process, report = start(root / '2.0.0')
        wait_for(lambda: log_contains('Update downloaded'), 'Update was not downloaded')
        assert report['version'] == '1.0.0'
        assert (installed / 'current/version.txt').read_text() == '1.0.0', 'Updated during play'
        close(process, report)
        wait_for(lambda: (installed / 'current/version.txt').is_file() and
                 (installed / 'current/version.txt').read_text() == '2.0.0', 'Update was not applied on exit')
        process, report = start(root / '2.0.0')
        assert report['version'] == '2.0.0'
        assert (data / 'settings.json').read_text() == 'preserve this setting'
        assert (Path(report['content']) / 'main.lua').read_text() == 'original content'
        close(process, report)
        print('PASS: install, offline start, corrupt download, deferred update, restart, data preservation, child cleanup')
    finally:
        # Scope cleanup to the uniquely identified fixture installation only.
        if 'process' in locals() and process.poll() is None:
            (data / 'exit').write_text('exit')
            process.wait(timeout=30)
        if (installed / 'Update.exe').exists():
            run(str(installed / 'Update.exe'), 'uninstall', '--silent')


if __name__ == '__main__':
    main()
