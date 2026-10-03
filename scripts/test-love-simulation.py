#!/usr/bin/env python3
"""Run the shared LÖVE suite with the same Pinpals modules as the release pack."""
from game_sources import game_sources
import argparse
import os
import json
import runpy
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--love', default='love')
    parser.add_argument('--settings-output', type=Path, help='Export tested game declarations as JSON')
    args = parser.parse_args()
    executable = shutil.which(args.love)
    if not executable:
        parser.error('LÖVE executable not found')
    with tempfile.TemporaryDirectory(prefix='gamenight-party-tests-') as temporary:
        source = Path(temporary) / 'party'
        shutil.copytree(game_sources() / 'love-party', source)
        for folder in ('core', 'sim', 'app', 'data'):
            shutil.copytree(game_sources() / 'pinpals' / folder, source / folder)
        env = dict(os.environ, GNLOVE_TEST='1', GNLOVE_HEADLESS='1')
        declaration_file = Path(temporary) / 'settings.json'
        env['GNLOVE_SETTINGS_OUTPUT'] = str(declaration_file)
        subprocess.run([executable, str(source)], env=env, check=True, timeout=120)
        declarations = json.loads(declaration_file.read_text())
        packaged = runpy.run_path(str(ROOT / "scripts/package-love-party.py"))["GAMES"]
        assert set(declarations) == set(packaged), "Every packaged game needs tested settings"
        if args.settings_output:
            shutil.copyfile(declaration_file, args.settings_output)


if __name__ == '__main__':
    main()
