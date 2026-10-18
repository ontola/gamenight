#!/usr/bin/env python3
"""Plays a fake GameNight host against the game, headless.

Checks the session lifecycle and the controller path: hello, declared
settings and a change from the party, prepare with a local seat and a bot
seat, ready, start, the left stick moves seat 0, A dashes, Start opens the
settings menu, a change there is sent to GameNight, B closes it, pause, resume and dispose. Grow it with every control you add.

    python3 tests/lifecycle.py [--godot path/to/godot] [--pack game.pck]   (needs `websockets`)
"""
import argparse
import asyncio
import json
import os
import subprocess
import sys
from pathlib import Path

import websockets

ROOT = Path(__file__).resolve().parents[1]
GAME_ID = json.loads((ROOT / "gamenight.json").read_text())["id"]
PORT = 7941
A, B, START = 0, 1, 7


def frame(buttons=0, move=(0, 0)):
    axes = [move[0], move[1], 0, 0, 0, 0]
    return {"type": "controller_frame", "controllers": [{"controller": "pad1", "axes": axes, "buttons": buttons}]}


async def run(godot: str, pack: str = "") -> None:
    inbox: asyncio.Queue = asyncio.Queue()
    conn = {}
    lines: list[str] = []

    async def handler(ws):
        conn["ws"] = ws
        try:
            async for text in ws:
                await inbox.put(json.loads(text))
        except websockets.ConnectionClosed:
            pass

    async def expect(kind, check=lambda m: True, timeout=30.0):
        loop = asyncio.get_running_loop()
        end = loop.time() + timeout
        while True:
            left = end - loop.time()
            if left <= 0:
                raise AssertionError(f"timed out waiting for {kind}")
            m = await asyncio.wait_for(inbox.get(), left)
            if m.get("type") == kind and check(m):
                return m

    async def send(msg):
        await conn["ws"].send(json.dumps(msg))

    async def hold(msg, seconds):
        # The SDK treats input older than 250 ms as released, so keep sending.
        for _ in range(int(seconds / 0.05)):
            await send(msg)
            await asyncio.sleep(0.05)

    async def read_stdout(proc):
        loop = asyncio.get_running_loop()
        while line := await loop.run_in_executor(None, proc.stdout.readline):
            lines.append(line.decode(errors="replace").strip())

    async def saw(text, timeout=8.0):
        loop = asyncio.get_running_loop()
        end = loop.time() + timeout
        while loop.time() < end:
            if any(text in line for line in lines):
                return
            await asyncio.sleep(0.1)
        raise AssertionError(f"game never printed {text!r}; last lines: {lines[-8:]}")

    async with websockets.serve(handler, "127.0.0.1", PORT):
        env = dict(os.environ, GAMENIGHT="1", GAMENIGHT_ADDR=f"127.0.0.1:{PORT}",
                   GAMENIGHT_GAME_ID=GAME_ID, GAMENIGHT_TOKEN="t", GAME_TRACE="1")
        game = ["--main-pack", pack] if pack else ["--path", str(ROOT)]
        proc = subprocess.Popen([godot, "--headless", *game], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        reader = asyncio.create_task(read_stdout(proc))
        try:
            hello = await expect("hello")
            assert hello["game"] == GAME_ID and hello.get("token") == "t", hello
            await send({"type": "welcome", "party": {}})
            declared = await expect("declare_settings")
            keys = {s["key"] for s in declared["settings"]}
            assert keys == {"round_seconds", "orbs"}, keys
            await send({"type": "setting_changed", "game": GAME_ID, "key": "round_seconds", "value": 30})
            await saw("setting round_seconds = 30")
            print("ok: settings declared and changed by the party")
            seats = [
                {"index": 0, "controller": "pad1", "occupant": {"kind": "local", "player_id": "ada"}},
                {"index": 1, "occupant": {"kind": "ai"}},
            ]
            players = [{"id": "ada", "name": "Ada", "color": "#3d8fe0"}]
            await send({"type": "prepare", "game": GAME_ID, "session": "s1", "seats": seats, "players": players})
            await expect("ready", lambda m: m.get("session") == "s1")
            await saw("seated Ada (seat 0), bot")
            await send({"type": "start", "session": "s1"})
            await saw("running")
            print("ok: prepared, ready and started")

            await hold(frame(move=(32767, 0)), 1.0)
            await saw("moved Ada")
            print("ok: the left stick moves seat 0")
            await hold(frame(1 << A), 0.1)
            await hold(frame(), 0.2)
            await saw("dash Ada")
            print("ok: A dashes")

            await hold(frame(1 << START), 0.15)
            await hold(frame(), 0.2)
            await saw("menu open")
            await hold(frame(move=(32767, 0)), 0.15)
            await hold(frame(), 0.15)
            changed = await expect("set_setting")
            assert (changed["key"], changed["value"]) == ("round_seconds", 40), changed
            print("ok: the menu writes the setting back to GameNight")
            await hold(frame(1 << B), 0.15)
            await hold(frame(), 0.2)
            await saw("menu closed")
            print("ok: Start opens the settings menu, B closes it")

            await send({"type": "pause", "session": "s1"})
            await saw("paused")
            await send({"type": "resume", "session": "s1"})
            await saw("running")
            print("ok: pause and resume")
            await send({"type": "dispose", "session": "s1"})
            await saw("disposed")
            print("ok: disposed")
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
            reader.cancel()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    ap.add_argument("--pack", default="")
    args = ap.parse_args()
    asyncio.run(run(args.godot, args.pack))
    print("lifecycle: all good")
    return 0


if __name__ == "__main__":
    sys.exit(main())
