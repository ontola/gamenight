"""Locate redistributable x64 libraries from the installed Visual C++ toolchain."""
import os
from pathlib import Path
import subprocess


def find_crt():
    """Use the installed toolchain's redistributables, never DLLs from System32."""
    configured = os.environ.get('VCToolsRedistDir')
    if configured:
        roots = [Path(configured)]
    else:
        vswhere = Path(os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)')) / 'Microsoft Visual Studio/Installer/vswhere.exe'
        installation = subprocess.check_output([
            str(vswhere), '-latest', '-products', '*',
            '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
            '-property', 'installationPath'], text=True).strip()
        if not installation:
            raise RuntimeError('Visual C++ toolchain with redistributables is required')
        roots = list((Path(installation) / 'VC/Redist/MSVC').iterdir())
    candidates = [directory for root in roots
                  for directory in root.glob('x64/Microsoft.VC*.CRT')
                  if (directory / 'vcruntime140.dll').is_file()]
    if not candidates:
        raise RuntimeError('Cannot find x64 Visual C++ redistributable DLLs')
    # Numeric toolset versions, so 14.9 is older than 14.44.
    return max(candidates, key=lambda path: tuple(int(part) for part in path.parent.parent.name.split('.') if part.isdigit()))

