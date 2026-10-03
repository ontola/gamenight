"""Generic SDK settings for the shared phone/lobby assistant.
No engine-specific commands or model services live here.
"""
import time

def current(party):
    return party.get("active_session") or party.get("warm_session")

def controls(party):
    session=current(party)
    if not session or session["game"] not in party.get("connected_games",[]):return None
    entry=next((s for s in party.get("settings",[]) if s["game"]==session["game"]),None)
    if not entry or not entry["specs"]:return None
    settings={}
    for spec in entry["specs"]:
        item={k:spec[k] for k in ("label","kind","min","max","options") if k in spec}
        item.update(value=entry["values"][spec["key"]],description=spec.get("description") or "",
                    applies="See game description")
        if spec["kind"]=="number":item["integer"]=True
        settings[spec["key"]]=item
    return {"game":session["game"],"instance":session["id"],"revision":entry.get("revision",0),
            "can_undo":entry.get("can_undo",False),"settings":settings}

def game_id(value):
    return "mineclonia" if value == "mineclonia-prototype" else value

def snapshot(host,receipt=None):
    party=host.status();session=current(party);c=controls(party)
    games=[]
    for game in party.get("library",[]):
        if game["id"] in ("lobby","gamenight-lobby"):continue
        games.append({"id":game_id(game["id"]),"selectable":True,"state":"playing" if session and game["id"]==session["game"] else "available"})
    if session and not any(g["id"]==game_id(session["game"]) for g in games):
        games.append({"id":game_id(session["game"]),"selectable":True,"state":"playing"})
    return {"seats":host.seats(party),"discovery":{"games":games,"current":game_id(session["game"]) if session else None,
            "controls":c,"agent_receipt":receipt,"acknowledged":receipt["id"] if receipt and receipt.get("ok") else None,
            "next":(party.get("warm_session") or {}).get("game")}}

def execute(host,selection):
    party=host.status()
    if selection.get("expires",0)<=time.time():raise ValueError("Request expired")
    if selection.get("seat") not in host.seats(party):raise ValueError("Player left or changed controller")
    if selection.get("edit"):
        raise ValueError("Playlist editing is not supported by this experimental relay")
    command=selection.get("command")
    if not command:
        game="mineclonia-prototype" if selection["game"] == "mineclonia" else selection["game"]
        if not any(g["id"]==game for g in party.get("library",[])):raise ValueError("Game is not on this host")
        host.request({"type":"queue_next","game":game})
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            p=host.status()
            if any((p.get(k) or {}).get("game")==game for k in ("warming","warm_session")):
                return {"id":selection["id"],"ok":True,"message":"Host queued the game."}
            time.sleep(.1)
        raise TimeoutError("Host did not confirm the queue change")
    c=controls(party)
    if not c or selection["game"]!=c["game"] or command.get("instance")!=c["instance"]:
        raise ValueError("The running game changed")
    if command.get("expected_revision")!=c["revision"]:raise ValueError("Settings changed; try again")
    if command.get("action") not in ("set","undo","keep"):raise ValueError("This game does not expose that action")
    accepted=host.request({"type":"control_settings","game":c["game"],"session":c["instance"],
        "expected_revision":c["revision"],"player_id":selection["seat"]["player"],
        "action":command["action"],"values":command.get("values",{})},receipt=True)
    if accepted != {"type":"settings_accepted","game":c["game"],"session":c["instance"],"revision":c["revision"]+1}:
        raise RuntimeError("Host did not acknowledge this settings request")
    deadline=time.monotonic()+5
    while time.monotonic()<deadline:
        p=host.status();after=controls(p)
        if not after or after["instance"]!=c["instance"]:raise ValueError("The game changed before confirmation")
        if after["revision"]==c["revision"]+1:
            return {"id":selection["id"],"ok":True,
                "message":"Host accepted the settings. They take effect at the time specified by the game."}
        time.sleep(.1)
    raise TimeoutError("Host did not confirm the settings")
