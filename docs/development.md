# Development setup

Use stable Rust, Python 3, and a native toolchain for the OS on which you play.

## Ubuntu / Debian

```sh
sudo apt-get install build-essential pkg-config libudev-dev libasound2-dev \
  libx11-dev libxkbcommon-dev libwayland-dev libxcursor-dev libxi-dev libxrandr-dev
python3 scripts/run-local.py
```

Use a desktop session and graphics drivers for the lobby. WSL can build and
run protocol tests, but use the Windows build for Windows controllers.

## Windows

Install Rust for Windows (MSVC), the Visual Studio C++ Build Tools and Python 3.
Run `python scripts/run-local.py` in PowerShell from a local checkout. The
script chooses `.exe` binaries automatically and keeps logs in `.local/`.

## macOS

Install Rust, Python 3 and Xcode Command Line Tools, then run the same script.

## Custom games

`--shelf` accepts a JSON array of game metadata with `launch.command`, optional
`launch.args`, and `launch.cwd`. Use absolute paths for executables and working
directories. `--skip-build` reuses a completed build; `--headless` skips the
lobby and runs the terminal example. Ctrl+C stops the launcher and its host.
The script uses `GAMENIGHT_NO_PREWARM` to disable catalogue downloading; normal
session prewarming remains enabled.

The daemon's HTTP studio is optional. `--studio` enables LAN QR pairing on
port 7913. The control protocol stays on loopback port 7912 (or the launcher's `--port`). Only use the
studio on a trusted LAN; see [security scope](../SECURITY.md).

The [local web API](local-web-api.md) documents profile operations, join outcomes
and daemon failure semantics.
