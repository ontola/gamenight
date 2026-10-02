"""Experimental local cloud adapter. Uses a real isolated Mineclonia world.

Launches use the real daemon; settings use the isolated world bridge.
No arbitrary code, shell commands or downloaded executables are accepted.
"""
import argparse
import json
import math
from pathlib import Path
import time
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from host import Host, GAME
import modding
from prototype import command, read_json
from capabilities import controls, valid


def snapshot(root, instance, receipt=None, host=None, allow_loading=False):
    path = root / "world" / "gamenight" / "status.json"
    if not path.exists() or time.time() - path.stat().st_mtime > 5:
        if host and allow_loading:
            # Pairing belongs to the party, even before a game world is ready.
            return {"seats": host.seats(host.status()), "discovery": {"games": [{"id":"mineclonia", "selectable":False,"state":"loading"}], "current":"mineclonia", "agent_receipt":receipt}}
        raise RuntimeError("World heartbeat is stale")
    state = read_json(path)
    players = {p["name"] for p in state.get("players") or []}
    seats = [{"index": i, "player": f"Couch{i+1}", "revision": 1}
             for i in range(2) if f"Couch{i+1}" in players]
    phase = "playing"
    if host:
        party = host.status()
        seats = host.seats(party)
        session = party.get("active_session") or party.get("warm_session") or {}
        if session.get("game") != GAME:
            if allow_loading:
                return {"seats":seats,"discovery":{"games":[{"id":"mineclonia","selectable":False,"state":"available"}],"agent_receipt":receipt}}
            raise RuntimeError("Mineclonia is not prepared in this lobby")
        instance = session["id"]
        phase = "playing" if session.get("phase") == "running" else "ready" if session.get("phase") in ("paused", "ready") else "loading"
    return {"seats": seats, "discovery": {
        "games": [{"id": "mineclonia", "selectable": True, "state": phase}],
        "current": "mineclonia", "agent_receipt": receipt,
        "controls": {"game": "mineclonia", "instance": instance,
                     "revision": state["revision"], "can_undo": state["can_undo"],
                     "launch_players": 2 if host else None,
                     "mod_recipes": ["bounce_pad"] if host and "bounce" not in state["values"] else [],
                     "can_undo_mod": bool(state.get("can_undo_mod")),
                     "settings": controls(state["values"])}}}


