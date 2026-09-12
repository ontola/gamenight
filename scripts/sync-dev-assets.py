"""Incrementally stage lobby assets without touching unrelated runtime files."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import time


def sync(source, destination):
    source, destination = Path(source).resolve(), Path(destination).resolve()
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError('Source and destination must be separate directories')
    if not source.is_dir():
        raise ValueError(f'Missing source: {source}')
    destination.mkdir(parents=True, exist_ok=True)
    manifest = destination / '.dev-assets.json'
    previous = json.loads(manifest.read_text()) if manifest.exists() else {}
    current, copied, removed = {}, 0, 0
    for group in ('assets', 'packs'):
        for path in sorted((source / group).rglob('*')):
            if not path.is_file():
                continue
            relative = path.relative_to(source).as_posix()
            target = destination / relative
            metadata = path.stat()
            old = previous.get(relative)
            # Warm restarts avoid opening hundreds of unchanged WSL files.
            # Rehash after any metadata change; copy2 preserves timestamps.
            if isinstance(old, dict) and old['size'] == metadata.st_size and old['mtime'] == metadata.st_mtime_ns:
                staged = target.stat() if target.is_file() else None
                if staged and staged.st_size == old['size'] and staged.st_mtime_ns == old['mtime']:
                    current[relative] = old
                    continue
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            current[relative] = {'sha256': digest, 'size': metadata.st_size, 'mtime': metadata.st_mtime_ns}
            if not target.exists() or hashlib.sha256(target.read_bytes()).hexdigest() != digest:
                if destination not in target.resolve().parents:
                    raise ValueError('Asset escapes staging directory')
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)
                copied += 1
            elif destination in target.resolve().parents:
                shutil.copystat(path, target)
    for relative in previous.keys() - current.keys():
        target = (destination / relative).resolve()
        if destination not in target.parents or Path(relative).parts[0] not in ('assets', 'packs'):
            raise ValueError('Invalid managed asset path')
        if target.is_file():
            target.unlink()
            removed += 1
    manifest.write_text(json.dumps(current, sort_keys=True))
    return {'files': len(current), 'copied': copied, 'removed': removed}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    started = time.monotonic()
    result = sync(args.source, args.destination)
    result['seconds'] = round(time.monotonic() - started, 3)
    print(json.dumps(result))
