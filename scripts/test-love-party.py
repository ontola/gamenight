"""Verify real LÖVE processes authenticate, prepare and exit when their host closes."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--love", required=True)
    parser.add_argument("--pack", type=Path, required=True)
    args = parser.parse_args()
    for game in ("bumper-royale", "neon-trails", "meteor-dash", "blast-party", "neon-siege"):
        with socket.socket() as server:
            server.bind(("127.0.0.1", 0))
            server.listen()
            server.settimeout(5)
            env = {**os.environ, "GAMENIGHT": "1", "GAMENIGHT_GAME_ID": game,
                   "GAMENIGHT_TOKEN": "fixture-token", "GNLOVE_HEADLESS": "1",
                   "GAMENIGHT_ADDR": f"127.0.0.1:{server.getsockname()[1]}"}
            env.pop("GNLOVE_TEST", None)
            child = subprocess.Popen([args.love, str((args.pack / f"{game}.love").resolve())],
                                     env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            try:
                with server.accept()[0] as peer:
                    peer.settimeout(5)
                    with peer.makefile("rwb", buffering=0) as stream:
                        hello = json.loads(stream.readline())
                        assert hello["type"] == "hello" and hello["game"] == game and hello["token"] == "fixture-token"
                        stream.write((json.dumps({"type": "welcome", "protocol_version": 1})+"\n").encode())
                        stream.write((json.dumps({"type": "prepare", "game": game, "session": "session-one",
                                                   "seats": [{"index": 0, "occupant": {"kind": "ai"}},
                                                             {"index": 2, "occupant": {"kind": "ai"}}], "players": []})+"\n").encode())
                        assert json.loads(stream.readline()) == {"type": "ready", "session": "session-one"}
                        stream.write(b'{"type":"start","session":"session-one"}\n')
                child.wait(timeout=5)
                assert child.returncode == 0, child.communicate()[0].decode(errors="replace")
                print(f"PASS {game}: authenticated, prepared sparse seats, exited after host disconnect")
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=5)

if __name__ == "__main__":
    main()
