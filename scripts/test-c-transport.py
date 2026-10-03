"""Exercise fragmented artwork messages, following frames and bounded C SDK buffers."""
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = r'''#define _POSIX_C_SOURCE 200809L
#define GAMENIGHT_IMPLEMENTATION
#include "gamenight.h"
#include <time.h>
int main(int argc, char **argv) {
    gn_client client;
    gn_event event;
    int prepares = 0;
    if (argc != 3 || gn_connect(&client, argv[1], "transport-test", NULL) != GN_OK) return 2;
    for (int i = 0; i < 5000; i++) {
        int got = gn_poll(&client, &event);
        if (got < 0) {
            gn_close(&client);
            return strcmp(argv[2], "bounded") == 0 ? 0 : 3;
        }
        if (got == 1 && event.type == GN_PREPARE) {
            if (event.player_count != 8 || event.seat_count != 8 ||
                strcmp(event.seats[7].name, "Player 8") != 0) return 4;
            prepares++;
        }
        if (got == 1 && event.type == GN_START) {
            gn_close(&client);
            return prepares == 1 ? 0 : 5;
        }
        struct timespec nap = {0, 2000000};
        nanosleep(&nap, NULL);
    }
    gn_close(&client);
    return 6;
}
'''

class TransportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        root = Path(cls.temp.name)
        source = root / "transport.c"
        source.write_text(FIXTURE)
        cls.binary = root / "transport"
        subprocess.run(["cc", "-std=c99", "-Wall", "-Wextra", "-Werror", "-I", str(ROOT / "sdk/c"), "-o", str(cls.binary), str(source)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def exercise(self, data, mode):
        with socket.socket() as server:
            server.bind(("127.0.0.1", 0))
            server.listen()
            server.settimeout(10)
            errors = []
            def send():
                try:
                    conn, _ = server.accept()
                    with conn:
                        conn.settimeout(10)
                        conn.recv(4096)  # hello
                        for offset in range(0, len(data), 4093):
                            conn.sendall(data[offset:offset + 4093])
                except (BrokenPipeError, ConnectionResetError):
                    if mode != "bounded": errors.append("Unexpected disconnection")
                except Exception as error:
                    errors.append(str(error))
            worker = threading.Thread(target=send)
            worker.start()
            result = subprocess.run([str(self.binary), f"127.0.0.1:{server.getsockname()[1]}", mode], timeout=15)
            worker.join(timeout=12)
            self.assertFalse(worker.is_alive())
            self.assertEqual(errors, [])
            self.assertEqual(result.returncode, 0)

    def test_eight_large_profiles_and_following_start(self):
        players = [{"id": str(i), "name": f"Player {i+1}", "avatar": {"png": "A" * 350000, "hat_png": "B" * 350000}} for i in range(8)]
        seats = [{"index": i, "occupant": {"kind": "local", "player_id": str(i)}} for i in range(8)]
        prepare = {"type": "prepare", "session": "large-profile", "players": players, "seats": seats}
        data = (json.dumps(prepare) + "\n" + json.dumps({"type": "start", "session": "large-profile"}) + "\n").encode()
        self.exercise(data, "profiles")

    def test_oversized_unterminated_message_is_rejected(self):
        self.exercise(b"x" * (9 * 1024 * 1024), "bounded")

if __name__ == "__main__":
    unittest.main()
