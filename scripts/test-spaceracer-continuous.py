"""Check that a completed race restarts without ending the GameNight session."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', type=Path, required=True)
    parser.add_argument('--source', type=Path, required=True)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('spaceracer_pinned_probe', args.source/'tests/integration.py')
    probe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(probe)
    host = probe.Host()
    child = None
    with tempfile.TemporaryDirectory(prefix='spaceracer-continuous-') as directory:
        state_path = Path(directory)/'state.json'
        env = dict(os.environ, GAMENIGHT='1', GAMENIGHT_GAME_ID='spaceracer',
                   GAMENIGHT_TOKEN='spaceracer-continuous-test',
                   GAMENIGHT_ADDR=f'127.0.0.1:{host.port}',
                   SPACERACER_PROBE_PATH=str(state_path))
        try:
            child = subprocess.Popen([str(args.godot.resolve()), '--headless',
                                      '--audio-driver', 'Dummy'], env=env,
                                     stderr=subprocess.STDOUT)
            host.connect()
            probe.wait(lambda: host.messages,
                       lambda messages: any(m.get('type') == 'hello' for m in messages))
            host.send('welcome', protocol_version=1, party={})
            host.send('setting_changed', key='laps', value=1)
            host.send('setting_changed', key='difficulty', value='easy')
            host.send('setting_changed', key='seed', value=2)
            session = 'spaceracer-continuous'
            seats = [dict(index=0, occupant=dict(kind='ai', player_id='bot0'), controller='')]
            players = [dict(id='bot0', name='Bot', color='#00aaff', skin_color='#8a6644')]
            host.send('prepare', game='spaceracer', session=session, seats=seats, players=players)
            probe.wait(lambda: host.messages,
                       lambda messages: any(m.get('type') == 'ready' for m in messages), timeout=30)
            def read():
                return json.loads(state_path.read_text())
            probe.wait(read, lambda s: s.get('phase') == 'ready')
            host.send('start', session=session)
            probe.wait(read, lambda s: s.get('clock', 0) > 2)
            probe.wait(lambda: host.messages,
                       lambda messages: any(m.get('type') == 'finished' for m in messages), timeout=150)
            finished_clock = read()['clock']
            assert finished_clock > 2 and child.poll() is None
            restarted = probe.wait(read, lambda s: s.get('phase') == 'running'
                                   and s.get('clock', 1000) < 2, timeout=25)
            assert restarted['session'] == session and restarted['running']
            assert child.poll() is None, 'Game process exited after the first race'
            host.close()
            child.wait(timeout=8)
            assert child.returncode == 0
            print('PASS race finished, restarted and kept the same GameNight session and process')
        finally:
            if child and child.poll() is None:
                child.terminate()
                child.wait(timeout=5)
            try:
                host.close()
            except OSError:
                pass


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'FAIL {exc}', file=sys.stderr)
        sys.exit(1)
