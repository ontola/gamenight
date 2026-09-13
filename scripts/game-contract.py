"""Evidence-backed integration matrix. Unknown is never a successful release check."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
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
    return {"path": str(path.relative_to(output)), "sha256": digest(path)}


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
            'process.disconnect': ([sys.executable, str(ROOT/'scripts/test-love-party.py'),
                                    '--love', str(love), '--pack', str(pack), '--game', artifact.stem], env),
        }
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
    for game in rows:
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
    finally:
        write_report(report, output)
    return any(c['status'] == 'failed' for g in report['games'] for c in g['checks'].values())


if __name__ == '__main__':
    sys.exit(main())
