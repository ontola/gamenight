#!/usr/bin/env python3
"""A fake GameNight host for a game's own tests. Python standard library only.

Every Godot game used to write its own copy of this. It starts the game the
way GameNight does (GAMENIGHT=1, a free port, a launch token), speaks the
WebSocket protocol, and lets a test send lifecycle messages and controller
frames and wait for what the game sends back or prints:

    import sys; sys.path.insert(0, "addons/gamenight")
    from fake_host import FakeHost, frame, BUTTON_A

    with FakeHost("godot", game_id="my-game", path=".") as host:
        host.welcome()
        host.expect("declare_settings")
        host.prepare([host.local_seat(0, "ada")], [{"id": "ada", "name": "Ada"}])
        host.start()
        host.hold(frame(BUTTON_A), 0.1)
        host.saw("jump Ada")          # a line the game printed (GAME_TRACE=1)
        host.pause(); host.resume(); host.dispose()

Lessons built in: a free port so a real GameNight is never touched, the
game's output goes to a file (an unread pipe stalls Godot on Windows), and
`hold` repeats frames because input older than 250 ms counts as released.
Pass `pack=` to test the exported game, which is where missing files show.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import queue
import socket
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path

BUTTON_A, BUTTON_B, BUTTON_X, BUTTON_Y = 0, 1, 2, 3
BUTTON_LB, BUTTON_RB, BUTTON_BACK, BUTTON_START = 4, 5, 6, 7
BUTTON_LS, BUTTON_RS, BUTTON_UP, BUTTON_DOWN, BUTTON_LEFT, BUTTON_RIGHT = 8, 9, 10, 11, 12, 13


def frame(*buttons: int, left=(0.0, 0.0), right=(0.0, 0.0), triggers=(0.0, 0.0), controller="pad0") -> dict:
    """A controller frame for one pad. Sticks and triggers go from -1 to 1."""
    axes = [*left, *right, *triggers]
    bits = 0
    for b in buttons:
        bits |= 1 << b
    return {"controller": controller, "axes": [round(a * 32767) for a in axes], "buttons": bits}


class FakeHost:
    def __init__(self, godot: str, game_id: str, path: str | Path = ".", pack: str = "",
                 args: list[str] | None = None, env: dict | None = None, timeout: float = 30.0):
        self.game_id = game_id
        self.timeout = timeout
        self.session = ""
        self.inbox: queue.Queue = queue.Queue()
        self._server = socket.socket()
        self._server.bind(("127.0.0.1", 0))
        self._server.listen(1)
        port = self._server.getsockname()[1]
        self._log = tempfile.NamedTemporaryFile(prefix="game-", suffix=".log", delete=False)
        self.log_path = Path(self._log.name)
        launch = dict(os.environ, GAMENIGHT="1", GAMENIGHT_ADDR=f"127.0.0.1:{port}",
                      GAMENIGHT_GAME_ID=game_id, GAMENIGHT_TOKEN="fake-host-token", GAME_TRACE="1")
        launch.update(env or {})
        where = ["--main-pack", pack] if pack else ["--path", str(path)]
        self.process = subprocess.Popen([godot, "--headless", "--audio-driver", "Dummy", *where, *(args or [])],
                                        env=launch, stdin=subprocess.DEVNULL, stdout=self._log,
                                        stderr=subprocess.STDOUT)
        self._server.settimeout(timeout)
        try:
            self._peer, _ = self._server.accept()
        except socket.timeout:
            raise AssertionError(f"the game never connected; output:\n{self.output()[-2000:]}") from None
        self._handshake()
        self._lock = threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()
        self.hello = self.expect("hello")
        assert self.hello.get("game") == game_id, self.hello
        assert self.hello.get("token") == "fake-host-token", self.hello

    # -- context manager ----------------------------------------------------

    def __enter__(self) -> "FakeHost":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        try:
            self._peer.close()
        except OSError:
            pass
        self._server.close()
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self._log.close()

    # -- what the game sends and prints -------------------------------------

    def expect(self, kind: str, check=lambda m: True, timeout: float | None = None) -> dict:
        """Wait for a message of this type from the game, skipping others."""
        end = time.monotonic() + (timeout or self.timeout)
        while (left := end - time.monotonic()) > 0:
            try:
                msg = self.inbox.get(timeout=left)
            except queue.Empty:
                break
            if msg.get("type") == kind and check(msg):
                return msg
        raise AssertionError(f"the game never sent {kind}; output:\n{self.output()[-2000:]}")

    def output(self) -> str:
        return self.log_path.read_text(errors="replace")

    def saw(self, text: str, timeout: float = 8.0) -> None:
        """Wait until the game printed a line containing `text`."""
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if text in self.output():
                return
            time.sleep(0.05)
        raise AssertionError(f"the game never printed {text!r}; last lines:\n" + "\n".join(self.output().splitlines()[-12:]))

    # -- what the host sends --------------------------------------------------

    def send(self, msg: dict) -> None:
        data = json.dumps(msg).encode()
        if len(data) < 126:
            header = bytes([0x81, len(data)])
        elif len(data) < 65536:
            header = bytes([0x81, 126]) + struct.pack("!H", len(data))
        else:
            header = bytes([0x81, 127]) + struct.pack("!Q", len(data))
        with self._lock:
            self._peer.sendall(header + data)

    def welcome(self, party: dict | None = None, godot_sdk: int = 0) -> None:
        self.send({"type": "welcome", "protocol_version": 1, "godot_sdk": godot_sdk, "party": party or {}})

    @staticmethod
    def local_seat(index: int, player_id: str, controller: str | None = None) -> dict:
        return {"index": index, "controller": controller or f"pad{index}",
                "occupant": {"kind": "local", "player_id": player_id}}

    @staticmethod
    def ai_seat(index: int) -> dict:
        return {"index": index, "occupant": {"kind": "ai"}}

    def prepare(self, seats: list, players: list, session: str = "s1", wait_ready: bool = True) -> None:
        self.session = session
        self.send({"type": "prepare", "game": self.game_id, "session": session, "seats": seats, "players": players})
        if wait_ready:
            self.expect("ready", lambda m: m.get("session") == session)

    def start(self) -> None:
        self.send({"type": "start", "session": self.session})

    def pause(self) -> None:
        self.send({"type": "pause", "session": self.session})

    def resume(self) -> None:
        self.send({"type": "resume", "session": self.session})

    def dispose(self) -> None:
        self.send({"type": "dispose", "session": self.session})

    def setting(self, key: str, value) -> None:
        self.send({"type": "setting_changed", "game": self.game_id, "key": key, "value": value})

    def frames(self, *pads: dict) -> None:
        self.send({"type": "controller_frame", "controllers": list(pads)})

    def hold(self, pads: dict | list, seconds: float) -> None:
        """Keep sending these pads for a while, then release them for a moment."""
        pads = pads if isinstance(pads, list) else [pads]
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            self.frames(*pads)
            time.sleep(0.05)
        for _ in range(4):
            self.frames(*[frame(controller=p["controller"]) for p in pads])
            time.sleep(0.05)

    def phone(self, player_id: str, data=None, connected: bool | None = None) -> None:
        """A phone screen opened, closed or sent something."""
        if connected is not None:
            self.send({"type": "companion_presence", "player_id": player_id, "connected": connected})
        if data is not None:
            self.send({"type": "companion_message", "player_id": player_id, "data": data})

    # -- WebSocket ------------------------------------------------------------

    def _handshake(self) -> None:
        self._peer.settimeout(self.timeout)
        request = b""
        while b"\r\n\r\n" not in request:
            chunk = self._peer.recv(4096)
            if not chunk:
                raise AssertionError("the game closed the connection during the handshake")
            request += chunk
        headers = {k.strip().lower(): v.strip() for k, v in
                   (line.split(":", 1) for line in request.decode().split("\r\n")[1:] if ":" in line)}
        accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] +
                                                "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self._peer.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                            f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
        self._peer.settimeout(None)

    def _exact(self, count: int) -> bytes:
        data = b""
        while len(data) < count:
            chunk = self._peer.recv(count - len(data))
            if not chunk:
                raise EOFError
            data += chunk
        return data

    def _read(self) -> None:
        message = b""
        try:
            while True:
                first, second = self._exact(2)
                count = second & 127
                if count == 126:
                    count = struct.unpack("!H", self._exact(2))[0]
                elif count == 127:
                    count = struct.unpack("!Q", self._exact(8))[0]
                mask = self._exact(4) if second & 128 else b""
                payload = self._exact(count)
                if mask:
                    payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
                opcode = first & 15
                if opcode == 8:
                    break
                if opcode == 9:
                    with self._lock:
                        self._peer.sendall(bytes([0x8A, len(payload)]) + payload)
                    continue
                if opcode in (0, 1):
                    message += payload
                    if first & 0x80:
                        self.inbox.put(json.loads(message))
                        message = b""
        except (EOFError, OSError, ValueError):
            pass
