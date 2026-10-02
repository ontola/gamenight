"""Integration check against a real running server and two connected clients.
Does not synthesize controller input or claim visual verification.
"""
import argparse
import json
from pathlib import Path
import uuid
from prototype import command

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--root", type=Path, default=Path("E:/gamenight-host/prototypes/mineclonia"))
    args = p.parse_args()
    before = command(args.root, "status")["state"]
    assert len(before["players"] or []) == 2, "Connect both real clients first"
    assert not before["can_undo"], "Keep or undo your existing change first"
    request_id = uuid.uuid4().hex
    revision = before["revision"]
    try:
        applied = command(args.root, "set", {"gravity": 0.5, "jump": 1.4}, revision, request_id)
        assert applied["ok"], applied
        assert applied["state"]["revision"] == revision + 1
        for player in applied["state"]["players"]:
            assert abs(player["physics"]["gravity"] - 0.5) < 0.001, player
            assert abs(player["physics"]["jump"] - 1.4) < 0.001, player
        duplicate = command(args.root, "set", {"gravity": 0.5, "jump": 1.4}, revision, request_id)
        assert duplicate == applied, "Retry must return original result"
        stale = command(args.root, "set", {"jump": 1.8}, revision)
        assert not stale["ok"], "Stale change must fail"
        invalid = command(args.root, "set", {"gravity": -1}, revision + 1)
        assert not invalid["ok"], "Invalid gravity must fail"
    finally:
        current = command(args.root, "status")["state"]
        if current["revision"] == revision + 1:
            restored = command(args.root, "undo", expected=revision + 1)
            assert restored["ok"], restored
            assert restored["state"]["values"] == before["values"]
            originals = {p["name"]: p["physics"] for p in before["players"]}
            for player in restored["state"]["players"]:
                for key in ("gravity", "jump"):
                    assert abs(player["physics"][key] - originals[player["name"]][key]) < 0.001
    print(json.dumps({"ok": True, "players": [p["name"] for p in before["players"]],
        "checks": ["shared live physics", "undo", "idempotency", "stale revision", "range validation"],
        "not_tested": ["controllers", "camera input", "inventory", "audio", "frame rate"]}, indent=2))


if __name__ == "__main__":
    main()
