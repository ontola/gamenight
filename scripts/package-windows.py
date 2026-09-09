"""Package previously built native binaries and checksum-verified game archives."""
import argparse
import hashlib
from pathlib import Path
import shutil
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', type=Path, required=True)
    parser.add_argument('--love-zip', type=Path, required=True)
    parser.add_argument('--pinpals-zip', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--profile', choices=['dev', 'ci', 'release'], default='dev')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    profile_dir = 'debug' if args.profile == 'dev' else args.profile
    sources = [
        (args.love_zip, 'ba6e56be2685e53c817749c4a5007f51137136fe5a3ab64920508babc2e74369', 'love-11.5-win64', 'love'),
        (args.pinpals_zip, 'b574829c2d1fac531fa73c4b13e7aba0758bd067f74c4651de01e75870e6e0f5',
         'pinpals-95ea42fe544cf3906c90aeb556359180964c1e88', 'pinpals'),
    ]
    for archive, expected, _, _ in sources:
        if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
            parser.error(f'Checksum mismatch: {archive}')
    args.output.mkdir(parents=True, exist_ok=False)
    stage = args.output / 'gamenight-windows-preview'
    (stage / 'bin').mkdir(parents=True)
    for name in ['gamenight-daemon.exe', 'lobby.exe']:
        shutil.copy2(args.target / profile_dir / name, stage / 'bin' / name)
    shutil.copy2(args.target / profile_dir / 'gamenight-launcher.exe', stage / 'GameNight.exe')
    for name in ['assets', 'packs', 'licenses']:
        shutil.copytree(repo / 'crates/lobby' / name, stage / 'lobby' / name)
    for name in ['LICENSE', 'CREDITS.md']:
        shutil.copy2(repo / 'crates/lobby' / name, stage / 'lobby' / name)
    shutil.copytree(repo / 'vendor/bones/licenses', stage / 'notices/bones')
    shutil.copy2(repo / 'crates/lobby/tools/reskin/ASSET-SOURCES.md', stage / 'notices')
    for name in ['LICENSE', 'THIRD_PARTY.md']:
        shutil.copy2(repo / name, stage / name)
    shutil.copy2(repo / 'docs/windows-preview.md', stage / 'README.md')
    shutil.copy2(repo / 'docs/windows-distribution.md', stage / 'windows-distribution.md')
    for archive, _, prefix, destination in sources:
        with zipfile.ZipFile(archive) as z:
            for item in z.infolist():
                relative = Path(item.filename).relative_to(prefix)
                if '..' in relative.parts or relative.is_absolute():
                    raise ValueError('Unsafe archive path')
                path = stage / destination / relative
                if item.is_dir():
                    path.mkdir(parents=True, exist_ok=True)
                else:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(z.read(item))
    archive = Path(shutil.make_archive(str(args.output / stage.name), 'zip', args.output, stage.name))
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (args.output / 'SHA256SUMS.txt').write_text(f'{digest}  {archive.name}\n')
    print(archive)


if __name__ == '__main__':
    main()
