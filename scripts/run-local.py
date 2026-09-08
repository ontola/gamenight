#!/usr/bin/env python3
"""Build and run a local GameNight, without any cloud account or private code."""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--headless", action="store_true")
    parser.add_argument("--studio", action="store_true")
    parser.add_argument("--shelf", type=Path)
    parser.add_argument("--port", type=int, default=7912)
    args = parser.parse_args()
    if os.name == "nt":
        def interrupt(signum, frame):
            raise KeyboardInterrupt
        signal.signal(signal.SIGBREAK, interrupt)
    if not 1 <= args.port <= 65535:
        parser.error("Port must be between 1 and 65535")
    root = Path(__file__).resolve().parents[1]
    target = Path(os.environ.get("CARGO_TARGET_DIR", root / "target")).resolve()
    env = os.environ.copy()
    env["CARGO_TARGET_DIR"] = str(target)
    if not args.skip_build:
        subprocess.run(["cargo", "build", "--workspace", "--locked"], cwd=root, env=env, check=True)
        if not args.headless:
            subprocess.run(["cargo", "build", "--locked", "--manifest-path",
                            str(root / "crates/lobby/Cargo.toml")], cwd=root, env=env, check=True)
    suffix = ".exe" if os.name == "nt" else ""
    daemon = target / "debug" / ("gamenight-daemon" + suffix)
    demo = target / "debug" / ("demo-game" + suffix)
    lobby = target / "debug" / ("lobby" + suffix)
    for binary in [daemon] + ([] if args.shelf else [demo]) + ([] if args.headless else [lobby]):
        if not binary.is_file():
            parser.error(f"Missing {binary}; run without --skip-build")
    with socket.socket() as probe:
        if probe.connect_ex(("127.0.0.1", args.port)) == 0:
            parser.error(f"Port {args.port} is in use; close that GameNight or choose --port")
    shelf = json.loads(args.shelf.read_text()) if args.shelf else [{
        "id": "demo-game", "title": "SDK Demo", "players": "1–4",
        "min_players": 1, "max_players": 4, "emoji": "🦀", "color": "#7c5cff",
        "launch": {"command": str(demo), "args": ["10"], "cwd": str(root)},
    }]
    if not isinstance(shelf, list):
        parser.error("The shelf must be a JSON array")
    shelf = [entry for entry in shelf if entry.get("id") != "lobby"]
    if not args.headless:
        lobby_dir = root / "crates/lobby"
        shelf.append({"id": "lobby", "title": "GameNight", "players": "1–4",
                      "min_players": 1, "max_players": 4, "emoji": "🎮", "color": "#7c5cff",
                      "launch": {"command": str(lobby), "cwd": str(lobby_dir),
                                 "env": {"BEVY_ASSET_ROOT": str(lobby_dir)}}})
    local = root / ".local"
    local.mkdir(exist_ok=True)
    shelf_path = local / "shelf.json"
    shelf_path.write_text(json.dumps(shelf, indent=2), encoding="utf-8")
    for key in ("GAMENIGHT", "GAMENIGHT_GAME_ID", "GAMENIGHT_TOKEN", "GAMENIGHT_NO_LOBBY_WATCH", "GAMENIGHT_WEB"):
        env.pop(key, None)
    env.update(GAMENIGHT_ADDR=f"127.0.0.1:{args.port}", GAMENIGHT_LIBRARY=str(shelf_path),
               GAMENIGHT_NO_PREWARM="1", RUST_LOG=env.get("RUST_LOG", "info"))
    if args.headless:
        env["GAMENIGHT_NO_LOBBY_WATCH"] = "1"
    if args.studio:
        env["GAMENIGHT_WEB"] = "1"
    log_path = local / "gamenight.log"
    print(f"Starting GameNight. Logs: {log_path}\nPress Ctrl+C to stop.", flush=True)
    options = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt" else {"start_new_session": True}
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen([str(daemon)], cwd=root, env=env, stdout=log, stderr=log, **options)
        try:
            while True:
                try:
                    return process.wait(timeout=0.25)
                except subprocess.TimeoutExpired:
                    pass
        except KeyboardInterrupt:
            return 0
        finally:
            if process.poll() is None:
                if os.name == "nt":
                    subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"], capture_output=True)
                else:
                    os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=10)


if __name__ == "__main__":
    sys.exit(main())
