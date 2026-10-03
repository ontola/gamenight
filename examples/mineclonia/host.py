"""Observed GameNight lifecycle, shared by the phone relay and local launch tools."""
import hashlib
import json
import socket
import time

GAME = "mineclonia-prototype"


class Host:
    def __init__(self, port=17942):
        self.port = port

    def request(self, message=None, receipt=False):
        with socket.create_connection(("127.0.0.1", self.port), timeout=4) as sock:
            sock.sendall(b'{"type":"hello","role":"overlay"}\n')
            stream = sock.makefile("rb")
            welcome = json.loads(stream.readline(16777216))
            if message:
                sock.sendall((json.dumps(message)+"\n").encode())
                # Wait for an observed response, not merely a successful write.
                response = json.loads(stream.readline(16777216))
                while receipt and response.get("type") not in ("settings_accepted","error"):
                    response = json.loads(stream.readline(16777216))
                if response.get("type") == "error":
                    raise RuntimeError(response.get("message", "Host rejected command"))
            return response if receipt and message else welcome["party"]

    def status(self):
        return self.request()

    @staticmethod
    def seats(party):
        players = {p["id"]: p for p in party.get("players", [])}
        result = []
        for seat in party.get("seats", []):
            occupant = seat.get("occupant", {})
            if occupant.get("kind") != "local":
                continue
            player = occupant.get("player")
            if player is None:
                player = occupant.get("player_id")
            if player is None or not seat.get("controller"):
                continue
            # Identity is the host player ID, never the display name or SDL index.
            result.append({"index": seat["index"], "player": str(player),
                           "revision": int.from_bytes(hashlib.sha256((str(player)+"|"+seat["controller"]).encode()).digest()[:6], "big")})
        return result

    def launch(self, expected_seat, players=2, timeout=85):
        if players != 2:
            raise ValueError("Mineclonia currently supports exactly two local players")
        deadline = time.monotonic()+timeout
        party = self.status()
        self.check_players(party, expected_seat, players)
        current = party.get("active_session") or {}
        if current.get("game") == GAME:
            self.request({"type": "close_overlay"})
        else:
            warm = party.get("warm_session") or {}
            if warm.get("game") != GAME:
                raise RuntimeError("Mineclonia must be in this host's next-game slot")
            while warm.get("phase") != "ready":
                if time.monotonic() >= deadline:
                    raise TimeoutError("Both Mineclonia views did not become ready")
                time.sleep(.2)
                party = self.status()
                self.check_players(party, expected_seat, players)
                warm = party.get("warm_session") or {}
                if warm.get("game") != GAME:
                    raise RuntimeError("Next game changed while preparing")
            self.request({"type": "next"})
        while time.monotonic() < deadline:
            party = self.status()
            self.check_players(party, expected_seat, players)
            current = party.get("active_session") or {}
            if current.get("game") == GAME and current.get("phase") == "running" and not party.get("overlay_open"):
                return party
            time.sleep(.1)
        raise TimeoutError("Host did not confirm Mineclonia started")

    @classmethod
    def check_players(cls, party, expected_seat, count):
        seats = cls.seats(party)
        if expected_seat not in seats:
            raise ValueError("Player left or changed controller")
        if len(seats) != count:
            raise ValueError(f"Join with {count} controllers in the lobby first")
