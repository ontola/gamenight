# Mineclonia couch prototype

This is an isolated experiment, not a catalog game. A patched Luanti 5.17.0
Windows build adds isolated controller input and two borderless views. The engine
build and routing checks pass; the user confirmed independent controller input in both standalone views.
See [controller setup and controls](engine/README.md).

## Run on Windows

Requires Python 3.11 or newer. Everything downloaded or saved stays under one
directory, by default `E:\gamenight-host\prototypes\mineclonia`. Override it
with `--root PATH` on each command. The server listens only on loopback.

```powershell
python prototype.py setup
python prototype.py server
# In a second terminal:
python prototype.py clients
python prototype.py status
python test_live.py
python prototype.py demo
python prototype.py undo
python prototype.py stop
```

`clients` opens two diagnostic windows, Couch1 and Couch2, in one shared world.
They are not automatically tiled and are not controller-isolated. The clients
have separate configs, logs and identities. Client 2 is muted to avoid duplicate
audio. This is an audio policy, not a verified mix. Close their windows after
stopping the server; stop saves the world but stock Luanti returns clients to its
menu. Do not install new mods while the server is running.

## Verified on 2 October 2026

Downloaded official packages and checked compressed size and SHA-256:

| Package | Bytes | SHA-256 |
| --- | ---: | --- |
| [Luanti 5.17.0 win64](https://github.com/luanti-org/luanti/releases/tag/5.17.0) | 17,539,019 | `3ce20c77f5c206a988d7a6b883439e2759e3cf67428c9dbcf99ecd2936da631c` |
| [Mineclonia 0.123.1](https://content.luanti.org/packages/ryvnf/mineclonia/) | 29,204,259 | `abeacf4e202d6e01a63119a36b46751eb6abfd42948a0b06e1ba8f63fb849e59` |

Two actual Windows clients connected to the real local server. `test_live.py`
verified both players' physics values changed, undo restored them, retry returned
the original result, and stale revisions and invalid ranges were rejected.
These checks read the engine's player objects, not mocked responses. The server
was shut down through `core.request_shutdown`, which saves the world. After
restart, the bridge revision and restored settings persisted; both clients
reconnected and the same real-player physics test passed again.

The user confirmed independent movement and camera input with two 8BitDo controllers.
The managed adapter also passed three real-daemon start/pause/resume cycles.
Inventory usability, audio quality, frame rate and physical Back across the lobby
transition are not yet verified.

## Why the controller build needs a patch

Source inspected at Luanti tag `5.17.0`:

- `src/client/keycode.cpp`: gamepad `KeyPress` keeps the button/axis but discards
  the event's device ID. Both connected pads can therefore affect one client.
- `src/client/game.cpp`: input is cleared when the window is inactive, and camera
  updates require active/focused state. Enabling background SDL events alone is
  insufficient.
- [Official controller documentation](https://docs.luanti.org/for-players/gamepads/)
  explicitly excludes controller menus. Inventory and formspec navigation need
  additional engine work.

The patch implements per-client device binding, hotplug/release handling,
background movement and camera input without mouse capture, a controller inventory
cursor, and side-by-side borderless placement. The launcher preserves device paths
across enumeration changes and refuses missing or ambiguous pads. No OS input
injection or focus-stealing workaround is used. The experimental `managed.py` adapter now routes host controller frames and the
shared pause lifecycle through the real lobby; see `engine/README.md`.
Do not certify it until two physical controllers pass the checks below.

## Reversible live changes

The running bridge declares eight live numeric controls from
`mods/gamenight_bridge/settings.json`. The world mod, Python validation, lobby
controls and assistant discovery use this same contract:

| Control | Range | Effect |
| --- | --- | --- |
| Gravity | 0.25–2× | Downward acceleration |
| Jump strength | 0.25–2× | Jump impulse |
| Movement speed | 0.25–3× | All players' movement |
| Air steering | 0.1–3× | Acceleration while airborne |
| Sneaking speed | 0.1–3× | Crouching speed, combined with movement speed |
| Time of day | 0–24 hours | Set the clock once; 12 is noon |
| Day/night speed | 0–240 | Game seconds per real second; 0 freezes, 72 is normal |
| Bounce pads | 0–3 | Live strength; 0 disables the effect |

Movement uses `playerphysics.add_physics_factor` with GameNight's own ID, so it
composes with equipment and potion effects. Joining players receive active rules.
A single request can change several controls atomically. Undo restores just those
controls, including the previous clock when time was explicitly changed. Keep
accepts the change. Clock progression does not count as a settings edit.

Bounce pads are registered with the bridge at startup. Enabling them supplies
eight pads per player once; players place them using normal building controls.
Strength changes and disabling the effect are live. Undo does not delete placed
blocks or inventory items. The assistant receives descriptions, units, current
values, ranges and application timing. It should use `set`, including for a
request phrased as a bounce-pad “mod”. These controls need no world or client
restart once this bridge version is loaded. Updating the bridge itself still
requires a world restart.

The Python adapter writes a bounded JSON request atomically into the isolated
world's `gamenight` directory. A single-writer lock prevents overlapping requests;
the mod validates the revision, action and values. IDs and results are retained
in mod storage. A retry never re-executes an acknowledged action. This file
mailbox is a trusted local adapter, not an internet API or arbitrary Lua executor.

The older, separate `bounce_pad` recipe generates a Lua mod from a trusted template.
Its only input is a finite bounce strength from 0 to 3. Zero disables bouncing.
Arbitrary Lua, URLs and filesystem paths are rejected. `modding.py` stages the
source by SHA-256 and boots a separate, disposable Mineclonia world to check it.
A failed test never stops the current game. After a passing test, `managed.py`
rechecks the player and revision, stops both views, saves the world, checkpoints
it, installs the mod and reconnects the views. An interrupted installation rolls
back from its checkpoint on the next adapter start. Failed worlds are preserved.
Undo Mod restores the previous recipe through this same pipeline; it does not
rewind world progress. Physics Undo and Keep remain separate.

The generated-node startup check passes. The complete live install/reconnect
flow still needs a playtest; do not advertise arbitrary mod generation or store
certification. World saves are not settings presets. No catalog entry is added.


## Experimental room relay

`relay.py` connects this isolated world to a local GameNight cloud preview. It
uses `--daemon-port 17942` to publish the real lobby seats, opaque player IDs,
controller-binding revisions and active/warm session ID. A phone remains linked
to its actual lobby player, not a separate diagnostic Couch1 account. World
status must be fresh before it advertises live controls. Discovery
includes `controls` with game/instance/revision, setting descriptions, units,
application timing, numeric bounds, current values, and `can_undo`. A selection's `command` contains `action` (`set`, `undo`,
`keep`, `launch`, `mod`, `undo_mod`), the exact instance, expected revision, and
numeric values. `launch` requires `{ "players": 2 }` and two joined controllers.
It waits for the real daemon to report Running. On older bridges, `mod` takes `{ "bounce": 1.5 }`;
`undo_mod` takes an empty values object. Its receipt
reports the actual game result. Ordinary queue acknowledgements cannot confirm
a settings change.

The adapter rejects expired requests, absent players, different worlds, missing
revisions, unsupported keys and invalid values before writing the mailbox. Lua
checks bounds and revision again and deduplicates IDs durably. This is a prototype
extension, not a declaration that all GameNight SDKs support these controls.
The ordinary desktop discovery bridge does not advertise this capability yet.

Run `python -m unittest test_relay` for boundary validation. The private session
agent handles AI models, accounts and the phone preview; none of that belongs
in this public game adapter. No game listing is created by this experiment.


## Unified lobby session

The managed adapter now owns and supervises its isolated world server. Do not
start `prototype.py server` alongside `lobby_test.py`. The server listens on
loopback and must keep a fresh heartbeat. A crashed server cannot remain Ready.
The adapter installs a small Mineclonia join/disconnect race guard reproducibly:
when a departing peer has no player-information record, skip its version notice.

`GAMENIGHT_ASSISTANT_URL` enables an optional small computer beside the TV and a
Start-menu “Session assistant” entry. Hold Y near the computer to open that URL.
It opens a browser window; this is not an embedded browser or automatic microphone
capture. The cloud/account/voice service remains outside this public adapter.
`GAMENIGHT_LINKS_URL` lets the native lobby poll a loopback profile bridge while
`GAMENIGHT_JOIN_URL` remains reachable from phones.

Run `python -m unittest discover -s examples/mineclonia -p 'test_*.py'` for host
routing, two-player launch boundaries, mod validation failure and checkpoint
recovery. Fixtures are not evidence of physical controller operation. The earlier
three live lifecycle cycles and independent controller test predate this unified
agent implementation; repeat them before marking this flow verified.

## Real model and engine test

`live_test_world.py --runtime PATH --root NEW_TEST_DIRECTORY` creates a disposable
world on port 30129 and starts two real clients with controllers disabled. It
never opens or changes the normal play world. Create a `stop` file inside that
new directory to save and close its processes. Engine logs remain there.
The private `deploy/cloud/test-agent-world.py` drives the real model and cloud
against this world; AI-provider policy and evaluation prompts stay internal.
Unit checks: `python -m unittest test_settings test_relay test_mod_lifecycle`.
Physical controller use is not exercised by this live-rules test.
