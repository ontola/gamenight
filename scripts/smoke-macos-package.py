"""Launch the packaged Mac host from an unrelated cwd and wait for its Game Room lobby."""
import argparse
import json
import os
import re
import signal
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=Path)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--timeout", type=float, default=100)
args = parser.parse_args()
app = args.app.resolve()
output = args.output.resolve()
output.mkdir(parents=True)
memory = output / "test-players.json"
memory.write_text(json.dumps({"device": "macos-package-test", "profiles": {
    "mac-test": {"id": "mac-test", "username": "Mac Test", "skin_color": "#dba57a", "avatar": ""}
}}))
env = dict(os.environ, GAMENIGHT_DATA_DIR=str(output / "data"),
           GAMENIGHT_PLAYER_MEMORY=str(memory), RUST_BACKTRACE="1")
daemon_log = output / "data/daemon.log"
ansi = re.compile(r"\x1b\[[0-9;]*m")


def lobby_connected():
    # The Godot lobby proves it started from the bundle (binary, PCK, launch
    # spec) by saying hello to the packaged host with its launch token.
    if not daemon_log.is_file():
        return False
    text = ansi.sub("", daemon_log.read_text(errors="replace"))
    return any("game connected" in line and "game=game-room" in line for line in text.splitlines())


def diagnose():
    # Run the helper on its own, verbosely, so a failed run says whether
    # Godot found the pack and started the Game Room's scripts.
    helper = app / "Contents/Helpers/GameNight.app/Contents"
    result = subprocess.run([str(helper / "MacOS/GameNight"), "--headless", "--verbose", "--main-pack",
                             str(helper / "Resources/GameNight.pck"), "--quit-after", "120"],
                            env=dict(os.environ, GAMENIGHT_ADDR="127.0.0.1:9"), capture_output=True,
                            text=True, timeout=60)
    print("\n".join((result.stdout + result.stderr).splitlines()[-80:]))


with (output / "launcher.log").open("w") as log:
    process = subprocess.Popen([str(app / "Contents/MacOS/GameNight"), "17912"],
                               cwd=output, env=env, stdout=log, stderr=log, start_new_session=True)
    try:
        deadline = time.monotonic() + args.timeout
        while not lobby_connected():
            if process.poll() is not None:
                raise RuntimeError(f"Packaged launcher exited with {process.returncode} before the lobby connected")
            if time.monotonic() > deadline:
                diagnose()
                raise RuntimeError("The packaged Game Room lobby did not connect to the host")
            time.sleep(0.5)
        time.sleep(5)  # Let a lobby that crashes right after hello show it.
        if process.poll() is not None:
            raise RuntimeError(f"Packaged launcher exited with {process.returncode} after the lobby connected")
        errors = (output / "data/daemon-errors.log").read_text(errors="replace")
        if "panicked at" in errors:
            raise RuntimeError("The packaged host panicked")
        print("Packaged Game Room lobby connected to the host")
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=10)
