#!/usr/bin/env python3
"""Real daemon -> real Godot processes. Source builds, not release certification.
Set GODOT and GAMENIGHT_GODOT_SOURCES to a JSON {game_id: project_path} mapping.
Requires a built gamenight-daemon. Can be reused by the private model evaluation.
"""
import contextlib, importlib.util, json, os, socket, subprocess, tempfile
from pathlib import Path
spec = importlib.util.spec_from_file_location("live", Path(__file__).with_name("test-live-settings.py"))
live = importlib.util.module_from_spec(spec); spec.loader.exec_module(live)
ROOT = live.ROOT
from host import Host
from game_controls import controls, execute
CASES = {
    "spaceracer": {"boost_cost": 35, "energy_refill": 200, "weapon_pickups": False},
    "growing-guns": {"gravity": 50, "body_damage": 150, "card_pick_seconds": 6},
    "ballkickers": {"run_speed": 125, "super_shots": False, "keeper_speed": 75},
    "frog-fighter": {"lives": 5, "gravity": 50, "bot_reaction": 150},
}
wait_for = live.wait_for
assert_values = live.assert_values

@contextlib.contextmanager
def running(game):
    sources = json.loads(os.environ["GAMENIGHT_GODOT_SOURCES"])
    project = Path(sources[game])
    with tempfile.TemporaryDirectory(prefix="gn-godot-settings-") as tmp:
        root = Path(tmp)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0)); port = sock.getsockname()[1]
        (root/"library.json").write_text(json.dumps([{"id":game,"title":game}]))
        env = dict(os.environ, GAMENIGHT_ADDR=f"127.0.0.1:{port}",
            GAMENIGHT_NO_PREWARM="1", GAMENIGHT_NO_LOBBY_WATCH="1",
            GAMENIGHT_LIBRARY=str(root/"library.json"))
        processes=[]
        with (root/"log").open("w+") as log:
            try:
                processes.append(subprocess.Popen([str(ROOT/"target/debug/gamenight-daemon")],env=env,stdout=log,stderr=log))
                host=Host(port);wait_for(host.status)
                for index in range(2):
                    host.request({"type":"join_party","name":f"Test {index+1}"})
                    player=host.status()["players"][-1]["id"]
                    host.request({"type":"bind_controller","player_id":player,"controller":f"ordinal:{index}"})
                probe=root/"probe.json"
                env.update(GAMENIGHT="1",GAMENIGHT_GAME_ID=game,GAMENIGHT_SETTINGS_PROBE=str(probe))
                processes.append(subprocess.Popen([os.environ["GODOT"],"--headless","--audio-driver","Dummy","--path",str(project)],env=env,stdout=log,stderr=log))
                wait_for(lambda:controls(host.status()),60)
                yield host,probe,processes
                assert all(p.poll() is None for p in processes),"A game or host exited"
            except Exception:
                log.flush();print((root/"log").read_text());raise
            finally:
                for child in reversed(processes):
                    if child.poll() is None:child.terminate()
                for child in processes:
                    try:child.wait(timeout=5)
                    except subprocess.TimeoutExpired:child.kill();child.wait()

def main():
    for game, values in CASES.items():
        with running(game) as (host,probe,_):
            defaults={key:item["value"] for key,item in controls(host.status())["settings"].items()}
            assert execute(host,live.selection(host,values))["ok"]
            assert_values(probe,values)
            assert execute(host,live.selection(host,action="undo"))["ok"]
            assert_values(probe,{key:defaults[key] for key in values})
            print(game+": real game received typed changes and undo",flush=True)
if __name__=="__main__":main()
