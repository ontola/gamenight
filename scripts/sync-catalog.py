#!/usr/bin/env python3
"""Rebuild offline catalog entries from each game's own gamenight.json.

A game's metadata lives in its repository: gamenight.json for the facts and
assets/gamenight/ for cover.png, icon.png and gameplay.png. The entries in
catalog/games/ only ship that data inside the installer, so they are generated
here and never edited by hand. Downloads stay as they are: they are release
facts, not metadata.

  python3 scripts/sync-catalog.py                    # every entry, from GitHub
  python3 scripts/sync-catalog.py spellstorm         # one entry
  python3 scripts/sync-catalog.py --game ../spellstorm   # from a local checkout
  python3 scripts/sync-catalog.py --check            # fail when an entry is stale

The game's folder is found from `links.source` in its catalog entry. Entries
without a gamenight.json there (the LÖVE pack, games outside our repositories)
are left alone. New games are not added here: they reach hosts through the
hosted catalog once a stable build is published (see docs/site/publishing.md).
Pillow is only needed when artwork has to be shrunk to the 256 KiB limit.
"""
import argparse
import base64
import io
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAMES = ROOT / 'catalog' / 'games'
ORDER = ['$schema', 'id', 'title', 'tagline', 'developer', 'players', 'match_minutes', 'price',
         'tags', 'emoji', 'color', 'integration', 'requirements', 'links',
         'cover', 'icon', 'screenshot', 'downloads', 'bundled']
ART = {'cover': 'cover.png', 'icon': 'icon.png', 'screenshot': 'gameplay.png'}
# Release facts and art come from elsewhere; everything else is the game's to say.
NOT_METADATA = {'$schema', 'downloads', 'bundled', *ART}
MAX_PNG_BYTES = 256 * 1024
MAX_SIDE = 1024


class Local:
    def __init__(self, folder):
        self.folder = Path(folder)

    def read(self, name):
        path = self.folder / name
        return path.read_bytes() if path.is_file() else None

    def __str__(self):
        return str(self.folder)


class GitHub:
    def __init__(self, owner, repo, ref, path):
        self.base = f'https://raw.githubusercontent.com/{owner}/{repo}/{ref}/' + (path + '/' if path else '')

    def read(self, name):
        try:
            with urllib.request.urlopen(self.base + name, timeout=30) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            raise

    def __str__(self):
        return self.base


def github_source(url):
    match = re.fullmatch(r'https://github\.com/([\w.-]+)/([\w.-]+?)(?:\.git)?(?:/tree/([\w.-]+)/(.*?))?/?', url or '')
    if not match:
        return None
    owner, repo, ref, path = match.groups()
    return GitHub(owner, repo, ref or 'main', path or '')


def fit_png(data):
    """Embed the PNG as is when it fits the protocol limits, else shrink it."""
    width, height = int.from_bytes(data[16:20], 'big'), int.from_bytes(data[20:24], 'big')
    if data[:8] == b'\x89PNG\r\n\x1a\n' and len(data) <= MAX_PNG_BYTES and max(width, height) <= MAX_SIDE:
        return data
    from PIL import Image
    image = Image.open(io.BytesIO(data))
    image.load()
    image = image.convert('RGBA')
    image.thumbnail((MAX_SIDE, MAX_SIDE), Image.Resampling.LANCZOS)
    for attempt in range(12):
        candidate = image if attempt == 0 else image.resize(
            (max(1, round(image.width * 0.85 ** attempt)), max(1, round(image.height * 0.85 ** attempt))),
            Image.Resampling.LANCZOS)
        for quantized in (False, True):
            frame = candidate.quantize(256, method=Image.Quantize.FASTOCTREE) if quantized else candidate
            out = io.BytesIO()
            frame.save(out, 'PNG', optimize=True)
            if out.tell() <= MAX_PNG_BYTES:
                return out.getvalue()
    raise ValueError('artwork does not fit in 256 KiB')


def build(existing, source):
    raw = source.read('gamenight.json')
    if raw is None:
        return None
    meta = json.loads(raw)
    if meta.get('id') != existing['id']:
        raise ValueError(f"{source}gamenight.json has id {meta.get('id')!r}, catalog expects {existing['id']!r}")
    entry = {'$schema': '../schema.json'}
    entry.update({k: v for k, v in meta.items() if k not in NOT_METADATA})
    for field, name in ART.items():
        data = source.read('assets/gamenight/' + name)
        if data:
            entry[field] = 'data:image/png;base64,' + base64.b64encode(fit_png(data)).decode()
    for field in ('downloads', 'bundled'):
        if field in existing:
            entry[field] = existing[field]
    known = [k for k in ORDER if k in entry]
    return {k: entry[k] for k in known + sorted(set(entry) - set(known))}


def encode(entry):
    return json.dumps(entry, indent=2, ensure_ascii=False) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('ids', nargs='*', help='Catalog ids to sync; default is every entry')
    parser.add_argument('--game', action='append', default=[], type=Path,
                        help='Local game folder holding gamenight.json; repeatable')
    parser.add_argument('--check', action='store_true', help='Report stale entries without writing')
    args = parser.parse_args()

    sources = {}
    for folder in args.game:
        manifest = folder / 'gamenight.json'
        if not manifest.is_file():
            parser.error(f'{manifest} does not exist')
        sources[json.loads(manifest.read_text())['id']] = Local(folder)
    ids = args.ids or (list(sources) if sources else sorted(p.stem for p in GAMES.glob('*.json')))

    stale = []
    for game in ids:
        path = GAMES / f'{game}.json'
        if not path.is_file():
            print(f'{game}: no catalog entry. New games are published through the GameNight API, '
                  'not added to catalog/games; see docs/site/publishing.md.', file=sys.stderr)
            return 2
        existing = json.loads(path.read_text())
        source = sources.get(game) or github_source(existing.get('links', {}).get('source'))
        entry = build(existing, source) if source else None
        if entry is None:
            print(f'{game}: kept as is (no gamenight.json at {source or "its source link"})')
            continue
        if encode(entry) == path.read_text():
            print(f'{game}: up to date')
            continue
        stale.append(game)
        if args.check:
            print(f'{game}: differs from {source}gamenight.json')
        else:
            path.write_text(encode(entry))
            print(f'{game}: updated from {source}')
    if args.check and stale:
        print('Run python3 scripts/sync-catalog.py ' + ' '.join(stale), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
