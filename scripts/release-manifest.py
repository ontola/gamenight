"""Write checksums and provenance for website promotion of a complete preview."""
import argparse
import hashlib
import json
from pathlib import Path


def manifest(directory, version, revision, run, windows_only=False):
    setups = list(directory.glob('*Setup.exe'))
    if len(setups) != 1 or not (windows_only or (directory/'GameNight.dmg').is_file()):
        raise ValueError('Both installers are required')
    for required in ('catalog.tar.gz', 'game-contract-windows.tar.gz'):
        if not (directory/required).is_file():
            raise ValueError(f'Missing {required}')
    assets = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sorted(directory.iterdir()) if p.is_file() and p.name not in ('release.json', 'SHA256SUMS.txt')}
    result = dict(schema=1, version=version, commit=revision, run_id=int(run),
                  installers={'windows': setups[0].name, **({} if windows_only else {'mac': 'GameNight.dmg'})},
                  sha256=assets)
    (directory/'release.json').write_text(json.dumps(result, indent=2)+'\n')
    (directory/'SHA256SUMS.txt').write_text(''.join(f'{v}  {k}\n' for k, v in assets.items()))
    return result


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('directory', type=Path)
    p.add_argument('--version', required=True)
    p.add_argument('--revision', required=True)
    p.add_argument('--run', required=True)
    # While macOS runners are down: the website keeps its last complete
    # downloads (promotion needs both), the in-app updater gets Windows.
    p.add_argument('--windows-only', action='store_true')
    a = p.parse_args()
    manifest(a.directory, a.version, a.revision, a.run, a.windows_only)
