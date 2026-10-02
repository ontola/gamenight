"""Real daemon + patched clients/server lifecycle check; no synthetic controller input."""
import argparse,json,socket,time
from pathlib import Path

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root",type=Path,default=Path("E:/gamenight-host/prototypes/mineclonia"))
    p.add_argument("--port",type=int,default=17942)
    a=p.parse_args()
    def request(kind=None):
        with socket.create_connection(("127.0.0.1",a.port),timeout=4) as s:
            s.sendall(b'{"type":"hello","role":"overlay"}\n')
            party=json.loads(s.makefile("rb").readline())["party"]
            if kind:
                s.sendall((json.dumps({"type":kind})+"\n").encode());s.recv(65536)
            return party
    def state():return json.loads((a.root/"world/gamenight/status.json").read_text())
    def views():return [(a.root/f"managed/view-{i}.frame").read_text().split()[1] for i in range(2)]
    deadline=time.monotonic()+90
    while time.monotonic()<deadline:
        party=request()
        if party.get("warm_session",{}).get("phase")=="ready":break
        time.sleep(.5)
    else:raise AssertionError("Game did not become ready")
    try:
        request("next");time.sleep(2)
        assert views()==["1","1"],"Start must activate both views"
        for cycle in range(3):
            request("open_overlay");time.sleep(.8)
            before=state();time.sleep(1.5);after=state()
            assert views()==["0","0"],"Pause must hide both views"
            assert before["game_time"]==after["game_time"],"Simulation advanced while paused"
            request("close_overlay");time.sleep(2)
            running=state()
            assert views()==["1","1"],"Resume must activate both views"
            assert running["game_time"]>after["game_time"],"Simulation failed to resume"
            assert len(running["players"] or [])==2,"Both world clients must stay connected"
            print(f"Cycle {cycle+1}: both clients connected, world paused and resumed",flush=True)
        print("PASS. Physical controller/Back/menu operation still requires the user playtest.",flush=True)
    finally:request("open_overlay")
if __name__=="__main__":main()
