"""Observe real packaged LOVE renderers and switch two native processes.

Synthetic host frames exercise the production input adapter with sparse device
IDs. This verifies ownership and consumption, not physical controller hardware.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import threading


def wait_until(read, predicate, timeout=12):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            last = read()
            if predicate(last):
                return last
        except (OSError, ValueError):
            pass
        time.sleep(.05)
    raise AssertionError(f"Observation timed out: {last}")


class Game:
    def __init__(self, love, artifact, folder, tag):
        self.file = folder / f'{tag}.json'
        self.stop_input = threading.Event()
        self.send_lock = threading.Lock()
        self.messages = []
        self.command_id = 0
        self.log = open(folder / f'{tag}.log', 'wb')
        self.server = socket.socket()
        self.server.bind(('127.0.0.1', 0))
        self.server.listen()
        self.server.settimeout(12)
        env = {k: v for k, v in os.environ.items() if not k.startswith(('GAMENIGHT', 'GNLOVE'))}
        env.update(GAMENIGHT='1', GAMENIGHT_GAME_ID=artifact.stem,
                   GAMENIGHT_ADDR=f'127.0.0.1:{self.server.getsockname()[1]}',
                   GAMENIGHT_TOKEN='probe', GNLOVE_PROBE_FILE=str(self.file), GNLOVE_PROBE_HOST_INPUT='1', GNLOVE_MATCH_SECONDS='600')
        self.child = subprocess.Popen([str(love), str(artifact)], env=env, stdout=self.log, stderr=self.log)
        try:
            self.peer = self.server.accept()[0]
            self.peer.settimeout(12)
            self.stream = self.peer.makefile('rwb', buffering=0)
            hello = json.loads(self.stream.readline())
            assert hello['type'] == 'hello' and hello['token'] == 'probe'
            self.peer.settimeout(None)
            self.send('welcome', protocol_version=1)
            # A real host drains the game's output. Leaving participation and
            # activity unread can keep Windows TCP shutdown from completing.
            def receive():
                try:
                    while line := self.stream.readline():
                        self.messages.append(json.loads(line))
                except (OSError, ValueError):
                    pass
            self.reader = threading.Thread(target=receive, daemon=True)
            self.reader.start()
            def stream_input():
                while not self.stop_input.wait(.04):
                    try:
                        self.send('controller_frame', controllers=[
                            dict(controller='ordinal:7', axes=[-32767,0,0,0,0,0], buttons=17),
                            dict(controller='ordinal:2', axes=[32767,0,0,0,0,0], buttons=34)])
                    except (OSError,ValueError): break
            self.input_thread=threading.Thread(target=stream_input,daemon=True)
            self.input_thread.start()
        except BaseException:
            self.close()
            raise

    def send(self, kind, **values):
        with self.send_lock:
            self.stream.write((json.dumps(dict(type=kind, session='probe-session', **values))+'\n').encode())

    def command(self, **values):
        self.command_id += 1
        target = self.file.with_suffix('.command')
        temporary = target.with_suffix('.tmp')
        temporary.write_text(json.dumps(dict(sequence=self.command_id, **values)), encoding='utf-8')
        # Windows cannot replace a file during the renderer's brief read.
        deadline = time.monotonic() + 2
        while True:
            try:
                temporary.replace(target)
                break
            except PermissionError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(.01)
        return wait_until(self.read, lambda s: s.get('command') == self.command_id)

    def read(self):
        return json.loads(self.file.read_text())

    def phase(self, value):
        return wait_until(self.read, lambda s: s['phase'] == value)

    def close(self):
        self.stop_input.set()
        if getattr(self, 'input_thread', None): self.input_thread.join(timeout=1)
        if getattr(self, 'peer', None):
            try: self.peer.shutdown(socket.SHUT_RDWR)
            except OSError: pass
        if getattr(self, 'reader', None): self.reader.join(timeout=2)
        for name in ('stream', 'peer', 'server'):
            obj = getattr(self, name, None)
            if obj:
                obj.close()
        try:
            self.child.wait(timeout=6)
        except subprocess.TimeoutExpired:
            self.forced_exit = True
            self.log.write(('TIMEOUT '+(self.file.read_text() if self.file.exists() else 'No observations')+'\n').encode())
            if os.name == 'nt':
                subprocess.run(['taskkill', '/PID', str(self.child.pid), '/T', '/F'], capture_output=True)
            else:
                self.child.kill()
            self.child.wait()
        self.log.close()


def check(love, artifact, output):
    results = {}
    observations = {}
    players = [dict(id='alpha', name='AlphaProbe', color='#25b769', skin_color='#db9371'),
               dict(id='beta', name='BetaProbe', color='#9d43cb', skin_color='#784f32')]
    for i, p in enumerate(players):
        p['avatar'] = json.dumps(dict(v=1, w=2, h=2, px=[None, '#12abef' if i == 0 else '#efab12', '#ffffff', None]))
    # Deliberately reorder sparse host IDs relative to the roster.
    seats = [dict(index=i, controller=f'ordinal:{(2,7)[i]}', occupant=dict(kind='local', player_id=p['id']))
             for i, p in enumerate(players)]
    def verdict(feature, passed, detail):
        results[feature] = dict(status='passed' if passed else 'failed', detail=detail)
    with tempfile.TemporaryDirectory(prefix='gamenight-contract-') as temporary:
        folder = Path(temporary)
        games = []
        try:
            for tag in ('first', 'second'):
                g = Game(love, artifact, folder, tag)
                games.append(g)
                g.send('prepare', game=artifact.stem, players=players, seats=seats)
                ready = g.phase('ready')
                observations[tag + '_ready'] = ready
                assert ready['rendered']['colors'], 'No prepared frame was rendered'
                assert ready['steps'] == 0, 'Simulation advanced during preload'
                assert not ready['visible'] and ready['audio'] == 0, 'Preloading was visible or audible'
            verdict('presentation.prewarm', True, 'Both native windows hidden and audio silent after preparing an actual frame')
            first, second = games
            started = time.monotonic()
            first.send('start')
            sample = wait_until(first.read, lambda s: s['phase']=='running' and s['steps']>90)
            observations['initial'] = sample
            verdict('gameplay.start', sample['visible'] and time.monotonic()-started < 12, 'Start presents gameplay and advances the simulation within 12 seconds on the test renderer')
            def borderless(snapshot):
                w = snapshot['window']
                assert not w['flags']['fullscreen'] and w['flags']['borderless'], 'Game entered fullscreen display mode or has window borders'
                assert (w['width'],w['height']) == (w['desktopWidth'],w['desktopHeight'] + (1 if os.name == 'nt' else 0)), 'Game does not cover the desktop with the composition guard'
            borderless(sample)
            initial = sample
            for i,p in enumerate(players):
                p['name'] = ('AUpdated','BUpdated')[i]
                p['color'] = ('#317da9','#d65c81')[i]
                p['skin_color'] = ('#bf8562','#68472c')[i]
                p['avatar'] = json.dumps(dict(v=1,w=2,h=2,px=['#af25c1' if i==0 else '#23cf81',None,None,'#ffffff']))
            first.send('party_updated',players=players,seats=seats,presence=[])
            sample = wait_until(first.read, lambda s: s['steps']>initial['steps']+90)
            observations['running'] = sample
            actual = sample['players']
            rendered = sample['rendered']
            def carried(key):
                return len(actual)==2 and all(actual[i].get(key)==p[key] for i,p in enumerate(players))
            verdict('profile.identity', carried('name') and all(any(p['name'] in t for t in rendered['text']) for p in players),
                    'Live-updated names in game state and actual text drawing calls')
            verdict('profile.colors', carried('color') and carried('skin_color') and all(
                p[k] in rendered['colors'] for p in players for k in ('color','skin_color')),
                'Live-updated outfit AND skin colours retained and used by the renderer')
            verdict('profile.face', carried('avatar') and all(p['avatar'] in rendered['faces'] for p in players),
                    'Each live-updated transparent avatar payload converted to an image and drawn')
            inputs = sample['inputs']
            def direction(v):
                if 'flip_left' in v:
                    return -1 if v['flip_left'] else 1 if v['flip_right'] else 0
                return v.get('x', v.get('move', 0))
            verdict('input.identity', len(actual)==2 and [p.get('controller') for p in actual]==['ordinal:2','ordinal:7']
                    and len(inputs)==2 and direction(inputs[0])>0 and direction(inputs[1])<0,
                    'Sparse host IDs retain profile ownership and consumed game inputs, independent of SDL enumeration')
            # Exercise the actual key event path, including held/repeated
            # presses and the press delivered again when focus returns.
            time.sleep(1.1)
            first.command(back=True, held=False)
            wait_until(lambda: first.messages, lambda ms: sum(m.get('type')=='request_overlay' for m in ms)==1)
            first.send('pause')
            paused = first.phase('paused')
            time.sleep(.15)
            paused = first.read()
            second.send('start')
            active = wait_until(second.read, lambda s: s['phase']=='running' and s['steps']>90)
            old = first.read()
            observations['paused'] = dict(before=paused, after=old)
            assert not old['visible'] and old['audio']==0 and old['steps']==paused['steps'] and old['remaining']==paused['remaining'], 'Old game kept running/visible/audible'
            verdict('gameplay.pause', True, 'Hidden and silent; simulation steps unchanged while the second game runs')
            assert active['visible'], 'New game did not become visible'
            second.send('pause')
            second.phase('paused')
            first.send('resume')
            resumed = wait_until(first.read, lambda s: s['phase']=='running' and s['visible'] and s['steps']>old['steps'])
            assert resumed['players'] == old['players'] and resumed['remaining'] <= old['remaining'], 'Resume reset the roster or round timer'
            observations['resumed'] = resumed
            verdict('gameplay.resume', True, 'Same players retained and simulation advances after Resume')
            first.command(back=True, held=True)
            time.sleep(1.1)
            first.command(back=True, held=True)
            time.sleep(.15)
            assert sum(m.get('type')=='request_overlay' for m in first.messages)==1, 'Held or focus-return Back bounced into lobby'
            first.command(held=False)
            time.sleep(1.1)
            first.command(back=True, held=False)
            wait_until(lambda: first.messages, lambda ms: sum(m.get('type')=='request_overlay' for m in ms)==2)
            observations['back_requests'] = [m for m in first.messages if m.get('type')=='request_overlay']
            verdict('input.back', True, 'Actual key handler: fresh press accepted; resumed/held presses rejected; released press accepted')
            assert not second.read()['visible'] and second.read()['audio']==0
            # Exercise repeated resumes, including rendering after each hide.
            for _ in range(5):
                first.send('pause')
                first.phase('paused')
                first.send('resume')
                resumed = wait_until(first.read, lambda s: s['phase']=='running' and s['visible'])
                borderless(resumed)
            observations['borderless_resumes'] = 5
            if artifact.stem == 'volley-trouble':
                # Volley deliberately shows names only on its score screen.
                # Render each winning side through the normal game renderer.
                for winner in (1, 2):
                    first.command(winner=winner)
                    wait_until(first.read, lambda s: any(players[winner-1]['name'] in t for t in s['rendered']['text']))
                names = first.read()
                observations['results_names'] = names
                verdict('profile.identity', carried('name') and all(any(p['name'] in t for t in names['rendered']['text']) for p in players),
                        'Updated names retained in state and drawn on both winning-side result screens')
            first.send('dispose')
            disposed = first.phase('idle')
            assert not disposed['players'] and not disposed['visible'] and disposed['audio']==0
            observations['switched'] = dict(previous=old, active=active, disposed=disposed)
            verdict('gameplay.switch', True, 'Two native processes: hidden silent preload; pause freezes simulation; switch/resume/dispose')
        except (AssertionError, OSError, ValueError) as error:
            verdict('gameplay.switch', False, str(error))
        finally:
            for g in games:
                g.close()
            if any(getattr(g, 'forced_exit', False) or g.child.returncode != 0 for g in games):
                verdict('gameplay.switch', False, 'Process failed to exit cleanly after host disconnection: ' + str([(g.child.returncode, getattr(g, 'forced_exit', False)) for g in games]))
            for logfile in [*folder.glob('*.log'), *folder.glob('*.error')]:
                (output / f'{artifact.stem}.{logfile.name}').write_bytes(logfile.read_bytes())
    for feature in ('profile.identity','profile.colors','profile.face','input.identity','gameplay.switch',
                    'presentation.prewarm','gameplay.start','gameplay.pause','gameplay.resume','input.back'):
        results.setdefault(feature, dict(status='failed',detail='Execution did not reach the observation'))
    (output / f'{artifact.stem}.observations.json').write_text(json.dumps(observations,indent=2)+'\n')
    return results


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--love',type=Path,required=True)
    p.add_argument('--pack',type=Path,required=True)
    p.add_argument('--game')
    p.add_argument('--output',type=Path,required=True)
    args=p.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    artifacts=sorted(args.pack.resolve().glob('*.love'))
    if args.game: artifacts=[a for a in artifacts if a.stem==args.game]
    if not artifacts: p.error('No matching artifacts')
    report={}
    for artifact in artifacts:
        report[artifact.stem]=check(args.love,artifact,args.output)
        for feature,result in report[artifact.stem].items():
            print(f'{artifact.stem}: {feature}: {result["status"]}: {result["detail"]}',flush=True)
    (args.output/'checks.json').write_text(json.dumps(report,indent=2)+'\n')
    return 0 if all(r['status']=='passed' for game in report.values() for r in game.values()) else 1

if __name__=='__main__':
    raise SystemExit(main())
