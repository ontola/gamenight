#!/usr/bin/env python3
"""Real daemon -> real shared LÖVE game settings, without a window or physical pads.
Reusable by the private model test. Requires love and a built gamenight-daemon.
"""
import contextlib,json,os,shutil,socket,subprocess,sys,tempfile,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(Path(__file__).resolve().parent))
from game_sources import game_sources
sys.path.insert(0,str(ROOT/"examples/mineclonia"))
from host import Host
from game_controls import controls,execute

def wait_for(fn,timeout=12):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        try:
            result=fn()
            if result:return result
        except (OSError,ValueError,KeyError):pass
        time.sleep(.1)
    raise TimeoutError("Timed out waiting for game observation")

@contextlib.contextmanager
def running(game):
    with tempfile.TemporaryDirectory(prefix="gn-settings-") as tmp:
        root=Path(tmp);source=root/"party"
        shutil.copytree(game_sources()/"love-party",source)
        for folder in ("core","sim","app","data"):
            shutil.copytree(game_sources()/"pinpals"/folder,source/folder)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1",0));port=sock.getsockname()[1]
        (root/"library.json").write_text(json.dumps([{"id":game,"title":game}]))
        env=dict(os.environ,GAMENIGHT_ADDR=f"127.0.0.1:{port}",
            GAMENIGHT_NO_PREWARM="1",GAMENIGHT_NO_LOBBY_WATCH="1",
            GAMENIGHT_LIBRARY=str(root/"library.json"))
        processes=[]
        with (root/"log").open("w+") as log:
            try:
                daemon=subprocess.Popen([str(ROOT/"target/debug/gamenight-daemon")],env=env,stdout=log,stderr=log)
                processes.append(daemon);host=Host(port);wait_for(host.status)
                for index in range(2):
                    host.request({"type":"join_party","name":f"Test player {index+1}"})
                    player=host.status()["players"][-1]["id"]
                    host.request({"type":"bind_controller","player_id":player,"controller":f"ordinal:{index}"})
                probe=root/"probe.json"
                env.update(GAMENIGHT="1",GAMENIGHT_GAME_ID=game,GNLOVE_HEADLESS="1",
                    GNLOVE_PROBE_FILE=str(probe),GNLOVE_PROBE_HOST_INPUT="1",SDL_VIDEODRIVER="dummy")
                love=subprocess.Popen(["love",str(source)],env=env,stdout=log,stderr=log)
                processes.append(love)
                wait_for(lambda:controls(host.status()))
                wait_for(lambda:json.loads(probe.read_text()).get("settings"))
                yield host,probe,processes
                assert all(p.poll() is None for p in processes),"A game or host exited"
            except Exception:
                log.flush();print((root/"log").read_text(),file=sys.stderr);raise
            finally:
                for p in reversed(processes):
                    if p.poll() is None:p.terminate()
                for p in processes:
                    try:p.wait(timeout=5)
                    except subprocess.TimeoutExpired:p.kill();p.wait()

CASES={
 "neon-trails":{"speed":75,"round_pause":"2.0 s"},
 "blast-party":{"pickups":10,"fuse":"3.0 s"},
 "neon-siege":{"difficulty":"intense","wormholes":False},
 "ricochet-club":{"bounces":2,"cover":False},
 "volley-trouble":{"arena":"lava","target":3,"bomb":True},
 "stack-together":{"target":8,"speed":75},
 "bubble-buddies":{"hearts":8,"waves":3},
 "pinpals":{"speed":80},
}

def selection(host,values=None,action="set"):
    c=controls(host.status())
    return {"id":"test-"+str(time.monotonic_ns()),"game":c["game"],"expires":int(time.time())+30,
        "seat":host.seats(host.status())[0],"command":{"action":action,"instance":c["instance"],
        "expected_revision":c["revision"],"values":values or {}}}

def assert_values(probe,values):
    return wait_for(lambda: all(json.loads(probe.read_text())["settings"].get(k)==v for k,v in values.items()))

def main():
    for game,values in CASES.items():
        with running(game) as (host,probe,processes):
            before=json.loads(probe.read_text())["settings"];c=controls(host.status())
            bad=selection(host,dict(values,unknown_option=1))
            try:execute(host,bad);raise AssertionError("Invalid batch accepted")
            except RuntimeError:pass
            assert controls(host.status())["revision"]==c["revision"]
            request=selection(host,values);assert execute(host,request)["ok"];assert_values(probe,values)
            try:execute(host,request);raise AssertionError("Stale request accepted")
            except ValueError:pass
            assert execute(host,selection(host,action="undo"))["ok"];assert_values(probe,before)
            print(game+": actual game observed typed settings and undo; invalid/stale batches refused",flush=True)

if __name__=="__main__":main()
