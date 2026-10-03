#!/usr/bin/env python3
"""Run the Godot lobby against a real daemon, with synthetic profiles and games.

--capture-dir renders desktop and narrow-window screenshots (requires a display,
e.g. xvfb-run). No account, physical controller or cloud connection is used.
"""
import argparse
import base64
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

ROOT = Path(__file__).resolve().parents[1]


class Peer:
    def __init__(self, port, role, game=None):
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=5)
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
            if message["type"] == "error":
                raise AssertionError(message)
            if message["type"] == "party_state":
                self.party = message["party"]
        return self.party

    def close(self):
        self.file.close()
        self.socket.close()


GAME_SETTINGS = {}


def game_loop(port, game_id, stop, peers):
    peer = Peer(port, "game", game_id)
    peers[game_id] = peer
    peer.send({"type":"declare_settings","settings":GAME_SETTINGS.get(game_id, [
        {"key":"items","label":"Pickups","kind":"toggle","default":True},
        {"key":"rounds","label":"Rounds","kind":"number","default":3,"min":1,"max":5},
        {"key":"arena","label":"Arena","kind":"choice","default":"Garden","options":["Garden","Warehouse"]}])})
    try:
        while not stop.is_set():
            message = peer.read()
            if message["type"] == "prepare":
                peer.send({"type": "ready", "session": message["session"]})
    except (OSError, ValueError):
        pass
    finally:
        peer.close()


def avatar(style):
    pixels = [None] * (48 * 48)
    def fill(x0, y0, x1, y1, color):
        for y in range(y0, y1):
            for x in range(x0, x1):
                pixels[y * 48 + x] = color
    fill(20, 25, 22, 28, "#243b36")
    fill(28, 25, 30, 28, "#243b36")
    fill(23, 33, 28, 34, "#9e5546")
    if style == 0:
        fill(14, 12, 34, 19, "#bc694c")
        fill(12, 18, 36, 21, "#d18b59")
        fill(19, 8, 31, 13, "#bc694c")
    elif style == 1:
        fill(14, 17, 34, 22, "#463b32")
        fill(13, 21, 17, 29, "#463b32")
        fill(32, 21, 35, 30, "#463b32")
    elif style == 2:
        fill(16, 15, 34, 20, "#598796")
        fill(13, 20, 38, 23, "#598796")
    else:
        fill(17, 16, 32, 21, "#a27350")
        fill(16, 24, 24, 25, "#243b36")
        fill(26, 24, 34, 25, "#243b36")
        fill(16, 29, 24, 30, "#243b36")
        fill(26, 29, 34, 30, "#243b36")
    return json.dumps({"v": 1, "w": 48, "h": 48, "px": pixels})


