"""Verify packaged SpaceRacer updates both players' live face-colour layers."""
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
    probe_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(probe_module)
    with tempfile.TemporaryDirectory(prefix='spaceracer-colors-') as directory:
        state_path = Path(directory)/'state.json'
        executable = str(args.godot.resolve())
        with probe_module.FakeHost(executable, 'spaceracer',
                                  command=[executable, '--headless', '--audio-driver', 'Dummy'],
                                  env={'SPACERACER_PROBE_PATH': str(state_path)}, timeout=30) as host:
            host.welcome()
            host.setting('bots', 0)
            seats = [dict(index=i, occupant=dict(kind='local', player_id=f'p{i}'),
                          controller=f'ordinal:{i}') for i in (0, 2)]
            players = [dict(id='p0', name='Azure', color='#00aaff', skin_color='#8a6644'),
                       dict(id='p2', name='Rose', color='#ff4488', skin_color='#efbd89')]
            session = 'spaceracer-colors'
            host.prepare(seats, players, session=session)
            def read():
                return json.loads(state_path.read_text())
            initial = probe_module.wait(read, lambda s: s.get('phase') == 'ready' and len(s.get('racers', [])) == 2)
            assert initial['racers'][0]['face_signature'][1:] == ['#8a6644', '#00aaff']
            assert initial['racers'][1]['face_signature'][1:] == ['#efbd89', '#ff4488']
            host.start()
            probe_module.wait(read, lambda s: s.get('running') and s.get('clock', 0) > .1)
            players[0].update(color='#22ee99', skin_color='#c48254')
            host.send(dict(type='party_updated', session=session, seats=seats,
                           players=list(reversed(players)), presence=[]))
            updated = probe_module.wait(read, lambda s: s['racers'][0].get('face_signature', [None,None,None])[1:]
                                        == ['#c48254', '#22ee99'])
            assert updated['racers'][0]['face_revision'] > initial['racers'][0]['face_revision']
            assert updated['racers'][0]['skin_color'] == '#c48254'
            assert updated['racers'][0]['color'] == '#22ee99'
            assert updated['racers'][1]['face_signature'] == initial['racers'][1]['face_signature']
            assert updated['racers'][1]['face_revision'] == initial['racers'][1]['face_revision']
            host.disconnect()
            assert host.exit_code(timeout=8) == 0
            print('PASS skin and clothing colours rebuild the correct pilot face layer during play')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'FAIL {exc}', file=sys.stderr)
        sys.exit(1)
