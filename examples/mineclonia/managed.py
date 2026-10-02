"""Local experimental Mineclonia adapter for the real GameNight lobby.

The resident lobby owns Back and hardware input. We route host tokens to two
engine views; native SDL controller events are disabled in managed clients.
"""
import argparse
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import time
import shutil
import uuid
from concurrent.futures import ThreadPoolExecutor
import modding
from settings import Settings
from host import Host
from couch import singleton
from server import Server, preserve_world
from prototype import command


def routed(seats, controllers):
    """Never interpret host tokens as SDL indexes, and never borrow a pad."""
    by_token = {p["controller"]: p for p in controllers}
    result = []
    used = set()
    for seat in seats:
        token = seat.get("controller")
        pad = by_token.get(token) if token and token not in used else None
        if token: used.add(token)
        if seat.get("occupant", {}).get("kind") != "local": pad = None
        axes = pad.get("axes") if pad else None
        buttons = pad.get("buttons") if pad else None
        valid = (isinstance(axes, list) and len(axes) == 6
            and all(type(v) is int and -32768 <= v <= 32767 for v in axes)
            and type(buttons) is int and 0 <= buttons < 16384)
        result.append((True, buttons & ~(1 << 6), axes) if valid else (False, 0, [0]*6))
    return result


def publish(path, active, connected=False, buttons=0, axes=None):
    fields = [time.monotonic_ns(), int(active), int(connected), buttons, *(axes or [0]*6)]
    temp = path.with_suffix(".tmp")
    temp.write_text(" ".join(map(str, fields)), encoding="ascii")
    try: os.replace(temp, path)
    except PermissionError: pass  # reader is closing; the next frame replaces it


