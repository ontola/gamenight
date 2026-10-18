#!/usr/bin/env python3
"""Phones count as players for games played on phones.

Runs a real daemon with its local web server. Three people join with
controllers' worth of seats (overlay joins), two phones wait in the local room
and take a seat of their own with `/api/local-room/phone-seat`. The host then
reports both phones as linked, a fifth seat appears past the four controller
seats, and the phone game (two phones needed), first in the queue, is warmed
in place of the controller game that was warm for the three.
"""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
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

    def until(self, predicate, what):
        deadline = time.monotonic() + 15
        while not predicate(self.party):
            if time.monotonic() > deadline:
                raise AssertionError(f"timed out waiting for {what}: {json.dumps(self.party)[:2000]}")
            message = self.read()
            if message["type"] == "party_state":
                self.party = message["party"]
        return self.party


def game_loop(port, game_id, stop, prepared):
    peer = Peer(port, "game", game_id)
    peer.socket.settimeout(None)
    try:
        while not stop.is_set():
            message = peer.read()
            if message["type"] == "prepare":
                prepared.append((game_id, message["seats"]))
                peer.send({"type": "ready", "session": message["session"]})
    except (OSError, ValueError):
        pass


def post(path, body):
    request = urllib.request.Request(WEB + path, json.dumps(body).encode(), {"Content-Type": "application/json"})
    try:
        return urllib.request.urlopen(request, timeout=10).status
    except urllib.error.HTTPError as error:
        return error.code


def main():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    with tempfile.TemporaryDirectory(prefix="gamenight-phones-") as temporary:
        temp = Path(temporary)
        shelf = [
            {"id": "cards", "title": "Cards", "min_players": 2, "max_players": 6, "play_with": "phone"},
            {"id": "duo", "title": "Duo", "min_players": 1, "max_players": 4},
        ]
        (temp / "shelf.json").write_text(json.dumps(shelf))
        env = {k: v for k, v in os.environ.items() if not k.startswith("GAMENIGHT")}
        env.update(GAMENIGHT_OFFLINE="1", GAMENIGHT_ADDR=f"127.0.0.1:{port}", GAMENIGHT_LIBRARY=str(temp / "shelf.json"),
                   GAMENIGHT_WEB="1", GAMENIGHT_NO_MUSIC="1", GAMENIGHT_TEST_NO_CONTROLLERS="1",
                   GAMENIGHT_DATA_DIR=str(temp / "data"), HOME=str(temp))
        target = Path(os.environ.get("CARGO_TARGET_DIR", ROOT / "target"))
        daemon = os.environ.get("GAMENIGHT_TEST_DAEMON", str(target / "debug" / "gamenight-daemon"))
        log_path = ROOT / ".local" / "phone-players.log"
        log_path.parent.mkdir(exist_ok=True)
        stop = threading.Event()
        prepared = []
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
                for name in ("Nora", "Jamal", "Bo"):
                    overlay.send({"type": "join_party", "name": name})
                    overlay.until(lambda p, n=name: any(player["name"] == n for player in p["players"]), name)
                for game in ("cards", "duo"):
                    threading.Thread(target=game_loop, args=(port, game, stop, prepared), daemon=True).start()
                overlay.until(lambda p: set(p.get("connected_games", [])) >= {"cards", "duo"}, "games")
                overlay.send({"type": "set_playlist", "entries": [{"game": "cards", "title": "Cards"}, {"game": "duo", "title": "Duo"}]})
                overlay.until(lambda p: (p.get("warm_session") or {}).get("game") == "duo", "duo warm for three")

                deadline = time.monotonic() + 15
                while True:
                    try:
                        room = json.loads(urllib.request.urlopen(WEB + "/api/player-links", timeout=3).read())["room"]
                        break
                    except OSError:
                        if time.monotonic() > deadline: raise
                        time.sleep(0.2)
                for name in ("Sanne", "Thijs"):
                    profile = "phone-" + name.lower()
                    assert post("/api/profiles", {"id": profile, "username": name, "skin_color": "#edc59a", "avatar": ""}) in (200, 204)
                    assert post("/api/local-room/join", {"code": room["room_code"], "profile": profile}) == 204
                    status = post("/api/local-room/phone-seat", {"profile": profile})
                    assert status == 204, f"phone seat for {name}: {status}"
                assert post("/api/local-room/phone-seat", {"profile": "phone-sanne"}) == 410, "seated phones no longer wait"

                party = overlay.until(lambda p: len(p.get("phones", [])) == 2, "two linked phones")
                assert len(party["players"]) == 5, party["players"]
                assert len(party["seats"]) == 5, "a fifth seat past the four controller seats"
                phone_seats = [s for s in party["seats"] if s["occupant"].get("player_id") in party["phones"]]
                assert all(s.get("controller") is None for s in phone_seats), phone_seats
                # Two phones make the phone game, first in the queue, playable.
                overlay.until(lambda p: (p.get("warm_session") or {}).get("game") == "cards", "cards warm for two phones")
                game, seats = prepared[-1]
                assert game == "cards" and sum(1 for s in seats if s["occupant"].get("player_id")) == 5, prepared[-1]
            finally:
                stop.set()
                try: os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError: pass
                process.wait(timeout=10)
    print("PASS phone players: phone seats, linked phones, phone game warmed")


if __name__ == "__main__":
    main()
