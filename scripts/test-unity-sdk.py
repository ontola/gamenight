#!/usr/bin/env python3
"""Test the Unity SDK and the Orb Rush demo without Unity.

The SDK core (sdk/unity/Runtime/Core) and the demo's rules
(examples/unity-demo/Assets/OrbRush/OrbRushGame.cs) are plain C#. This builds
them into a console game with dotnet (sdk/unity/Tests~/Harness), checks that
bots play a deterministic run, and plays every GameNight feature against the
fake host: lifecycle, input, Start menu, settings, per-player settings, phone
buttons, plain-text requests, phone screens, live roster, saves, room log,
activity and quitting when the host goes away. It also compiles the Unity
layer and the demo view against Unity's reference assemblies.

    python3 scripts/test-unity-sdk.py            # needs dotnet 8 on PATH
    python3 scripts/test-unity-sdk.py --binary out/orb-rush-headless

A real Unity build is not covered: window handling, faces on screen and pads.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "sdk/godot/addons/gamenight"))
from fake_host import BUTTON_A, BUTTON_START, FakeHost, frame  # noqa: E402

HARNESS = ROOT / "sdk/unity/Tests~/Harness"
UNITY_COMPILE = ROOT / "sdk/unity/Tests~/UnityCompile"


def build(out: Path) -> Path:
    subprocess.run(["dotnet", "build", str(HARNESS), "-c", "Release", "-o", str(out), "--nologo", "-v", "q"], check=True)
    name = "orb-rush-headless.exe" if os.name == "nt" else "orb-rush-headless"
    return out / name


def sim(binary: Path, seed: int) -> str:
    out = subprocess.run([str(binary), "--sim", "4000", "--seed", str(seed)], capture_output=True, text=True, timeout=120)
    if out.returncode != 0 or "sim: ok" not in out.stdout:
        raise SystemExit(f"sim failed:\n{out.stdout}\n{out.stderr}")
    return re.search(r"hash (\w+)", out.stdout).group(1)


def lifecycle(binary: Path) -> None:
    ada, bo = {"id": "ada", "name": "Ada", "color": "#e8553d", "couch": 1}, {"id": "bo", "name": "Bo", "couch": 0}
    with FakeHost("", game_id="unity-demo", command=[str(binary)], timeout=20) as host:
        host.welcome()
        declared = host.expect("declare_settings")
        keys = [s["key"] for s in declared["settings"]]
        assert keys == ["round_seconds", "orbs", "bumps", "body"], keys
        assert declared["settings"][3]["scope"] == "player", declared
        actions = host.expect("declare_actions")
        assert [a["key"] for a in actions["actions"]] == ["new_round", "shuffle"], actions
        assert actions["actions"][0]["confirm"] is True
        host.expect("declare_commands", lambda m: "8 orbs" in m["examples"])

        host.send({"type": "player_settings", "game": "unity-demo", "player_id": "ada", "values": {"body": "cube"}})
        host.saw("body ada")
        host.prepare([host.local_seat(0, "ada"), host.ai_seat(1), {"index": 2, "occupant": {"kind": "empty"}}], [ada], wait_ready=False)
        host.expect("participation", lambda m: m["instant_join"] is True)
        host.expect("progress", lambda m: m["percent"] == 100)
        host.expect("ready", lambda m: m["session"] == "s1")
        host.saw("seated Ada (seat 0), bot")
        print("ok: prepare, participation, progress, ready")

        host.start()
        host.saw("running")
        # The A that started the game from the lobby is still held: no dash yet.
        host.hold(frame(BUTTON_A), 0.3)
        host.hold(frame(BUTTON_A), 0.2)
        host.saw("dash Ada")
        host.hold(frame(left=(0.9, 0.0)), 0.3)
        host.expect("controller_input", lambda m: m["controller"] == "pad0")
        print("ok: input per seat, release after start, activity")

        host.hold(frame(BUTTON_START), 0.15)
        host.saw("menu open")
        for stick in [(0.0, 1.0), (0.0, 1.0), (0.0, 1.0), (1.0, 0.0)]:  # down to Orbs, then right
            host.hold(frame(left=stick), 0.15)
        menu = host.expect("set_setting")
        assert menu["key"] == "orbs" and menu["value"] == 7, menu
        host.hold(frame(BUTTON_START), 0.15)
        host.saw("menu closed")
        print("ok: Start menu changes settings through GameNight")

        host.setting("orbs", 9)
        host.saw("setting orbs = 9")
        host.setting("bumps", False)
        host.saw("setting bumps = false")
        host.send({"type": "action_triggered", "key": "new_round", "player_id": "ada"})
        host.saw("action new_round")
        host.expect("room_log", lambda m: m["text"].startswith("Round "))
        host.send({"type": "game_command", "game": "unity-demo", "player_id": "ada", "id": "r-1", "text": "8 orbs please"})
        assert host.expect("set_setting")["value"] == 8
        assert host.expect("command_result", lambda m: m["id"] == "r-1")["ok"] is True
        host.send({"type": "game_command", "game": "unity-demo", "player_id": "ada", "id": "r-2", "text": "sing a song"})
        assert host.expect("command_result", lambda m: m["id"] == "r-2")["ok"] is False
        print("ok: settings, phone buttons, room log, plain-text requests")

        host.phone("ada", connected=True)
        view = host.expect("companion_message", lambda m: m.get("player_id") == "ada")
        assert view["data"]["name"] == "Ada", view
        host.phone("ada", data={"action": "boost"})
        host.saw("boost Ada")
        host.phone("ada", data={"action": "explode"})  # untrusted input is ignored
        print("ok: phone screen")

        host.send({"type": "players_updated", "session": "s1", "players": [dict(ada, name="Ada L")]})
        host.saw("players updated")
        host.send({"type": "party_updated", "session": "s1", "presence": [],
                   "seats": [host.local_seat(0, "ada"), host.ai_seat(1), host.local_seat(2, "bo")],
                   "players": [dict(ada, name="Ada L"), bo]})
        host.saw("joined seat 2")
        print("ok: live roster and profile updates")

        host.pause()
        host.saw("paused")
        host.resume()
        host.saw("running")

        # A short round, so it ends: results, finished, saves and the room log.
        host.send({"type": "game_command", "game": "unity-demo", "player_id": "ada", "id": "r-3", "text": "rounds of 20 seconds"})
        assert host.expect("set_setting")["value"] == 20
        host.setting("round_seconds", 20)
        host.send({"type": "action_triggered", "key": "new_round", "player_id": "ada"})
        host.expect("room_log", lambda m: " won with " in m["text"], timeout=30)
        save = host.accept_saves()
        assert "best" in save["data"] and save["expected_revision"] == 0, save
        host.expect("finished", lambda m: m["session"] == "s1")
        print("ok: round end, finished, saved progress")

        host.dispose()
        host.saw("disposed")
        host.prepare([host.local_seat(0, "ada")], [ada], session="s2")
        host.saw("seated Ada (seat 0)")
        print("ok: dispose and a second session in the same process")

        host.disconnect()
        assert host.exit_code(10) == 0
        print("ok: quits when GameNight goes away")


def unity_compile() -> None:
    subprocess.run(["dotnet", "build", str(UNITY_COMPILE), "--nologo", "-v", "q"], check=True)
    print("ok: Unity layer and demo view compile against UnityEngine reference assemblies")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", help="an already built orb-rush-headless")
    ap.add_argument("--skip-unity-compile", action="store_true")
    args = ap.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        binary = Path(args.binary) if args.binary else build(Path(tmp) / "out")
        first, again, other = sim(binary, 1), sim(binary, 1), sim(binary, 2)
        if first != again:
            raise SystemExit(f"the same seed gave two runs: {first} {again}")
        if first == other:
            raise SystemExit("different seeds gave the same run")
        print("ok: deterministic bots, seed", first)
        started = time.monotonic()
        lifecycle(binary)
        print(f"lifecycle took {time.monotonic() - started:.0f} s")
    if not args.skip_unity_compile:
        unity_compile()
    print("unity sdk: all good")
    return 0


if __name__ == "__main__":
    sys.exit(main())