def execute(root, instance, selection, host=None):
    current = snapshot(root, instance, host=host)
    if selection.get("expires", 0) <= time.time():
        raise ValueError("Request expired")
    if selection.get("seat") not in current["seats"]:
        raise ValueError("Player is no longer connected")
    c = selection.get("command") or {}
    if selection.get("game") != "mineclonia" or c.get("instance") != current["discovery"]["controls"]["instance"]:
        raise ValueError("Game instance changed")
    revision=c.get("expected_revision")
    if type(revision) is not int or revision < 0:
        raise ValueError("Missing game revision")
    if c.get("action") in ("mod", "undo_mod"):
        if not host:
            raise ValueError("Mods require the supervised lobby host")
        return modding.request(root, c.get("values"), c.get("expected_revision"), selection["id"], selection["seat"], selection["expires"], c["instance"], undo=c["action"] == "undo_mod")
    if c.get("action") == "launch":
        if not host or c.get("values") != {"players": 2}:
            raise ValueError("This host requires two joined controllers")
        if c.get("expected_revision") != current["discovery"]["controls"]["revision"]:
            raise ValueError("World changed before launch")
        host.launch(selection["seat"], 2, timeout=min(85, max(1, selection["expires"]-time.time())))
        return {"id": selection["id"], "ok": True, "message": "Mineclonia is running for two players."}
    if c.get("action") not in ("set", "keep", "undo"):
        raise ValueError("Unsupported action")
    values=c.get("values")
    if not isinstance(values,dict) or (c["action"] == "set" and not values):
        raise ValueError("Missing settings")
    if c["action"] != "set" and values:
        raise ValueError("Unexpected settings")
    for key,value in values.items():
        if not valid(key, value):
            raise ValueError("Unsupported setting or value")
    # Lua validates values, expected revision and durable duplicate requests again.
    result = command(root, c["action"], c.get("values") if c["action"] == "set" else None,
                     expected=c.get("expected_revision"), request_id=selection["id"])
    return {"id": selection["id"], "ok": result["ok"],
            "message": ("Applied to the running world. " + ", ".join(
                f"{k}: {v:g}" for k, v in result["state"]["values"].items()))
            if result["ok"] else result.get("error", "The host refused the change")}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root", type=Path, default=Path("E:/gamenight-host/prototypes/mineclonia"))
    p.add_argument("--base", default="http://127.0.0.1:7932")
    p.add_argument("--registration", type=Path, required=True)
    p.add_argument("--daemon-port", type=int, help="Use the real lobby seats and lifecycle")
    args = p.parse_args()
    host = Host(args.daemon_port) if args.daemon_port else None
    parsed = urllib.parse.urlparse(args.base)
    if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost"):
        raise ValueError("This test adapter only connects to a local cloud process")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def post(path, data, token=None):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        req = urllib.request.Request(args.base + path, json.dumps(data).encode(), headers)
        with opener.open(req, timeout=5) as response:
            body=response.read()
            return json.loads(body) if body else None
    registration = post("/v1/lobbies/register", {})
    instance, receipt = uuid.uuid4().hex, None
    registration["instance"] = instance
    args.registration.write_text(json.dumps(registration))
    print("Mineclonia relay connected. Room " + registration["room_code"], flush=True)
    worker = ThreadPoolExecutor(max_workers=1)
    pending, pending_id = None, None
    pairing, applied_profiles = {}, {}
    # Retain receipts across a relay restart. Never repeat a launch on retry.
    journal_path = args.root / "managed" / "agent-receipts.json"
    journal_path.parent.mkdir(exist_ok=True)
    journal = json.loads(journal_path.read_text()) if journal_path.exists() else {}
    def perform(selection):
        try:
            return execute(args.root, instance, selection, host)
        except (ValueError, RuntimeError, TimeoutError, OSError) as error:
            return {"id": selection["id"], "ok": False, "message": str(error)[:1000]}
    while True:
        try:
            if pending and pending.done():
                receipt = pending.result()
                journal[pending_id] = receipt
                temp = journal_path.with_suffix(".tmp")
                temp.write_text(json.dumps(journal))
                temp.replace(journal_path)
                pending = None
                print(receipt["message"], flush=True)
            response = post("/v1/lobbies/poll", snapshot(args.root, instance, receipt, host, allow_loading=True), registration["token"])
            if host:
                live_seats = host.seats(host.status())
                known = {s["player"]: s for s in live_seats}
                pairing = {key:value for key,value in pairing.items() if key in known}
                for seat in live_seats:
                    cached = pairing.get(seat["player"])
                    if not cached or cached["revision"] != seat["revision"] or cached["expires"] < time.time():
                        ticket = post("/v1/lobbies/ticket", {"index":seat["index"]}, registration["token"])
                        pairing[seat["player"]] = {"ticket":ticket["ticket"], "revision":seat["revision"], "expires":time.time()+180}
                linked=[]
                for update in response.get("updates", []):
                    seat = update.get("seat")
                    if seat not in live_seats: continue
                    player, profile = seat["player"], update["profile"]
                    linked.append(player)
                    key = (player, seat["revision"], update["profile_revision"])
                    if applied_profiles.get(player) != key:
                        for kind,field,value in [("rename_player","name",profile.get("display_name")),("set_player_skin_color","skin_color",profile.get("skin_color")),("set_player_avatar","avatar",profile.get("avatar"))]:
                            if value is not None: host.request({"type":kind,"player_id":player,field:value})
                        applied_profiles[player] = key
                public_state={"cloud":True,"linked":linked,"revisions":{s["player"]:s["revision"] for s in live_seats},
                    "pairing_tickets":{key:v["ticket"] for key,v in pairing.items()},
                    "room":{"room_code":response["room_code"],"pending":response.get("pending",[])}}
                destination=args.registration.parent/"lobby-links.json"
                temporary=destination.with_suffix(".tmp");temporary.write_text(json.dumps(public_state));temporary.replace(destination)
                pickup_file=args.registration.parent/"pickup.json"
                if pickup_file.exists():
                    pickup=json.loads(pickup_file.read_text());pickup_file.unlink()
                    seat=known.get(pickup.get("player"))
                    if seat: post("/v1/lobbies/pickup",{"pending":pickup["pending"],"seat":seat},registration["token"])
            selection = response.get("selection")
            if selection and not pending:
                pending_id = selection["id"]
                if pending_id in journal:
                    receipt = journal[pending_id]
                else:
                    # Heartbeats continue while preparing/starting a game.
                    journal[pending_id] = {"id": pending_id, "ok": False, "message": "The previous host operation was interrupted. Check the game before sending a new request."}
                    temp = journal_path.with_suffix(".tmp"); temp.write_text(json.dumps(journal)); temp.replace(journal_path)
                    pending = worker.submit(perform, selection)
        except (OSError, ValueError, RuntimeError) as error:
            # Do not renew room membership from a stale or unavailable world.
            print("Waiting for live world: " + str(error), flush=True)
        time.sleep(.5)


if __name__ == "__main__":
    main()
