"""Evidence-backed integration matrix. Unknown is never a successful release check."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import zipfile
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
STATUSES = {"passed", "failed", "untested", "not_applicable"}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def catalog(root=ROOT):
    entries = [json.loads(p.read_text(encoding="utf-8")) for p in sorted((root / "catalog/games").glob("*.json"))]
    if not entries or len({e['id'] for e in entries}) != len(entries):
        raise ValueError("Empty catalog or duplicate game ids")
    return entries


def revision(root=ROOT):
    return subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()


def required_feature(rule, feature, policy):
    return (rule['required'] or (policy.get('first_party') is True and rule.get('group') == 'personalisation')
            or feature in policy.get('claims', []))


def new_report(entries, requirements, commit, os_name, policies=None):
    return {"schema_version": 1, "commit": commit, "platform": os_name,
            "policies": policies or {"version":1,"games":{}}, "worktree_dirty": False, "created_at": datetime.now(timezone.utc).isoformat(), "requirements": requirements,
            "games": [{"id": e['id'], "title": e['title'], "artifact_sha256": None, "artifact": None,
                       "checks": {f: {"status": "untested", "evidence": [],
                                      "detail": "No executable verification for this artifact"}
                                  for f in requirements['features']}} for e in entries]}


def run_check(command, env, log, timeout=90):
    try:
        result = subprocess.run(command, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=timeout)
        log.write_bytes(result.stdout)
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired) as exc:
        log.write_text(str(exc), encoding="utf-8")
        return False


def evidence(path, output):
    return {"path": path.relative_to(output).as_posix(), "sha256": digest(path)}


def run_games(report, pack, love, certifier, output):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("GAMENIGHT", "GNLOVE"))}
    games = {g['id']: g for g in report['games']}
    artifacts = sorted(pack.glob('*.love'))
    if not artifacts:
        raise ValueError("No packaged games; refusing an empty successful run")
    unknown = {p.stem for p in artifacts} - games.keys()
    if unknown:
        raise ValueError(f"Packaged games absent from catalog: {sorted(unknown)}")
    for artifact in artifacts:
        game = games[artifact.stem]
        game['artifact_sha256'] = digest(artifact)
        game['artifact'] = artifact.name
        raw = output / (artifact.stem + '.protocol.json')
        commands = {
            'protocol.handshake': ([str(certifier), artifact.stem, '--timeout', '45', '--match-timeout', '5',
                                    '--report', str(raw), '--', str(love), str(artifact)],
                                   {**env, 'GNLOVE_HEADLESS': '1', 'GNLOVE_MATCH_SECONDS': '1'}),
            'presentation.frame': ([sys.executable, str(ROOT/'scripts/test-love-party-render.py'),
                                    '--love', str(love), '--pack', str(pack), '--game', artifact.stem], env),
            'gameplay.continuous': ([sys.executable, str(ROOT/'scripts/test-love-party.py'),
                                    '--continuous', '--love', str(love), '--pack', str(pack), '--game', artifact.stem], env),
            'process.disconnect': ([sys.executable, str(ROOT/'scripts/test-love-party.py'),
                                    '--love', str(love), '--pack', str(pack), '--game', artifact.stem], env),
        }
        observed = output / (artifact.stem + '.integration')
        probe_log = output / (artifact.stem + '.integration.log')
        run_check([sys.executable, str(ROOT/'scripts/test-love-integration.py'),
                   '--love', str(love), '--pack', str(pack), '--game', artifact.stem,
                   '--output', str(observed)], env, probe_log)
        try:
            checks = json.loads((observed/'checks.json').read_text())[artifact.stem]
        except (OSError, ValueError, KeyError):
            checks = {}
        observation = observed / (artifact.stem + '.observations.json')
        for feature in ('profile.identity', 'profile.colors', 'profile.face', 'input.identity', 'gameplay.switch',
                        'presentation.prewarm', 'gameplay.start', 'gameplay.pause', 'gameplay.resume', 'input.back'):
            result = checks.get(feature, {})
            passed = result.get('status') == 'passed' and observation.is_file()
            refs = [evidence(probe_log, output)]
            if observation.is_file(): refs.append(evidence(observation, output))
            game['checks'][feature] = {'status': 'passed' if passed else 'failed',
                                      'evidence': refs, 'detail': result.get('detail', 'Executable observations missing')}
        for feature, (command, check_env) in commands.items():
            log = output / f'{artifact.stem}.{feature}.log'
            passed = run_check(command, check_env, log)
            files = [evidence(log, output)]
            if feature == 'protocol.handshake':
                if raw.exists():
                    try:
                        protocol = json.loads(raw.read_text(encoding='utf-8'))
                        passed = (passed and protocol.get('schema_version') == 1 and protocol.get('scope') == 'protocol'
                                  and protocol.get('game') == artifact.stem and protocol.get('passed') is True
                                  and any(c.get('name') == 'process connects and says hello' and c.get('status') == 'passed' for c in protocol.get('checks', [])))
                        game['protocol_checks'] = protocol.get('checks', [])
                    except (ValueError, OSError):
                        passed = False
                    files.append(evidence(raw, output))
                else:
                    passed = False
            game['checks'][feature] = {'status': 'passed' if passed else 'failed',
                                      'evidence': files, 'detail': 'Executed against the packaged artifact'}
            print(f"{artifact.stem}: {feature}: {game['checks'][feature]['status']}", flush=True)


def run_spaceracer(report, archive, source, output, window_probe=False):
    """Run SpaceRacer's pinned packaged-game probe on the catalog ZIP.

    The probe exercises a synthetic host. An optional run with the actual
    window checks hidden, muted preparation on a Vulkan-capable machine.
    A separate packaged-game capture tests a rendered frame. Physical pads,
    colours and continuous play do not inherit a pass from these probes.
    """
    game = next(g for g in report['games'] if g['id'] == 'spaceracer')
    entry = next(e for e in catalog() if e['id'] == 'spaceracer')
    expected = entry['downloads']['windows']['sha256'].lower()
    actual = digest(archive)
    if actual != expected:
        raise ValueError(f'SpaceRacer download SHA-256 mismatch: {actual}')
    source_commit = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if source_commit != 'c5bb5eb9eb05a1a3dc3273453a5f1e49e36edfcb':
        raise ValueError('SpaceRacer probe source differs from v0.4.1 release')
    source_changes = subprocess.check_output(
        ['git', '-C', str(source), 'status', '--porcelain', '--untracked-files=no'], text=True).strip()
    if source_changes:
        raise ValueError('SpaceRacer probe source has uncommitted changes')
    game['artifact'] = archive.name
    game['artifact_sha256'] = actual
    game['probe_source_commit'] = source_commit
    supported = ('protocol.handshake', 'gameplay.start', 'gameplay.pause',
                 'gameplay.resume', 'input.identity', 'process.disconnect',
                 'profile.identity', 'profile.face', 'party.settings')
    log = output/'spaceracer.integration.log'
    window_log = output/'spaceracer.prewarm.log'
    frame_log = output/'spaceracer.frame.log'
    frame = output/'spaceracer.frame.png'
    colors_log = output/'spaceracer.colors.log'
    with tempfile.TemporaryDirectory(prefix='spaceracer-contract-') as directory:
        extracted = Path(directory)
        with zipfile.ZipFile(archive) as packed:
            for name in ('SpaceRacer.exe', 'SpaceRacer.pck'):
                if name not in packed.namelist():
                    raise ValueError(f'SpaceRacer release is missing {name}')
                (extracted/name).write_bytes(packed.read(name))
        env = {k: v for k, v in os.environ.items() if not k.startswith('GAMENIGHT')}
        passed = run_check([sys.executable, str(source/'tests/integration.py'),
                            '--godot', str(extracted/'SpaceRacer.exe'), '--packed', '--headless'],
                           env, log, timeout=180)
        colors_passed = run_check([sys.executable, str(ROOT/'scripts/test-spaceracer-colors.py'),
                                   '--godot', str(extracted/'SpaceRacer.exe'), '--source', str(source)],
                                  env, colors_log, timeout=90)
        if window_probe:
            window_passed = run_check([sys.executable, str(source/'tests/integration.py'),
                                       '--godot', str(extracted/'SpaceRacer.exe'), '--packed'],
                                      env, window_log, timeout=180)
            frame_passed = run_check([sys.executable, str(ROOT/'scripts/test-spaceracer-frame.py'),
                                      '--godot', str(extracted/'SpaceRacer.exe'),
                                      '--capture', str(frame)], env, frame_log, timeout=150)
            frame_passed = frame_passed and frame.is_file()
    ref = evidence(log, output)
    for feature in supported:
        game['checks'][feature] = {
            'status': 'passed' if passed else 'failed', 'evidence': [ref],
            'detail': 'Pinned v0.4.1 synthetic-host probe on the SHA-256-matched Windows ZIP',
        }
        print(f"spaceracer: {feature}: {game['checks'][feature]['status']}", flush=True)
    game['checks']['profile.colors'] = {
        'status': 'passed' if colors_passed else 'failed',
        'evidence': [evidence(colors_log, output)],
        'detail': 'Live skin and clothing updates rebuild only the matching pilot face layer',
    }
    print(f"spaceracer: profile.colors: {game['checks']['profile.colors']['status']}", flush=True)
    if window_probe:
        game['checks']['presentation.prewarm'] = {
            'status': 'passed' if window_passed else 'failed',
            'evidence': [evidence(window_log, output)],
            'detail': 'Pinned v0.4.1 windowed probe checks hidden, muted preparation and hidden, muted pause',
        }
        print(f"spaceracer: presentation.prewarm: {game['checks']['presentation.prewarm']['status']}", flush=True)
        frame_refs = [evidence(frame_log, output)]
        if frame.is_file():
            frame_refs.append(evidence(frame, output))
        game['checks']['presentation.frame'] = {
            'status': 'passed' if frame_passed else 'failed',
            'evidence': frame_refs,
            'detail': 'Packaged v0.4.1 Godot build captured a nonblank gameplay frame with renderer draw calls',
        }
        print(f"spaceracer: presentation.frame: {game['checks']['presentation.frame']['status']}", flush=True)


def write_report(report, output):
    (output/'matrix.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    lines = [f"# Game contract — {report['platform']}", '', f"Build: `{report['commit']}`", '']
    groups=report['requirements'].get('groups', {'all':{'label':'Checks'}})
    for group, info in groups.items():
        features=[f for f,r in report['requirements']['features'].items() if r.get('group','all')==group]
        lines += ['## '+info['label'], '', '| Game | '+' | '.join(features)+' |', '|---|'+'---|'*len(features)]
        for game in report['games']:
            lines.append('| '+game['id']+' | '+' | '.join(game['checks'][f]['status'] for f in features)+' |')
        lines.append('')
    lines += ['Essential checks are mandatory. Personalisation is mandatory for GameNight games.',
              'Optional features do not reduce playability; claimed features require passing evidence.',
              'Protocol success alone does not certify gameplay, graphics, audio or physical input.', '']
    (output/'matrix.md').write_text('\n'.join(lines), encoding='utf-8')


def release_game(entry, os_name, policies):
    # The inventory also contains the host, SDK example and games for other
    # operating systems. They remain untested in the matrix, not certified by
    # a Windows game-pack release. Missing downloads are NOT an exemption.
    role = policies.get('games', {}).get(entry['id'], {}).get('role', 'game')
    if role not in ('game', 'host', 'example'):
        raise ValueError(f"Unknown release role for {entry['id']}: {role}")
    if role != 'game':
        return False
    downloads = entry.get('downloads', {})
    return not downloads or os_name in downloads


def bundled_release_game(entry, os_name, policies):
    if not release_game(entry, os_name, policies):
        return False
    download = entry.get('downloads', {}).get(os_name, {})
    # The installer bundles .love games. Native ZIPs are downloaded on demand
    # and have their own artifact probes, not this pack's release gate.
    entrypoint = download.get('entrypoint', '')
    return not entrypoint or entrypoint.lower().endswith('.love')


def release_errors(report, entries, requirements, commit, os_name, output, pack, policies=None):
    errors = []
    policies = policies or {"version":1,"games":{}}
    if report.get('policies') != policies:
        errors.append('Game requirements or claimed features changed since verification')
    if report.get('schema_version') != 1 or report.get('commit') != commit or report.get('platform') != os_name:
        errors.append('Wrong report schema, commit or platform')
    if report.get('worktree_dirty') is not False:
        errors.append('Evidence was produced from uncommitted source changes')
    if report.get('requirements') != requirements:
        errors.append('Contract changed since verification')
    for game_id, policy in policies.get('games', {}).items():
        unknown=set(policy.get('claims', []))-requirements['features'].keys()
        if unknown:
            errors.append(f'{game_id}: unknown claimed features: {sorted(unknown)}')
    rows = report.get('games', [])
    games = {g['id']: g for g in rows}
    if len(games) != len(rows) or set(games) != {e['id'] for e in entries}:
        errors.append('Catalog coverage is incomplete or duplicated')
    entries_by_id = {e['id']: e for e in entries}
    expected = {e['id'] for e in entries if bundled_release_game(e, os_name, policies)}
    if not expected:
        errors.append('Release contains no games for this platform')
    packaged = {p.stem for p in pack.glob('*.love')}
    if packaged != expected:
        errors.append('Release package coverage differs from platform catalog: ' + str(sorted(packaged ^ expected)))
    for game in rows:
        entry = entries_by_id.get(game['id'], {})
        if entry and not bundled_release_game(entry, os_name, policies):
            continue
        download = entries_by_id.get(game['id'], {}).get('downloads', {}).get(os_name, {})
        if download.get('sha256') and download['sha256'].lower() != game.get('artifact_sha256'):
            errors.append(f"{game['id']}: tested artifact differs from catalog download")
        artifact = (pack/(game.get('artifact') or '__missing__')).resolve()
        if not artifact.is_relative_to(pack.resolve()) or not artifact.is_file() or digest(artifact) != game.get('artifact_sha256'):
            errors.append(f"{game['id']}: missing or changed artifact")
        policy=policies.get('games', {}).get(game['id'], {})
        for feature, rule in requirements['features'].items():
            check = game.get('checks', {}).get(feature, {})
            status = check.get('status')
            if status not in STATUSES or (required_feature(rule, feature, policy) and status != 'passed'):
                errors.append(f"{game['id']}/{feature}: {status or 'missing'}")
            if status == 'passed':
                refs = check.get('evidence', [])
                if not refs:
                    errors.append(f"{game['id']}/{feature}: no evidence")
                for ref in refs:
                    path = (output/ref['path']).resolve()
                    if not path.is_relative_to(output.resolve()) or not path.is_file() or digest(path) != ref.get('sha256'):
                        errors.append(f"{game['id']}/{feature}: missing or modified evidence")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--pack', type=Path)
    parser.add_argument('--love', type=Path)
    parser.add_argument('--certifier', type=Path)
    parser.add_argument('--spaceracer-archive', type=Path)
    parser.add_argument('--spaceracer-source', type=Path)
    parser.add_argument('--spaceracer-window-probe', action='store_true',
                        help='Run native window/prewarm and gameplay-frame checks on a Vulkan-capable Windows host')
    parser.add_argument('--gate', action='store_true', help='Require complete, current evidence before publication')
    parser.add_argument('--platform', choices=['windows', 'linux', 'mac'],
                        default={'Windows':'windows', 'Linux':'linux', 'Darwin':'mac'}[platform.system()])
    args = parser.parse_args()
    output = args.output.resolve()
    requirements = json.loads((ROOT/'contract/requirements.json').read_text())
    entries = catalog()
    policies = json.loads((ROOT/"contract/game-policies.json").read_text())
    if args.gate:
        if not args.pack:
            parser.error('--gate requires --pack for artifact verification')
        report = json.loads((output/'matrix.json').read_text())
        errors = release_errors(report, entries, requirements, revision(), args.platform, output, args.pack.resolve(), policies)
        print('\n'.join(errors) if errors else 'All required contract checks passed')
        return bool(errors)
    report = new_report(entries, requirements, revision(), args.platform, policies)
    report['worktree_dirty'] = bool(subprocess.check_output(
        ['git', '-C', str(ROOT), 'status', '--porcelain', '--untracked-files=normal'], text=True).strip())
    output.mkdir(parents=True, exist_ok=False)  # never reuse stale evidence
    try:
        if args.pack:
            if not args.love or not args.certifier:
                parser.error('--pack requires --love and --certifier')
            run_games(report, args.pack.resolve(), args.love.resolve(), args.certifier.resolve(), output)
        if args.spaceracer_archive or args.spaceracer_source:
            if not args.spaceracer_archive or not args.spaceracer_source:
                parser.error('SpaceRacer probe requires both --spaceracer-archive and --spaceracer-source')
            run_spaceracer(report, args.spaceracer_archive.resolve(), args.spaceracer_source.resolve(), output,
                           window_probe=args.spaceracer_window_probe)
    finally:
        write_report(report, output)
    return any(c['status'] == 'failed' for g in report['games'] for c in g['checks'].values())


if __name__ == '__main__':
    sys.exit(main())
