#!/usr/bin/env python3
"""Exercise first-run selection against real local HTTP and daemon binaries.

Linux CI uses a fixture catalog and a captured browser opener. This verifies the
handoff and interrupted-setup recovery, not downloading or running a game.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def unused_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary-dir", type=Path, default=ROOT / "target/debug")
    args = parser.parse_args()
    if sys.platform != "linux":
        parser.error("The captured xdg-open fixture runs on Linux.")
    binary = args.binary_dir.resolve()
    with tempfile.TemporaryDirectory(prefix="gamenight-handoff-") as directory:
        root = Path(directory)
        daemon_port, web_port = unused_port(), unused_port()
        env = {k: v for k, v in os.environ.items() if not k.startswith("GAMENIGHT_")}
        env.update(
            GAMENIGHT_ADDR=f"127.0.0.1:{daemon_port}",
            GAMENIGHT_HOST_SERVICES_ADDR=f"127.0.0.1:{web_port}",
            GAMENIGHT_CLOUD_URL="https://127.0.0.1:1", GAMENIGHT_PLAYER_MEMORY=str(root / "players.json"),
            GAMENIGHT_NO_PREWARM="1", GAMENIGHT_NO_LOBBY_WATCH="1", GAMENIGHT_NO_MUSIC="1",
            GAMENIGHT_LIBRARY=str(root / "shelf.json"), GAMENIGHT_CATALOG=str(root / "catalog"),
            GAMENIGHT_ONBOARDING_FILE=str(root / "onboarding.json"), GAMENIGHT_DATA_DIR=str(root),
            PATH=str(root) + ":/usr/bin:/bin",
        )
        (root / "shelf.json").write_text(json.dumps([
            {"id": "test-game", "title": "Test Game", "players": "2-4", "min_players": 2, "max_players": 4},
            {"id": "second-game", "title": "Second Game", "players": "2-4", "min_players": 2, "max_players": 4}
        ]))
        (root / "catalog").mkdir()
        (root / "catalog/test-game.json").write_text(json.dumps({
            "id": "test-game", "title": "Test Game", "players": {"min": 2, "max": 4},
            "integration": {"level": "integrated", "protocol": 1},
            "price": "free", "downloads": {"linux": {
                "url": "https://example.test/game.zip", "sha256": "a" * 64, "entrypoint": "game"
            }}
        }))
        second = json.loads((root / "catalog/test-game.json").read_text())
        second.update(id="second-game", title="Second Game")
        (root / "catalog/second-game.json").write_text(json.dumps(second))
        (root / "onboarding.json").write_text('{"complete":false}')
        (root / "xdg-open").write_text('#!/bin/sh\nprintf "%s" "$1" > "' + str(root / "opened-url") + '"\n')
        (root / "xdg-open").chmod(0o700)
        children = []

        def stop():
            for child in children:
                child.terminate()
            for child in children:
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            children.clear()

        def request(game):
            temporary = root / "request.tmp"
            temporary.write_text(json.dumps({"game":game}))
            temporary.replace(root / "catalog-request.json")

        def wait_saved(game):
            for _ in range(100):
                saved = json.loads((root / "onboarding.json").read_text())
                if saved.get("game") == game:
                    return saved
                time.sleep(.1)
            raise AssertionError("Host did not accept selection")

        try:
            with (root / "log").open("w") as log:
                def start():
                    for name in ["gamenight-daemon", "gamenight-host-services"]:
                        children.append(subprocess.Popen([str(binary / name)], env=env, stdout=log, stderr=log))
                start()
                for _ in range(100):
                    if (root / "opened-url").exists():
                        break
                    time.sleep(.1)
                opened = urllib.parse.urlparse((root / "opened-url").read_text())
                assert opened.scheme == "https" and opened.netloc == "127.0.0.1:1"
                assert opened.fragment == "setup=linux"
                for path in ["/", "/studio", "/onboarding", "/host/lobby", "/docs", "/api/onboarding"]:
                    try:
                        urllib.request.urlopen(f"http://127.0.0.1:{web_port}{path}")
                        raise AssertionError(f"Local page still served: {path}")
                    except urllib.error.HTTPError as error:
                        assert error.code == 404
                request("../../anything")
                time.sleep(.5)
                assert json.loads((root / "onboarding.json").read_text()) == {"complete":False}
                request("test-game")
                assert wait_saved("test-game")["complete"] is False
                request("second-game")
                wait_saved("second-game")
                stop()
                start()
                time.sleep(2)
                assert json.loads((root / "onboarding.json").read_text())["game"] == "second-game"
                request(None)
                for _ in range(100):
                    if json.loads((root / "onboarding.json").read_text()) == {"complete":True}: break
                    time.sleep(.1)
                else: raise AssertionError("Lobby-only handoff not accepted")
                print("PASS: hosted setup, native game selection, interrupted download recovery, no local pages")
        finally:
            stop()


if __name__ == "__main__":
    main()
