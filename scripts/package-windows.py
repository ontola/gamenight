"""Package previously built native binaries and a starter catalogue."""
import argparse
import hashlib
from pathlib import Path
import shutil
from windows_runtime import find_crt



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--profile', choices=['dev', 'ci', 'release'], default='dev')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    profile_dir = 'debug' if args.profile == 'dev' else args.profile
    crt = find_crt()
    args.output.mkdir(parents=True, exist_ok=False)
    stage = args.output / 'gamenight-windows-preview'
    (stage / 'bin').mkdir(parents=True)
    for name in ['gamenight-daemon.exe', 'lobby.exe']:
        shutil.copy2(args.target / profile_dir / name, stage / 'bin' / name)
    shutil.copy2(args.target / profile_dir / 'gamenight-launcher.exe', stage / 'GameNight.exe')
    # Rust/MSVC binaries dynamically import these DLLs. App-local deployment
    # supports a clean Windows account without installing a machine-wide runtime.
    for library in crt.glob('*.dll'):
        for destination in [stage, stage / 'bin']:
            shutil.copy2(library, destination / library.name)
    (stage / 'notices').mkdir(exist_ok=True)
    (stage / 'notices/msvc-runtime.txt').write_text(
        f'Microsoft Visual C++ Runtime ({crt.parent.parent.name}, x64)\n'
        'Copyright Microsoft Corporation. All rights reserved.\n'
        'Redistributed under the Microsoft Visual Studio license terms.\n'
        'https://learn.microsoft.com/cpp/windows/redistributing-visual-cpp-files\n', encoding='utf-8')

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
    (stage / 'catalog/games').mkdir(parents=True)
    shutil.copy2(repo / 'catalog/games/pinpals.json', stage / 'catalog/games/pinpals.json')
    shutil.copy2(repo / 'catalog/schema.json', stage / 'catalog/schema.json')
    archive = Path(shutil.make_archive(str(args.output / stage.name), 'zip', args.output, stage.name))
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (args.output / 'SHA256SUMS.txt').write_text(f'{digest}  {archive.name}\n')
    print(archive)


if __name__ == '__main__':
    main()
