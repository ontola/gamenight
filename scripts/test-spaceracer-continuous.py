"""Check that a completed race restarts without ending the GameNight session."""
import argparse
import importlib.util
import json
from pathlib import Path
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
    with tempfile.TemporaryDirectory(prefix='spaceracer-continuous-') as directory:
        state_path = Path(directory)/'state.json'
        executable = str(args.godot.resolve())
        with probe.FakeHost(executable, 'spaceracer',
                           command=[executable, '--headless', '--audio-driver', 'Dummy'],
                           env={'SPACERACER_PROBE_PATH': str(state_path)}, timeout=30) as host:
            host.welcome()
            host.setting('bots', 0)
            host.setting('laps', 1)
            host.setting('difficulty', 'easy')
            host.setting('seed', 2)
            session = 'spaceracer-continuous'
            seats = [dict(index=0, occupant=dict(kind='ai', player_id='bot0'), controller='')]
            players = [dict(id='bot0', name='Bot', color='#00aaff', skin_color='#8a6644')]
            host.prepare(seats, players, session=session)
            def read():
                return json.loads(state_path.read_text())
            probe.wait(read, lambda s: s.get('phase') == 'ready')
            host.start()
            probe.wait(read, lambda s: s.get('clock', 0) > 2)
            probe.wait(lambda: host.messages,
                       lambda messages: any(m.get('type') == 'finished' for m in messages), timeout=150)
            finished_clock = probe.wait(read, lambda s: s.get('clock', 0) > 2)['clock']
            assert finished_clock > 2 and host.process.poll() is None
            restarted = probe.wait(read, lambda s: s.get('phase') == 'running'
                                   and s.get('clock', 1000) < 2, timeout=25)
            assert restarted['session'] == session and restarted['running']
            assert host.process.poll() is None, 'Game process exited after the first race'
            host.disconnect()
            assert host.exit_code(timeout=8) == 0
            print('PASS race finished, restarted and kept the same GameNight session and process')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'FAIL {exc}', file=sys.stderr)
        sys.exit(1)
