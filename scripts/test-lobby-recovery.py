#!/usr/bin/env python3
"""Crash a disposable replacement lobby; verify bounded retries and party retention."""
import importlib.util,json,os,signal,socket,subprocess,sys,tempfile,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("flow",ROOT/"scripts/test-godot-lobby.py")
flow=importlib.util.module_from_spec(spec);spec.loader.exec_module(flow)
def wait(predicate, seconds=15):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        if predicate(): return
        time.sleep(.05)
    raise AssertionError("timed out waiting for recovery")
def main():
    with tempfile.TemporaryDirectory(prefix="gamenight-recovery-") as folder:
        tmp=Path(folder);count=tmp/"launches.txt"
        crash=tmp/"crash.py"
        crash.write_text("from pathlib import Path\nimport sys\np=Path(sys.argv[1])\nwith p.open('a') as f: f.write('start\\n')\n")
        shelf=tmp/"shelf.json"
        shelf.write_text(json.dumps([{"id":"broken-lobby","title":"Broken test lobby","launch":{"command":sys.executable,"args":[str(crash),str(count)],"env":{"GAMENIGHT_LOBBY_API":"1"}}}]))
        with socket.socket() as probe: probe.bind(("127.0.0.1",0));port=probe.getsockname()[1]
        env={k:v for k,v in os.environ.items() if not k.startswith("GAMENIGHT")}
        env.update(GAMENIGHT_ADDR=f"127.0.0.1:{port}",GAMENIGHT_LIBRARY=str(shelf),GAMENIGHT_LOBBY_GAME="broken-lobby",GAMENIGHT_NO_PREWARM="1",GAMENIGHT_NO_MUSIC="1",GAMENIGHT_TEST_NO_CONTROLLERS="1")
        target=Path(os.environ.get("CARGO_TARGET_DIR",ROOT/"target"))/"debug"/("gamenight-daemon.exe" if os.name=="nt" else "gamenight-daemon")
        def launches(): return len(count.read_text().splitlines()) if count.exists() else 0
        with (tmp/"daemon.log").open("w") as log:
            options={"creationflags":subprocess.CREATE_NEW_PROCESS_GROUP} if os.name=="nt" else {"start_new_session":True}
            process=subprocess.Popen([os.environ.get("GAMENIGHT_TEST_DAEMON",str(target))],env=env,stdout=log,stderr=log,**options)
            try:
                wait(lambda: launches()>=4)
                time.sleep(.6)
                assert launches()==4 and process.poll() is None,"restart budget must stop at three retries"
                peer=flow.Peer(port,"overlay")
                peer.send({"type":"join_party","name":"Recovery player"})
                before=peer.until(lambda p:len(p["players"])==1)["players"]
                peer.send({"type":"retry_lobby"})
                while True:
                    reply=peer.read()
                    assert reply["type"]!="error",reply
                    if reply["type"]=="party_state": break
                wait(lambda:launches()>=8);time.sleep(.6)
                assert launches()==8,"retry must reset, not remove, the crash budget"
                check=flow.Peer(port,"overlay")
                assert check.party["players"]==before,"recovery must preserve players"
                check.send({"type":"quit_party"})
                process.wait(timeout=5)
                check.close();peer.close()
            finally:
                if process.poll() is None:
                    if os.name=="nt": subprocess.run(["taskkill","/PID",str(process.pid),"/T","/F"],capture_output=True)
                    else: os.killpg(process.pid,signal.SIGTERM)
                    process.wait(timeout=5)
        print("PASS replacement lobby crash budget, retry, retained players and explicit quit")
if __name__=="__main__": main()
