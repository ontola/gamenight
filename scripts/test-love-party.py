"""Verify real LÖVE processes authenticate, prepare and exit when their host closes."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import select


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--love", required=True)
    parser.add_argument("--pack", type=Path, required=True)
    parser.add_argument("--continuous", action="store_true", help="Verify repeated rounds and pause during results")
    parser.add_argument("--game", help="Test only this packaged game")
    args = parser.parse_args()
    artifacts = sorted(args.pack.glob("*.love"))
    if args.game:
        artifacts = [p for p in artifacts if p.stem == args.game]
    if not artifacts:
        parser.error("No matching packaged games")
    for artifact in artifacts:
        game = artifact.stem
        with socket.socket() as server:
            server.bind(("127.0.0.1", 0))
            server.listen()
            server.settimeout(5)
            env = {**os.environ, "GAMENIGHT": "1", "GAMENIGHT_GAME_ID": game,
                   "GAMENIGHT_TOKEN": "fixture-token", "GNLOVE_HEADLESS": "1",
                   "GAMENIGHT_ADDR": f"127.0.0.1:{server.getsockname()[1]}"}
            env.pop("GNLOVE_TEST", None)
            if args.continuous: env["GNLOVE_MATCH_SECONDS"] = "1"
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
                        reply = json.loads(stream.readline())
                        if reply.get("type") == "participation":
                            assert reply["session"] == "session-one"
                            reply = json.loads(stream.readline())
                        assert reply == {"type": "ready", "session": "session-one"}, reply
                        stream.write(b'{"type":"start","session":"session-one"}\n')
                        if args.continuous:
                            def round_finished():
                                deadline = time.monotonic() + 10
                                while time.monotonic() < deadline:
                                    peer.settimeout(max(.1, deadline - time.monotonic()))
                                    message = json.loads(stream.readline())
                                    if message["type"] == "finished":
                                        assert message["session"] == "session-one"
                                        return
                                    assert message["type"] == "controller_input", message
                                raise AssertionError("round did not finish")
                            round_finished()
                            stream.write(b'{"type":"pause","session":"session-one"}\n')
                            # Longer than results + another round: paused games must not loop.
                            time.sleep(4.5)
                            assert not select.select([peer], [], [], 0)[0], "game advanced while paused"
                            stream.write(b'{"type":"resume","session":"session-one"}\n')
                            round_finished()
                            round_finished()
                            print(f"PASS {game}: three rounds in one session; results pause/resume")
                child.wait(timeout=5)
                assert child.returncode == 0, child.communicate()[0].decode(errors="replace")
                print(f"PASS {game}: authenticated, prepared sparse seats, exited after host disconnect")
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=5)

if __name__ == "__main__":
    main()
