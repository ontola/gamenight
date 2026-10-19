"""Verify real LÖVE processes authenticate, prepare and exit when their host closes."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import select
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "sdk/python"))
import gamenight_protocol as P  # noqa: E402  (generated from contract/protocol.schema.json)


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
            env = {**os.environ, P.ENV_GAMENIGHT: "1", P.ENV_GAME_ID: game,
                   P.ENV_TOKEN: "fixture-token", "GNLOVE_HEADLESS": "1",
                   P.ENV_ADDR: f"127.0.0.1:{server.getsockname()[1]}"}
            env.pop("GNLOVE_TEST", None)
            if args.continuous: env["GNLOVE_MATCH_SECONDS"] = "1"
            child = subprocess.Popen([args.love, str((args.pack / f"{game}.love").resolve())],
                                     env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            try:
                with server.accept()[0] as peer:
                    peer.settimeout(5)
                    with peer.makefile("rwb", buffering=0) as stream:
                        hello = json.loads(stream.readline())
                        assert hello["type"] == P.MSG_HELLO and hello["game"] == game and hello["token"] == "fixture-token"
                        stream.write((json.dumps({"type": P.MSG_WELCOME, "protocol_version": P.PROTOCOL_VERSION})+"\n").encode())
                        declaration = json.loads(stream.readline())
                        assert declaration.get("type") == P.MSG_DECLARE_SETTINGS and declaration.get("settings"), declaration
                        specs = declaration["settings"]
                        assert len({s["key"] for s in specs}) == len(specs), "duplicate setting keys"
                        for spec in specs:
                            value = (not spec["default"] if spec["kind"] == P.SETTING_KIND_TOGGLE else
                                     spec["options"][-1] if spec["kind"] == P.SETTING_KIND_CHOICE else spec["min"])
                            stream.write((json.dumps({"type": P.MSG_SETTING_CHANGED, "key":spec["key"], "value":value})+"\n").encode())
                        stream.write((json.dumps({"type": P.MSG_PREPARE, "game": game, "session": "session-one",
                                                   "seats": [{"index": 0, "occupant": {"kind": P.SEAT_OCCUPANT_AI}},
                                                             {"index": 2, "occupant": {"kind": P.SEAT_OCCUPANT_AI}}], "players": []})+"\n").encode())
                        reply = json.loads(stream.readline())
                        while reply.get("type") in (P.MSG_PARTICIPATION, P.MSG_DECLARE_SETTINGS):
                            if reply["type"] == P.MSG_PARTICIPATION: assert reply["session"] == "session-one"
                            reply = json.loads(stream.readline())
                        assert reply == {"type": P.MSG_READY, "session": "session-one"}, reply
                        stream.write((json.dumps({"type": P.MSG_START, "session": "session-one"})+"\n").encode())
                        if args.continuous:
                            def round_finished():
                                deadline = time.monotonic() + 10
                                while time.monotonic() < deadline:
                                    peer.settimeout(max(.1, deadline - time.monotonic()))
                                    message = json.loads(stream.readline())
                                    if message["type"] == P.MSG_FINISHED:
                                        assert message["session"] == "session-one"
                                        return
                                    assert message["type"] == P.MSG_CONTROLLER_INPUT, message
                                raise AssertionError("round did not finish")
                            round_finished()
                            stream.write((json.dumps({"type": P.MSG_PAUSE, "session": "session-one"})+"\n").encode())
                            # Longer than results + another round: paused games must not loop.
                            time.sleep(4.5)
                            assert not select.select([peer], [], [], 0)[0], "game advanced while paused"
                            stream.write((json.dumps({"type": P.MSG_RESUME, "session": "session-one"})+"\n").encode())
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
