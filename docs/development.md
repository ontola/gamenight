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

Player pages and sign-in use the hosted GameNight service by default. QR codes
point there, never at a localhost or LAN website. `--offline` disables cloud
sync; controllers, guest faces and local games still work. Offline sessions do
not advertise room codes that phones cannot use.

Native lobby controls use a loopback-only JSON API on port 7913. It serves no
HTML or static assets and rejects browser requests. The game protocol stays on
loopback port 7912 (or `--port`). Website preview servers belong to the internal
repository and are never bundled into the public application.

See [native host services](local-web-api.md) for the boundary.
