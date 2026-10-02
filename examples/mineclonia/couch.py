"""Launch the patched two-controller prototype. Requires two connected pads.

Pinned physical device paths, not transient SDL IDs, select each player's pad.
This launcher refuses missing/ambiguous devices and never silently shares one.
"""
import argparse,hashlib,json,os,subprocess
from contextlib import contextmanager
from pathlib import Path
from probe_controllers import devices


def select(available, saved=None):
    pads=[p for p in available if p["game_controller"] and p.get("path")]
    paths=[p["path"] for p in pads]
    if len(set(paths))!=len(paths):
        raise ValueError("SDL returned duplicate controller paths; cannot isolate players")
    if saved:
        if len(saved)!=2 or len(set(saved))!=2 or any(p not in paths for p in saved):
            raise ValueError("A previously assigned controller is missing. Reconnect it, or use --reassign.")
        return [next(p for p in pads if p["path"]==path) for path in saved]
    if len(pads)!=2:
        raise ValueError(f"Connect exactly two recognized controllers for first setup; found {len(pads)}.")
    return pads


@contextmanager
def singleton(root):
    # OS-owned advisory lock releases even if the supervisor crashes.
    with (root / "couch.lock").open("a+b") as lock:
        lock.seek(0, 2)
        if lock.tell() == 0:
            lock.write(b"0"); lock.flush()
        lock.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise SystemExit("A couch launcher is already running. Close that pair first.") from None
        try:
            yield
        finally:
            lock.seek(0)
            if os.name == "nt": msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
            else: fcntl.flock(lock, fcntl.LOCK_UN)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root",type=Path,default=Path("E:/gamenight-host/prototypes/mineclonia"))
    p.add_argument("--reassign",action="store_true",help="Forget saved controller-to-seat assignments")
    a=p.parse_args();root=a.root.resolve()
    exe=root / "controller-engine/bin/luanti.exe"
    manifest=root / "controller-engine/gamenight-controller-build.json"
    if not manifest.exists() or not exe.exists():
        raise SystemExit("Build/install the controller engine first; see engine/README.md.")
    evidence=json.loads(manifest.read_text())
    if hashlib.sha256(exe.read_bytes()).hexdigest()!=evidence["sha256"]:
        raise SystemExit("Controller engine differs from the recorded build.")
    assignment=root / "controller-seats.json"
    saved=json.loads(assignment.read_text()) if assignment.exists() and not a.reassign else None
    try:pads=select(devices(root),saved)
    except ValueError as e:raise SystemExit(str(e)) from None
    assignment.write_text(json.dumps([pad["path"] for pad in pads],indent=2))
    # The server must already be running; do not start extra worlds on every retry.
    status=root / "world/gamenight/status.json"
    import time
    if not status.exists() or time.time()-status.stat().st_mtime>5:
        raise SystemExit("Start the isolated world with prototype.py server first.")
    with singleton(root):
        children=[]
        try:
            for index,pad in enumerate(pads):
                seat=index+1
                config=root / f"couch-{seat}.conf"
                config.write_text(f"fullscreen = false\nwindow_maximized = false\npause_on_lost_focus = false\nfps_max = 60\nfps_max_unfocused = 60\nviewing_range = 60\nsound_volume = {0.5 if index==0 else 0}\nkeymap_pause = GAMEPAD_BUTTON_6|GAMEPAD_BUTTON_4\nkeymap_minimap = \nkeymap_drop = \nkeymap_freemove = \nkeymap_screenshot = \n",encoding="utf-8")
                env=dict(os.environ,GAMENIGHT_CONTROLLER_PATH=pad["path"],GAMENIGHT_COUCH_SEAT=str(index))
                userdir=root / f"couch-user-{seat}"
                userdir.mkdir(exist_ok=True)
                env["LUANTI_USER_PATH"]=str(userdir)
                child=subprocess.Popen([str(exe),"--go","--address","127.0.0.1","--port","30123",
                    "--name",f"Couch{seat}","--password","local-isolated-test","--config",str(config),
                    "--logfile",str(root/f"couch-{seat}.log")],cwd=root,env=env,
                    stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,
                    creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name=="nt" else 0)
                children.append(child)
                print(f"Couch{seat}: {pad['name']} ({pad['path']})",flush=True)
            while all(c.poll() is None for c in children):time.sleep(.2)
        finally:
            # A closed viewport ends this couch pair, never another agent's game.
            for child in children:
                if child.poll() is None:child.terminate()
            for child in children:child.wait(timeout=10)


if __name__=="__main__":main()
