#!/usr/bin/env python3
"""Check the SDK's shared fake host (sdk/godot/addons/gamenight/fake_host.py)
against a game made from the Godot template: lifecycle, a setting, a held
stick, a press, pause, resume and dispose.

    python3 scripts/test-godot-fake-host.py --godot /path/to/godot
"""
import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "sdk/godot/addons/gamenight"))
from fake_host import BUTTON_A, FakeHost, frame  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--godot", default="godot")
    godot = ap.parse_args().godot
    with tempfile.TemporaryDirectory() as tmp:
        game = Path(tmp) / "fake-host-test"
        subprocess.run([sys.executable, str(ROOT / "scripts/new-godot-game.py"), str(game), "fake-host-test", "Fake Host Test"],
                       check=True, capture_output=True)
        assert (game / "addons/gamenight/fake_host.py").is_file(), "new games get the fake host"
        subprocess.run([godot, "--headless", "--import", "--path", str(game)], capture_output=True, timeout=300)
        game_id = json.loads((game / "gamenight.json").read_text())["id"]
        with FakeHost(godot, game_id, path=game) as host:
            host.welcome(godot_sdk=99)
            host.expect("declare_settings")
            host.saw("is older than GameNight")
            print("ok: hello, settings, and the warning for an older addon")
            host.setting("round_seconds", 30)
            host.saw("setting round_seconds = 30")
            host.prepare([host.local_seat(0, "ada"), host.ai_seat(1)], [{"id": "ada", "name": "Ada", "color": "#3d8fe0"}])
            host.start()
            host.saw("running")
            host.hold(frame(left=(1, 0), controller="pad0"), 1.0)
            host.saw("moved Ada")
            host.hold(frame(BUTTON_A, controller="pad0"), 0.1)
            host.saw("dash Ada")
            print("ok: prepare, start, a held stick and a press")
            host.pause()
            host.saw("paused")
            host.resume()
            host.dispose()
            host.saw("disposed")
            assert host.count("ready") == 1 and host.messages[0]["type"] == "hello", host.messages
            print("ok: pause, resume and dispose")
            host.disconnect()
            assert host.exit_code(15) == 0, host.output()
            print("ok: the game quits when the host goes away")
    print("fake host: all good")
    return 0


if __name__ == "__main__":
    sys.exit(main())
