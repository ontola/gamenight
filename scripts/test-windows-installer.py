"""Exercise a real Velopack install and the production update/data/process helpers.
Uses a unique test app ID, private feed and disposable data, never GameNight's install.
"""
import argparse
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import uuid
from windows_runtime import find_crt


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


class RunningApp:
    """Track the app launched by the installed entry stub, which exits immediately."""
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]

    def __init__(self, pid):
        self.pid = pid
        self.handle = self.kernel.OpenProcess(0x100000 | 0x1000, False, pid)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        self.returncode = None

    def poll(self):
        if self.kernel.WaitForSingleObject(self.handle, 0) == 0:
            code = wintypes.DWORD()
            if not self.kernel.GetExitCodeProcess(self.handle, ctypes.byref(code)):
                raise ctypes.WinError(ctypes.get_last_error())
            self.returncode = code.value
        return self.returncode

    def wait(self, timeout):
        if self.kernel.WaitForSingleObject(self.handle, int(timeout * 1000)) != 0:
            raise RuntimeError('Installed app did not exit')
        return self.poll()

    def __del__(self):
        if self.handle:
            self.kernel.CloseHandle(self.handle)


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
    for library in find_crt().glob('*.dll'):
        shutil.copy2(library, stage / library.name)
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
    exe = installed / 'Smoke.exe'
    wait_for(exe.is_file, 'Installation did not produce Smoke.exe')
    (data / 'settings.json').write_text('preserve this setting')
    env = dict(os.environ, GAMENIGHT_DATA_DIR=str(data))
    session = 0

    def start(feed):
        nonlocal session
        session += 1
        for name in ['exit', 'running.json', 'children-closed', 'updater.log']:
            (data / name).unlink(missing_ok=True)
        env['GAMENIGHT_SMOKE_FEED'] = str(feed)
        with (data / f'process-{session}.log').open('w') as log:
            subprocess.run([str(exe)], env=env, stdout=log, stderr=log, check=True,
                           timeout=10, creationflags=subprocess.CREATE_NO_WINDOW)
        wait_for(lambda: (data / 'running.json').is_file(), 'Installed app failed to start')
        report = json.loads((data / 'running.json').read_text())
        return RunningApp(report['pid']), report

    def log_contains(text):
        log = data / 'updater.log'
        return log.exists() and text in log.read_text()

    def close(process, report):
        (data / 'exit').write_text('exit')
        process.wait(timeout=30)
        assert (data / 'children-closed').is_file(), f'Process {process.pid} exited ({process.returncode}) before child cleanup; see process-{session}.log'
        # tasklist reports only the exact fixture child PID; unrelated processes are untouched.
        out = run('tasklist', '/FI', f"PID eq {report['child']}", '/FO', 'CSV', '/NH').stdout
        assert f'"{report["child"]}"' not in out, 'Hidden child survived shutdown'

    try:
        process, report = start(root / 'offline-feed')
        assert report['version'] == '1.0.0'
        module = run('powershell', '-NoProfile', '-Command',
                     "(Get-Process -Id $env:GAMENIGHT_SMOKE_PID).Modules | Where-Object { $_.ModuleName -eq 'VCRUNTIME140.dll' } | Select-Object -ExpandProperty FileName",
                     env=dict(os.environ, GAMENIGHT_SMOKE_PID=str(report['pid']))).stdout.strip()
        assert Path(module).resolve() == (installed / 'current/vcruntime140.dll').resolve(), 'App used a system runtime instead of its bundled DLL'
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
        # The version directory is swapped before post-update hooks finish.
        # Wait for this install's updater, not an arbitrary delay or an unrelated updater.
        def update_finished():
            command = "$wanted = Join-Path $env:GAMENIGHT_SMOKE_INSTALL 'Update.exe'; @(Get-CimInstance Win32_Process -Filter \"Name='Update.exe'\" | Where-Object { $_.ExecutablePath -eq $wanted }).Count"
            check = run('powershell', '-NoProfile', '-Command', command,
                        env=dict(os.environ, GAMENIGHT_SMOKE_INSTALL=str(installed)))
            return check.stdout.strip() == '0'
        wait_for(update_finished, 'Updater did not complete')
        process, report = start(root / '2.0.0')
        assert report['version'] == '2.0.0'
        assert (data / 'settings.json').read_text() == 'preserve this setting'
        assert (Path(report['content']) / 'main.lua').read_text() == 'original content'
        close(process, report)
        print('PASS: install, offline start, corrupt download, deferred update, restart, data preservation, child cleanup, app-local C++ runtime')
    finally:
        # Scope cleanup to the uniquely identified fixture installation only.
        if 'process' in locals() and process.poll() is None:
            (data / 'exit').write_text('exit')
            process.wait(timeout=30)
        for log in installed.rglob('*.log'):
            shutil.copy2(log, root / log.name)
        if (installed / 'Update.exe').exists():
            run(str(installed / 'Update.exe'), 'uninstall', '--silent')


if __name__ == '__main__':
    main()
