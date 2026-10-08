#!/usr/bin/env python3
"""Run the Game Room lobby against a real daemon and local web server.

Synthetic players join through an overlay connection, stub games answer the
lifecycle, and a phone profile waits in the local room. The lobby's own test
flow then presses Y, LB and RT through the controller input path: queue a
game, put one first, start, pause, resume, pick up the phone profile and leave.

--capture-dir also saves screenshots (requires a display, e.g. xvfb-run, and
a Vulkan or OpenGL driver). No physical controller or phone camera is used.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
WEB = "http://127.0.0.1:7913"


class Peer:
    def __init__(self, port, role, game=None):
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.file = self.socket.makefile("rwb")
        self.send({"type": "hello", "role": role, **({"game": game} if game else {})})
        self.party = self.read()["party"]

    def send(self, message):
        self.file.write((json.dumps(message) + "\n").encode())
        self.file.flush()

    def read(self):
        return json.loads(self.file.readline())

    def until(self, predicate):
        while not predicate(self.party):
            message = self.read()
            if message["type"] == "party_state":
                self.party = message["party"]
        return self.party


def game_loop(port, game_id, stop):
    peer = Peer(port, "game", game_id)
    peer.socket.settimeout(None)  # stub games idle until the lobby starts them
    try:
        while not stop.is_set():
            message = peer.read()
            if message["type"] == "prepare":
                peer.send({"type": "ready", "session": message["session"]})
    except (OSError, ValueError):
        pass


def editor_face(index):
    """A face from the studio's character editor recipes (see tools/demo_faces.py)."""
    faces = json.loads((ROOT / "lobbies/game-room/assets/demo-faces.json").read_text())
    return [f for f in faces if f["source"].startswith("editor:")][index]["avatar"]


def post(path, body):
    request = urllib.request.Request(WEB + path, json.dumps(body).encode(), {"Content-Type": "application/json"})
    return urllib.request.urlopen(request, timeout=5).status


def run(godot, capture_dir=None):
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    lobby_dir = ROOT / "lobbies" / "game-room"
    with tempfile.TemporaryDirectory(prefix="gamenight-game-room-") as temporary:
        temp = Path(temporary)
        args = ["--path", str(lobby_dir)]
        if capture_dir:
            args += ["--rendering-driver", os.environ.get("GAME_ROOM_DRIVER", "vulkan"), "--resolution", "1920x1080"]
        else:
            args += ["--headless"]
        args += ["--", "--test-flow"] + ([f"--capture-dir={capture_dir}"] if capture_dir else [])
        games = [("space-racer", "Space Racer", "#38d6ff"), ("ball-kickers", "Ball Kickers", "#3ddc97"),
                 ("downhill-rush", "Downhill Rush", "#ffb454"), ("god-game", "God Game", "#ff4f8b")]
        shelf = [{"id": g, "title": t, "color": c, "players": "1–8", "min_players": 1, "max_players": 8} for g, t, c in games]
        shelf.append({"id": "game-room", "title": "Game Room", "launch": {"command": godot, "args": args, "env": {"GAMENIGHT_LOBBY_API": "1"}}})
        (temp / "shelf.json").write_text(json.dumps(shelf))
        env = {k: v for k, v in os.environ.items() if not k.startswith("GAMENIGHT")}
        env.update(GAMENIGHT_ADDR=f"127.0.0.1:{port}", GAMENIGHT_LIBRARY=str(temp / "shelf.json"), GAMENIGHT_WEB="1",
                   GAMENIGHT_LOBBY_GAME="game-room", GAMENIGHT_NO_PREWARM="1", GAMENIGHT_NO_MUSIC="1",
                   GAMENIGHT_TEST_NO_CONTROLLERS="1", GAMENIGHT_EXIT_WITH_LOBBY="1", GAMENIGHT_DATA_DIR=str(temp / "data"), HOME=str(temp))
        log_path = ROOT / ".local" / "game-room-flow.log"
        log_path.parent.mkdir(exist_ok=True)
        stop = threading.Event()
        target = Path(os.environ.get("CARGO_TARGET_DIR", ROOT / "target"))
        daemon = os.environ.get("GAMENIGHT_TEST_DAEMON", str(target / "debug" / "gamenight-daemon"))
        with log_path.open("w") as log:
            process = subprocess.Popen([daemon], env=env, stdout=log, stderr=log, start_new_session=True)
            try:
                deadline = time.monotonic() + 15
                while True:
                    try:
                        overlay = Peer(port, "overlay")
                        break
                    except OSError:
                        if time.monotonic() > deadline: raise
                        time.sleep(0.05)
                # No art: the host hands out its own guest faces and colours.
                for name in ("Nora", "Jamal", "Bo"):
                    overlay.send({"type": "join_party", "name": name})
                    overlay.until(lambda p, n=name: any(player["name"] == n for player in p["players"]))
                for game_id, _, _ in games:
                    threading.Thread(target=game_loop, args=(port, game_id, stop), daemon=True).start()
                # A phone profile waiting in the local room, as the studio page would send it.
                deadline = time.monotonic() + 15
                while True:
                    try:
                        room = json.loads(urllib.request.urlopen(WEB + "/api/player-links", timeout=3).read())["room"]
                        break
                    except OSError:
                        if time.monotonic() > deadline: raise
                        time.sleep(0.2)
                post("/api/profiles", {"id": "phone-sanne", "username": "Sanne", "skin_color": "#edc59a", "avatar": editor_face(1)})
                assert post("/api/local-room/join", {"code": room["room_code"], "profile": "phone-sanne"}) == 204
                process.wait(timeout=600 if capture_dir else 120)
            except subprocess.TimeoutExpired:
                pass
            finally:
                stop.set()
                try: os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError: pass
                process.wait(timeout=10)
        contents = log_path.read_text()
        assert "GAME_ROOM_FLOW_PASS" in contents and "SCRIPT ERROR" not in contents, contents[-6000:]
        print("PASS Game Room: queue, play next, start, pause, resume, phone pickup, leave")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--capture-dir", type=Path)
    args = parser.parse_args()
    godot = shutil.which(args.godot)
    if not godot:
        parser.error("Godot 4.5 executable not found")
    capture = None
    if args.capture_dir:
        capture = args.capture_dir.resolve()
        capture.mkdir(parents=True, exist_ok=True)
    run(str(Path(godot).resolve()), capture)


if __name__ == "__main__":
    main()