class Adapter:
    def __init__(self, root, send):
        self.root, self.send = root, send
        self.server = Server(root)
        self.server.start()
        self.settings = Settings(root)
        self.directory = root / "managed"
        self.directory.mkdir(exist_ok=True)
        self.server_frame = self.directory / "server.frame"
        self.children = []
        self.frames = []
        self.seats = []
        self.session = None
        self.active = False
        self.ready = False
        self.controllers = []
        self.received = 0
        self.started = 0
        self.prepare = None
        self.mod_worker = ThreadPoolExecutor(max_workers=1)
        self.mod_future = None
        self.mod_request = None
        self.mod_restart = None

    def dispose(self):
        self.active = False
        self.flush()
        self.settings.settle()
        if self.children and self.server.process and self.server.process.poll() is None:
            # Abruptly terminating a UDP client leaves its name reserved on the
            # server. Explicitly disconnect first, before any replacement view.
            command(self.root, "disconnect_views")
        for child in self.children:
            if child.poll() is None: child.terminate()
        for child in self.children: child.wait(timeout=10)
        self.children.clear(); self.frames.clear()
        (self.directory / "view-pids.txt").write_text("")
        self.session = None; self.ready = False

    def receive(self, msg):
        kind = msg.get("type")
        if kind == "welcome":
            self.send({"type": "declare_settings", "settings": self.settings.specs()})
        elif kind == "setting_changed":
            self.settings.change(msg.get("key"), msg.get("value"))
        elif kind == "controller_frame":
            self.controllers = msg["controllers"]; self.received = time.monotonic()
        elif kind == "prepare":
            if self.mod_request and self.mod_request.get("instance") != msg["session"]:
                self.mod_result(False, "Game instance changed during mod validation")
            self.dispose()
            self.prepare = msg
            self.session = msg["session"]
            # Exactly two physical seats for this prototype. Empty views stay neutral.
            self.seats = sorted(msg["seats"], key=lambda s: s["index"])[:2]
            self.started = time.monotonic()
            self.send({"type":"participation", "session":self.session, "instant_join":True})
            self.send({"type":"progress", "session":self.session, "percent":0, "label":"Loading both views"})
            for index in range(2):
                frame = self.directory / f"view-{index}.frame"
                frame.with_suffix(".frame.ready").unlink(missing_ok=True)
                publish(frame, False)
                self.frames.append(frame)
                conf = self.directory / f"view-{index}.conf"
                conf.write_text("fullscreen = false\nwindow_maximized = false\npause_on_lost_focus = false\nfps_max = 60\nfps_max_unfocused = 30\nviewing_range = 60\nkeymap_pause = GAMEPAD_BUTTON_6\nkeymap_minimap = \nkeymap_drop = \nkeymap_freemove = \nkeymap_screenshot = \ndebug_log_level = info\nsound_volume = " + ("0.5" if index == 0 else "0") + "\n")
                env = dict(os.environ, GAMENIGHT_CONTROLLER_FRAME=str(frame), GAMENIGHT_COUCH_SEAT=str(index))
                env["GAMENIGHT_COUCH_GROUP"] = str(self.directory / "view-pids.txt")
                env.pop("GAMENIGHT_CONTROLLER_PATH", None)
                userdir = self.directory / f"client-{index}"
                userdir.mkdir(exist_ok=True)
                env["LUANTI_USER_PATH"] = str(userdir)
                args = [str(self.root/"controller-engine-managed/bin/luanti.exe"), "--go", "--address", "127.0.0.1", "--port", "30123",
                    "--name", f"Couch{index+1}", "--password", "local-isolated-test", "--config", str(conf),
                    "--logfile", str(self.directory/f"view-{index}.log")]
                self.children.append(subprocess.Popen(args, cwd=self.root, env=env,
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
                (self.directory / "view-pids.txt").write_text(" ".join(str(c.pid) for c in self.children))
        elif kind == "party_updated" and msg.get("session") == self.session:
            self.seats = sorted(msg["seats"], key=lambda s:s["index"])[:2]
        elif kind in ("start", "resume", "pause", "dispose") and msg.get("session") == self.session:
            if kind == "dispose": self.dispose()
            else:
                self.active = kind in ("start", "resume")
                if self.mod_restart is not None: self.mod_restart = self.active
                self.flush()
                print(kind, self.session, flush=True)
        elif kind == "error":
            # Startup and roster changes can supersede a preparation while our
            # ready/participation notification is in flight. The host's ordered
            # dispose/prepare messages remain authoritative; a stale notice is
            # not a reason to kill the world or its current views.
            if msg["message"] in ("stale participation session", "ready for unknown or non-preparing session"):
                print("Superseded lifecycle notification:", msg["message"], flush=True)
                return
            raise RuntimeError(msg["message"])

    def flush(self):
        publish(self.server_frame, self.active)
        pads = routed(self.seats, self.controllers if time.monotonic()-self.received <= .25 else [])
        for i, path in enumerate(self.frames):
            connected, buttons, axes = pads[i] if i < len(pads) else (False, 0, [0]*6)
            publish(path, self.active, connected, buttons, axes)

    def mod_result(self, ok, message):
        result = {"id": self.mod_request["id"], "ok": ok, "message": message}
        target = self.directory / "mod-result.json"
        temp = target.with_suffix(".tmp"); temp.write_text(json.dumps(result)); temp.replace(target)
        self.mod_request = self.mod_future = self.mod_restart = None

    def mods(self):
        if self.settings.future is not None: return
        path = self.directory / "mod-request.json"
        if path.exists() and self.mod_request is None:
            req = json.loads(path.read_text()); path.unlink()
            uuid.UUID(req["id"])
            if req.get("instance") != self.session:
                self.mod_request=req; self.mod_result(False,"Game instance changed"); return
            self.mod_request = req
            try:
                state = json.loads((self.root / "world/gamenight/status.json").read_text())
                if state["revision"] != req["expected_revision"]:
                    raise ValueError("World changed before mod validation")
                staged, digest = modding.stage(self.root, req["values"])
                self.mod_future = self.mod_worker.submit(modding.validate, self.root, staged)
            except (ValueError, OSError, RuntimeError) as e:
                self.mod_result(False, str(e))
        if self.mod_future and self.mod_future.done():
            try:
                self.mod_future.result()
                if self.mod_request.get("instance") != self.session or self.mod_request["expires"] <= time.time() or self.mod_request["seat"] not in Host.seats({"seats": self.seats}):
                    raise ValueError("Player left or request expired during validation")
                state = json.loads((self.root / "world/gamenight/status.json").read_text())
                if state["revision"] != self.mod_request["expected_revision"]:
                    raise ValueError("World changed during mod validation")
            except Exception as e:
                self.mod_result(False, str(e)); return
            req = self.mod_request
            prepared, active = dict(self.prepare, seats=list(self.seats)), self.active
            checkpoint = self.root / "checkpoints" / str(uuid.UUID(req["id"]))
            marker = self.directory / "mod-install.json"
            try:
                staged, digest = modding.stage(self.root, req["values"])
                self.dispose()
                self.server.stop()
                shutil.copytree(self.root / "world", checkpoint)
                pending_marker = marker.with_suffix(".tmp")
                pending_marker.write_text(json.dumps({"checkpoint": str(checkpoint), "id": req["id"]}))
                pending_marker.replace(marker)
            except Exception as e:
                # No live mod files have changed yet. In particular, a full disk
                # during checkpoint creation must not strand a stopped session.
                self.server.start()
                if self.session is None:
                    self.receive(prepared)
                self.active = active
                self.mod_result(False, "Could not save a checkpoint; mod not installed: "+str(e))
                return
            try:
                shutil.copytree(staged, self.root / "world/worldmods/gamenight_custom", dirs_exist_ok=True)
                mt = self.root / "world/world.mt"
                if "load_mod_gamenight_custom" not in mt.read_text():
                    mt.write_text(mt.read_text()+"\nload_mod_gamenight_custom = true\n")
                (self.root / "world/gamenight/mod-current.json").write_text(json.dumps({"sha256": digest, "values": req["values"], "request_id":req["id"], "previous_values":None if req.get("undo") else (state.get("mod_values") or {"bounce":0})}))
                self.server.start()
                self.receive(prepared)
                self.mod_future = None
                self.mod_restart = active
            except Exception as e:
                self.server.stop()
                # Preserve the failed world for diagnosis. No recursive deletion.
                failed = self.root / ("failed-mod-"+str(uuid.UUID(req["id"])))
                preserve_world(self.root, failed.name)
                shutil.copytree(checkpoint, self.root / "world")
                self.server.start(); self.receive(prepared)
                self.mod_result(False, "Mod restart failed; saved world restored: "+str(e))
                marker.unlink(missing_ok=True)

    def tick(self):
        self.server.check()
        self.settings.tick(blocked=self.mod_request is not None)
        self.mods()
        if any(c.poll() is not None for c in self.children):
            raise RuntimeError("A Mineclonia view closed; ending this pair")
        if self.session and not self.ready:
            if all(Path(str(f)+".ready").exists() for f in self.frames) and len(self.frames)==2:
                self.ready = True
                if self.mod_restart is not None:
                    self.active = self.mod_restart
                    self.mod_result(True, "Previous mod restored; both views reconnected." if self.mod_request.get("undo") else "Bounce pad installed and both views reconnected. Players receive bounce pads in their inventory when space is available. Set bounce to zero to disable the effect.")
                    (self.directory / "mod-install.json").unlink(missing_ok=True)
                else:
                    self.send({"type":"ready", "session":self.session})
                print("Both world views rendered; ready", flush=True)
            elif time.monotonic()-self.started > 90:
                raise RuntimeError("Timed out loading Mineclonia views")
        self.flush()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root", type=Path, default=Path("E:/gamenight-host/prototypes/mineclonia"))
    a=p.parse_args()
    if not os.environ.get("GAMENIGHT_TOKEN"):
        raise SystemExit("Launch through the GameNight test shelf, not directly.")
    host, port=os.environ["GAMENIGHT_ADDR"].rsplit(":",1)
    with singleton(a.root), socket.create_connection((host,int(port))) as sock:
        def send(msg): sock.sendall((json.dumps(msg)+"\n").encode())
        send({"type":"hello", "role":"game", "game":os.environ["GAMENIGHT_GAME_ID"], "token":os.environ["GAMENIGHT_TOKEN"]})
        adapter=Adapter(a.root,send)
        buffer=b""
        try:
            while True:
                if select.select([sock],[],[],.016)[0]:
                    data=sock.recv(65536)
                    if not data: break
                    buffer+=data
                    if len(buffer)>16777216: raise RuntimeError("Oversized host message")
                    while b"\n" in buffer:
                        line,buffer=buffer.split(b"\n",1)
                        if line: adapter.receive(json.loads(line))
                adapter.tick()
        finally:
            try:
                adapter.settings.close()
                adapter.mod_worker.shutdown(wait=True, cancel_futures=True)
                adapter.dispose()
            finally: adapter.server.stop()

if __name__ == "__main__": main()
