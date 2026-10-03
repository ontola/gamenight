"""Start the real GameNight lobby with the isolated Mineclonia test shelf.
Owns the patched world server through the game adapter. No production data.
"""
import argparse,json,os,socket,subprocess,sys,time
from pathlib import Path

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root",type=Path,default=Path("E:/gamenight-host/prototypes/mineclonia"))
    p.add_argument("--runtime",type=Path,default=Path(os.environ["LOCALAPPDATA"])/"Ontola.GameNight.Preview/current")
    p.add_argument("--port",type=int,default=17942)
    p.add_argument("--lobby-exe",type=Path)
    p.add_argument("--daemon-exe",type=Path)
    p.add_argument("--godot",type=Path,help="Use the public pluggable Godot lobby")
    p.add_argument("--game-sources",type=Path,help="JSON mapping game ids to local Godot projects")
    p.add_argument("--first-game",default="mineclonia-prototype")
    p.add_argument("--assistant-url")
    p.add_argument("--join-url")
    p.add_argument("--links-url")
    a=p.parse_args();folder=a.root/"managed";folder.mkdir(exist_ok=True)
    daemon=a.daemon_exe or a.runtime/"bin/gamenight-daemon.exe"
    lobby=a.lobby_exe or a.runtime/"bin/lobby.exe"
    for exe in (daemon,a.godot or lobby,a.root/"controller-engine-managed/bin/luanti.exe"):
        if not exe.is_file():raise SystemExit(f"Missing {exe}")
    with socket.socket() as probe:
        if probe.connect_ex(("127.0.0.1",a.port))==0:raise SystemExit("Test daemon already running")
    shelf=[{"id":"mineclonia-prototype","title":"Mineclonia (controller test)","min_players":2,"max_players":2,"players":"2",
        "launch":{"command":sys.executable,"args":[str(Path(__file__).with_name("managed.py")),"--root",str(a.root)],"cwd":str(a.root)}},
        {"id":"lobby","title":"GameNight","min_players":1,"max_players":4,"players":"1–4",
        "launch":{"command":str(lobby),"cwd":str(a.runtime/"lobby"),"env":{"BEVY_ASSET_ROOT":str(a.runtime/"lobby")}}}]
    lobby_id = "lobby"
    if a.godot:
        lobby_id = "godot-lobby"
        project = Path(__file__).resolve().parents[2]/"sdk/godot"
        shelf[-1] = {"id":lobby_id,"title":"GameNight Living Room","min_players":1,"max_players":4,"players":"1–4",
            "launch":{"command":str(a.godot),"args":["--path",str(project)],"env":{"GAMENIGHT_LOBBY_API":"1","GAMENIGHT_LOBBY_FULLSCREEN":"1"}}}
    catalog=Path(__file__).resolve().parents[2]/"catalog/games"
    for path in sorted(catalog.glob('*.json')):
        entry=json.loads(path.read_text(encoding='utf8'))
        if entry['id'] in ('lobby','demo-game'): continue
        players=entry['players']
        shelf.append({'id':entry['id'],'title':entry['title'],
            'players':str(players['min'])+'–'+str(players['max']),
            'min_players':players['min'],'max_players':players['max'],
            **{k:entry[k] for k in ('cover','icon','screenshot','tagline','color') if entry.get(k)}})
    if a.game_sources:
        if not a.godot:raise SystemExit("--game-sources requires --godot")
        for game,path in json.loads(a.game_sources.read_text()).items():
            project=Path(path)
            if not (project/"project.godot").is_file():raise SystemExit(f"Missing Godot project for {game}")
            entry=next((item for item in shelf if item["id"]==game),None)
            if not entry:raise SystemExit(f"Unknown source game: {game}")
            entry["launch"]={"command":str(a.godot),"args":["--path",str(project)],"cwd":str(project)}
    first=next((entry for entry in shelf if entry["id"]==a.first_game),None)
    if not first or a.first_game==lobby_id:raise SystemExit("Choose a playable first game")
    library=folder/"shelf.json";library.write_text(json.dumps(shelf,indent=2))
    env={k:v for k,v in os.environ.items() if not k.startswith("GAMENIGHT")}
    env.update(GAMENIGHT_ADDR=f"127.0.0.1:{a.port}",GAMENIGHT_LIBRARY=str(library),GAMENIGHT_CATALOG=str(catalog),GAMENIGHT_LOBBY_GAME=lobby_id,RUST_LOG="info")
    if a.assistant_url: env["GAMENIGHT_ASSISTANT_URL"]=a.assistant_url
    if a.join_url: env["GAMENIGHT_JOIN_URL"]=a.join_url
    if a.links_url: env["GAMENIGHT_LINKS_URL"]=a.links_url
    with (folder/"daemon.log").open("w") as log:
        child=subprocess.Popen([str(daemon)],cwd=folder,env=env,stdout=log,stderr=log)
    (folder/"daemon.pid").write_text(str(child.pid))
    for _ in range(600):
        try:
            with socket.create_connection(("127.0.0.1",a.port),timeout=.2) as sock:
                commands=[{"type":"hello","role":"overlay"},{"type":"set_playlist","entries":[{"game":first["id"],"title":first["title"]}]},{"type":"open_overlay"}]
                sock.sendall(("\n".join(json.dumps(c) for c in commands)+"\n").encode())
                # Do not retry writes because a large welcome snapshot takes
                # longer than the connect timeout. Repeated set_playlist calls
                # keep disposing/repreparing the same world during startup.
            break
        except OSError:
            if child.poll() is not None:raise SystemExit("Daemon exited; inspect managed/daemon.log")
            time.sleep(.1)
    else:raise SystemExit("Daemon did not listen in time")
    print(f"Lobby running, daemon PID {child.pid}. Connected controllers join automatically; A queues, X puts first, then select Start game.",flush=True)
    child.wait()
if __name__=="__main__":main()
