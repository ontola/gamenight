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
            GAMENIGHT_WEB_ADDR=f"127.0.0.1:{web_port}",
            GAMENIGHT_NO_PREWARM="1", GAMENIGHT_NO_LOBBY_WATCH="1", GAMENIGHT_NO_MUSIC="1",
            GAMENIGHT_LIBRARY=str(root / "shelf.json"), GAMENIGHT_CATALOG=str(root / "catalog"),
            GAMENIGHT_ONBOARDING_FILE=str(root / "onboarding.json"), GAMENIGHT_DATA_DIR=str(root),
            PATH=str(root) + ":/usr/bin:/bin",
        )
        (root / "shelf.json").write_text(json.dumps([
            {"id": "test-game", "title": "Test Game", "players": "2-4", "min_players": 2, "max_players": 4}
        ]))
        (root / "catalog").mkdir()
        (root / "catalog/test-game.json").write_text(json.dumps({
            "id": "test-game", "title": "Test Game", "players": {"min": 2, "max": 4},
            "integration": {"level": "integrated", "protocol": 1},
            "price": "free", "downloads": {"linux": {
                "url": "https://example.test/game.zip", "sha256": "a" * 64, "entrypoint": "game"
            }}
        }))
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

        def claim(ticket, game):
            request = urllib.request.Request(
                f"http://127.0.0.1:{web_port}/api/onboarding",
                data=json.dumps({"ticket": ticket, "game": game}).encode(),
                headers={"Content-Type": "application/json"},
            )
            try:
                with urllib.request.urlopen(request, timeout=15) as response:
                    return response.status, json.load(response)
            except urllib.error.HTTPError as error:
                return error.code, None

        def playlist():
            with urllib.request.urlopen(f"http://127.0.0.1:{web_port}/api/playlist", timeout=15) as response:
                return json.load(response)

        try:
            with (root / "log").open("w") as log:
                def start():
                    for name in ["gamenight-daemon", "gamenight-local-web"]:
                        children.append(subprocess.Popen([str(binary / name)], env=env, stdout=log, stderr=log))
                start()
                for _ in range(100):
                    if (root / "opened-url").exists():
                        break
                    time.sleep(.1)
                opened = urllib.parse.urlparse((root / "opened-url").read_text())
                assert opened.scheme == "https" and opened.netloc == "gamenight.ontola.io"
                params = urllib.parse.parse_qs(opened.fragment)
                ticket = params["desktop"][0]
                assert params["port"] == [str(web_port)] and len(ticket) == 32
                assert claim("wrong", "test-game")[0] == 403
                for game in ["../../anything", "lobby", "demo-game", "unknown"]:
                    assert claim(ticket, game)[0] == 422
                status, body = claim(ticket, "test-game")
                assert status == 200 and body["accepted"], (status, body)
                saved = json.loads((root / "onboarding.json").read_text())
                assert saved == {"complete": False, "game": "test-game"}
                assert claim(ticket, "test-game")[0] == 200
                assert claim(ticket, "another-game")[0] == 409
                view = playlist()
                assert view["next"] == "test-game" and view["playing"] is None, view
                stop()
                (root / "opened-url").unlink()
                start()
                for _ in range(100):
                    try:
                        view = playlist()
                        if view["next"] == "test-game":
                            break
                    except (urllib.error.URLError, TimeoutError):
                        pass
                    time.sleep(.1)
                assert view["next"] == "test-game" and view["playing"] is None, view
                assert not (root / "opened-url").exists(), "Saved choice should not reopen the picker"
                print("PASS: first-run capability, catalog validation, host acknowledgement, no automatic start, retry and restart recovery")
        except Exception:
            print((root / "log").read_text(), file=sys.stderr)
            raise
        finally:
            stop()


if __name__ == "__main__":
    main()
