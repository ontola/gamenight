"""Isolated Windows Luanti/Mineclonia experiment. No catalog publication.

python prototype.py setup|server|clients|status|demo|undo|stop
Run `server` in a terminal, `clients` in another. Stock clients are a diagnostic
baseline, NOT working two-controller split-screen. See README.md.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import urllib.request
import uuid
import zipfile

PACKAGES = {
    "luanti-5.17.0-win64.zip": (
        "https://github.com/luanti-org/luanti/releases/download/5.17.0/luanti-5.17.0-win64.zip",
        17539019, "3ce20c77f5c206a988d7a6b883439e2759e3cf67428c9dbcf99ecd2936da631c", "engine"),
    "mineclonia-0.123.1.zip": (
        "https://cdn.content.luanti.org/uploads/0e17a07e64.zip",
        29204259, "abeacf4e202d6e01a63119a36b46751eb6abfd42948a0b06e1ba8f63fb849e59", "game"),
}

def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")

def setup(root):
    for name, (url, size, sha, folder) in PACKAGES.items():
        archive = root / "downloads" / name
        archive.parent.mkdir(parents=True, exist_ok=True)
        if not archive.exists():
            urllib.request.urlretrieve(url, archive)
        if archive.stat().st_size != size or hashlib.sha256(archive.read_bytes()).hexdigest() != sha:
            raise ValueError(f"Package verification failed: {name}")
        destination = (root / folder).resolve()
        with zipfile.ZipFile(archive) as z:
            for info in z.infolist():
                candidate = (destination / info.filename).resolve()
                if not candidate.is_relative_to(destination) or (info.external_attr >> 16) & 0o170000 == 0o120000:
                    raise ValueError("Unsafe archive member")
            if not destination.exists():
                z.extractall(destination)
        print(name, size, sha)
    engine = root / "engine" / "luanti-5.17.0-win64"
    game = engine / "games" / "mineclonia"
    if not game.exists():
        shutil.copytree(root / "game" / "mineclonia", game)
    world = root / "world"
    world.mkdir(exist_ok=True)
    if not (world / "world.mt").exists():
        write(world / "world.mt", "gameid = mineclonia\nbackend = sqlite3\nplayer_backend = sqlite3\nauth_backend = sqlite3\nmod_storage_backend = sqlite3\nload_mod_gamenight_bridge = true\n")
    shutil.copytree(Path(__file__).parent / "mods" / "gamenight_bridge",
                    world / "worldmods" / "gamenight_bridge", dirs_exist_ok=True)
    write(root / "server.conf", "bind_address = 127.0.0.1\nport = 30123\nserver_announce = false\nmax_users = 2\ndefault_privs = interact,shout\ncreative_mode = false\nenable_damage = false\nmg_name = v7\nfixed_map_seed = gamenight-couch-prototype\n")
    for seat in (1, 2):
        write(root / f"client-{seat}.conf", f"fullscreen = false\nscreen_w = 960\nscreen_h = 900\nwindow_maximized = false\npause_on_lost_focus = false\nfps_max = 60\nviewing_range = 60\nsound_volume = {0.5 if seat == 1 else 0}\nname = Couch{seat}\naddress = 127.0.0.1\nremote_port = 30123\n")

def read_json(path):
    # Windows can briefly deny reads while Luanti atomically replaces a file.
    for attempt in range(20):
        try:
            return json.loads(path.read_text(encoding='utf-8'))
        except (PermissionError, FileNotFoundError, json.JSONDecodeError):
            if attempt == 19:
                raise
            time.sleep(.01)

def command(root, action, values=None, expected=None, request_id=None):
    directory = root / "world" / "gamenight"
    if not directory.exists():
        raise RuntimeError("Server bridge has not started")
    # Cross-process lock. Do not steal a stale lock: inspect the server first.
    lock = directory / "writer.lock"
    try:
        fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        raise RuntimeError("Another bridge command is in progress") from None
    try:
        os.close(fd)
        state_path = directory / "status.json"
        if time.time() - state_path.stat().st_mtime > 5:
            raise RuntimeError("Bridge heartbeat is stale")
        state = read_json(state_path)
        request = {"id": request_id or uuid.uuid4().hex, "action": action,
                   "expected_revision": state["revision"] if expected is None else expected}
        if values is not None:
            request["values"] = values
        write(directory / "request.tmp", json.dumps(request))
        os.replace(directory / "request.tmp", directory / "request.json")
        for _ in range(100):
            try:
                response = read_json(directory / "response.json")
                if response.get("id") == request["id"]:
                    return response
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            time.sleep(0.1)
        raise TimeoutError("No acknowledgement; inspect status before retrying")
    finally:
        lock.unlink()

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("action", choices=["setup", "server", "clients", "status", "demo", "undo", "keep", "stop"])
    p.add_argument("--root", type=Path, default=Path("E:/gamenight-host/prototypes/mineclonia"))
    args = p.parse_args()
    root = args.root.resolve()
    exe = root / "engine" / "luanti-5.17.0-win64" / "bin" / "luanti.exe"
    if args.action == "setup":
        setup(root)
    elif args.action == "server":
        # Dedicated mode has no GUI and is bound only to loopback.
        return subprocess.call([str(exe), "--server", "--world", str(root / "world"),
                                "--config", str(root / "server.conf"), "--logfile", str(root / "server.log")], cwd=root)
    elif args.action == "clients":
        print("Diagnostic baseline: stock engine has no per-window controller isolation.")
        for seat in (1, 2):
            subprocess.Popen([str(exe), "--go", "--address", "127.0.0.1", "--port", "30123",
                              "--name", f"Couch{seat}", "--password", "local-isolated-test",
                              "--config", str(root / f"client-{seat}.conf"),
                              "--logfile", str(root / f"client-{seat}.log")], cwd=root)
    else:
        action = {"demo": "set", "stop": "shutdown"}.get(args.action, args.action)
        result = command(root, action, {"gravity": 0.5, "jump": 1.4} if action == "set" else None)
        print(json.dumps(result, indent=2))
        return 0 if result["ok"] else 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
