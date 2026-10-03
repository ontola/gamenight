"""Bind installer catalog downloads to the exact certified release artifacts."""
import argparse
import hashlib
import json
import re
from pathlib import Path


def prepare(catalog, pack, version):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Expected a numeric release version")
    artifacts = {p.name: p for p in pack.glob('*.love')}
    if not artifacts:
        raise ValueError('No certified games')
    used = set()
    updates = []
    for path in sorted(catalog.glob('*.json')):
        entry = json.loads(path.read_text(encoding='utf-8'))
        for download in entry.get('downloads', {}).values():
            name = download.get('entrypoint', '')
            if not name.endswith('.love'):
                continue
            if name not in artifacts:
                raise ValueError(f'Missing release artifact: {name}')
            used.add(name)
            download['url'] = f'https://github.com/ontola/gamenight/releases/download/v{version}/{name}'
            download['sha256'] = hashlib.sha256(artifacts[name].read_bytes()).hexdigest()
        updates.append((path, entry))
    if used != set(artifacts):
        raise ValueError('Release contains games absent from the catalog')
    for path, entry in updates:
        path.write_text(json.dumps(entry, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--catalog', type=Path, default=Path(__file__).resolve().parents[1]/'catalog/games')
    p.add_argument('--pack', type=Path, required=True)
    p.add_argument('--version', required=True)
    args = p.parse_args()
    prepare(args.catalog, args.pack, args.version)
