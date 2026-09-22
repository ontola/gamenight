"""Launch the packaged Mac host from an unrelated cwd and capture its lobby."""
import argparse
import json
import os
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=Path)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
app = args.app.resolve()
output = args.output.resolve()
output.mkdir(parents=True)
shot = output / "lobby.png"
memory = output / "test-players.json"
memory.write_text(json.dumps({"device": "macos-package-test", "profiles": {
    "mac-test": {"id": "mac-test", "username": "Mac Test", "skin_color": "#dba57a", "avatar": ""}
}}))
env = dict(os.environ, GAMENIGHT_DATA_DIR=str(output / "data"),
           GAMENIGHT_PLAYER_MEMORY=str(memory), LOBBY_SHOT=str(shot), LOBBY_SHOT_AFTER="18", RUST_BACKTRACE="1")
with (output / "launcher.log").open("w") as log:
    process = subprocess.Popen([str(app / "Contents/MacOS/GameNight"), "17912"],
                               cwd=output, env=env, stdout=log, stderr=log, start_new_session=True)
    try:
        process.wait(timeout=100)
        if process.returncode != 0:
            raise RuntimeError(f"Packaged launcher exited with {process.returncode}")
        if not shot.is_file() or shot.stat().st_size < 10000:
            raise RuntimeError("The packaged lobby did not produce a rendered screenshot")
        errors = (output / "data/daemon-errors.log").read_text(errors="replace")
        for marker in ["panicked at", "Unable to find asset", "Failed to load asset"]:
            if marker in errors:
                raise RuntimeError(f"Packaged lobby reported: {marker}")
        print(f"Packaged lobby rendered successfully: {shot}")
    finally:
        if process.poll() is None:
            import signal
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=10)