def run(godot, capture=None, narrow=False, settings=False, game_ids=None, assistant=False, menu=False, stopped=False):
    if capture:
        capture.unlink(missing_ok=True)
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    with tempfile.TemporaryDirectory(prefix="gamenight-lobby-test-") as temporary:
        temp = Path(temporary)
        godot_args = ["--path", str(ROOT / "sdk/godot")]
        if capture:
            if not narrow: godot_args += ["--fullscreen"]
            else: godot_args += ["--windowed"]
            godot_args += ["--resolution", "430x900" if narrow else "3840x2160", "--", "--capture=" + str(capture)]
            if narrow: godot_args += ["--capture-narrow"]
        else:
            godot_args += ["--headless", "--script", "res://lobby/tests/flow.gd"]
        if settings: godot_args += ["--capture-settings"]
        if assistant: godot_args += ["--capture-assistant"]
        if menu: godot_args += ["--capture-menu"]
        game_ids = game_ids or ["neon-trails", "bubble-buddies", "blast-party"]
        shelf = []
        for game_id in game_ids:
            catalog = json.loads((ROOT / "catalog/games" / (game_id + ".json")).read_text())
            entry = {"id": game_id, "title": catalog["title"], "players": "1–4", "min_players": 1, "max_players": 4, "color": catalog.get("color", "#527d68")}
            # Reuse only public packaged artwork. The stub speaks lifecycle;
            # these captures do not claim the corresponding game was played.
            for field in ("cover", "screenshot"):
                value = catalog.get(field, "")
                if value.startswith("data:image/png;base64,"):
                    entry[field] = value
                elif value and (ROOT / value).is_file():
                    entry[field] = "data:image/png;base64," + base64.b64encode((ROOT / value).read_bytes()).decode()
            shelf.append(entry)
        shelf.append({"id": "godot-lobby", "title": "Living Room", "launch": {"command": godot, "args": godot_args, "env": {"GAMENIGHT_LOBBY_API": "1"}}})
        (temp / "shelf.json").write_text(json.dumps(shelf))
        env = {k: v for k, v in os.environ.items() if not k.startswith("GAMENIGHT")}
        env.update(GAMENIGHT_ADDR=f"127.0.0.1:{port}", GAMENIGHT_LIBRARY=str(temp / "shelf.json"),
                   GAMENIGHT_LOBBY_GAME="godot-lobby", GAMENIGHT_NO_PREWARM="1", GAMENIGHT_NO_MUSIC="1", GAMENIGHT_TEST_NO_CONTROLLERS="1")
        if capture:
            # Show the talk control; screenshots never open the microphone or send requests.
            env['GAMENIGHT_ASSISTANT_URL'] = 'http://127.0.0.1:1/start/preview'
        suffix = ".exe" if os.name == "nt" else ""
        log_path = ROOT / ".local" / ("lobby-capture-narrow.log" if narrow else "lobby-capture.log" if capture else "lobby-flow.log")
        log_path.parent.mkdir(exist_ok=True)
        stop = threading.Event()
        peers = {}
        with log_path.open("w") as log:
            options = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt" else {"start_new_session": True}
            target = Path(os.environ.get("CARGO_TARGET_DIR", ROOT / "target"))
            process = subprocess.Popen([os.environ.get("GAMENIGHT_TEST_DAEMON", str(target / "debug" / ("gamenight-daemon" + suffix)))], env=env, stdout=log, stderr=log, **options)
            try:
                deadline = time.monotonic() + 10
                while True:
                    try:
                        overlay = Peer(port, "overlay")
                        break
                    except OSError:
                        if time.monotonic() > deadline: raise
                        time.sleep(0.05)
                names = ["Nora", "Jamal", "Alex", "Bo"]
                colors = ["#cd8161", "#6a9879", "#7298b3", "#c5a44a"]
                skins = ["#efc39a", "#905c40", "#e9b78d", "#bf855b"]
                for i, name in enumerate(names):
                    overlay.send({"type": "join_party", "name": name, **({"avatar": avatar(i), "color": colors[i]} if i < 2 else {})})
                    state = overlay.until(lambda p: len(p["players"]) == i + 1)
                    player = next(p for p in state["players"] if p["name"] == name)
                    overlay.send({"type": "set_player_skin_color", "player_id": player["id"], "skin_color": skins[i]})
                for game_id in game_ids:
                    threading.Thread(target=game_loop, args=(port, game_id, stop, peers), daemon=True).start()
                if capture:
                    overlay.until(lambda p: all(g in p.get("connected_games", []) for g in game_ids))
                    overlay.send({"type":"play_next","game":game_ids[0]})
                    overlay.until(lambda p: p.get("active_session", {}).get("phase") == "running")
                    overlay.send({"type":"open_overlay"})
                    overlay.until(lambda p: p.get("active_session", {}).get("phase") == "paused")
                    if stopped:
                        peers[game_ids[1]].socket.shutdown(socket.SHUT_RDWR)
                        overlay.until(lambda p: any(issue["game"] == game_ids[1] for issue in p.get("game_issues", [])))
                    deadline = time.monotonic() + 25
                    while not capture.is_file() and time.monotonic() < deadline:
                        time.sleep(0.1)
                    assert capture.is_file(), log_path.read_text()
                else:
                    process.wait(timeout=65)
                    contents = log_path.read_text()
                    assert "LOBBY_FLOW_PASS" in contents and "LOBBY_FLOW_FAIL" not in contents and "SCRIPT ERROR" not in contents, contents
                overlay.close()
            finally:
                stop.set()
                if os.name == "nt":
                    subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"], capture_output=True)
                else:
                    try: os.killpg(process.pid, signal.SIGTERM)
                    except ProcessLookupError: pass
                process.wait(timeout=5)
        contents = log_path.read_text()
        assert "SCRIPT ERROR" not in contents, contents
        print("PASS", capture or "Godot lobby: queue, play, pause, resume, profiles, reconnect, leave, join")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--capture-dir", type=Path)
    parser.add_argument("--settings-json", type=Path, help="Use exported game settings in captures")
    args = parser.parse_args()
    godot = shutil.which(args.godot)
    if not godot:
        parser.error("Godot 4 executable not found")
    run(str(Path(godot).resolve()))
    if args.settings_json:
        GAME_SETTINGS.update(json.loads(args.settings_json.read_text()))
    if args.capture_dir:
        target = args.capture_dir.resolve()
        target.mkdir(parents=True, exist_ok=True)
        run(str(Path(godot).resolve()), target / "godot-lobby-desktop.png")
        run(str(Path(godot).resolve()), target / "godot-lobby-narrow.png", narrow=True)
        run(str(Path(godot).resolve()), target / "godot-lobby-settings.png", settings=True)
        run(str(Path(godot).resolve()), target / "godot-lobby-menu.png", menu=True)
        run(str(Path(godot).resolve()), target / "godot-lobby-stopped.png", stopped=True)


if __name__ == "__main__":
    main()
