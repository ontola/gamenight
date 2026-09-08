# GameNight for C and C++

One header, no dependencies, no build-system changes.

```sh
cp sdk/c/gamenight.h your-engine/src/
```

```c
#define GAMENIGHT_IMPLEMENTATION   /* in exactly one .c/.cpp file */
#include "gamenight.h"
```

C99, C++-safe (`extern "C"`), POSIX and Winsock. Nothing allocates: one
`gn_client` is ~24 KB of fixed buffers.

## Why a C SDK exists

The [protocol](../../docs/protocol.md) is JSON over a socket, which is free
in Rust, Godot and JavaScript and distinctly not free in a C++ engine that
has neither a JSON parser nor a WebSocket client — SuperTuxKart, Raydium,
most of the couch classics worth adapting. This header is the whole
dependency: a socket, a line reader, and just enough JSON.

It speaks the **plain transport** (one JSON object per line, no handshake,
no frame codec). The daemon sniffs which transport a connection is using, so
this is the same protocol a WebSocket client speaks, minus several hundred
lines of SHA-1, base64 and frame masking that would otherwise land in your
engine.

## The whole API

```c
gn_result gn_connect_from_env(gn_client *c, const char *fallback_game_id);
gn_result gn_connect(gn_client *c, const char *addr, const char *game, const char *token);
int       gn_poll(gn_client *c, gn_event *ev);   /* 1 = event, 0 = nothing, -1 = gone */
void      gn_ready(gn_client *c, const char *session);
void      gn_progress(gn_client *c, const char *session, int percent, const char *label);
void      gn_finished(gn_client *c, const char *session);
void      gn_request_overlay(gn_client *c);
void      gn_declare_settings(gn_client *c, const char *settings_json);
void      gn_close(gn_client *c);
```

`gn_connect_from_env` returns `GN_ERR_NOT_LAUNCHED` when `GAMENIGHT` isn't
`1`. That is not a failure — it means nobody launched you into a party, so
boot your title screen and play standalone. One binary, two modes.

`gn_poll` never blocks. Call it once per frame from your existing game loop;
it returns `-1` exactly once, when the daemon is gone and the night is over.

Seats arrive with names already resolved:

```c
case GN_PREPARE:
    for (int i = 0; i < ev.seat_count; i++) {
        if (ev.seats[i].occupant == GN_EMPTY) continue;
        spawn_player(ev.seats[i].index, ev.seats[i].name);  /* "Ada", not "P1" */
    }
    gn_ready(&gn, ev.session);
    break;
```

You never have to join `seats[]` against `players[]` yourself — that join is
the single most annoying part of hand-rolling this protocol, so the header
does it.

## Worked example

[`examples/c-game.c`](../../examples/c-game.c) is a complete integration:
connect, warm, report progress, start, finish, survive dispose, stay
resident. Build and certify it exactly as you would your own game:

```sh
cc -std=c99 -I sdk/c -o /tmp/c-game examples/c-game.c
cargo run -p gamenight-certify -- c-game -- /tmp/c-game
```

## Limits, stated honestly

- `GN_MAX_SEATS` 8, `GN_MAX_PLAYERS` 8, messages up to 16 KB. Raise the
  `#define`s before including if your party is somehow bigger.
- `\uXXXX` escapes in player names decode to `?`. Names are display-only and
  this keeps the parser to a page; if your engine has real UTF-8 handling,
  widen `gn__str`.
- `GN_SETTING_CHANGED` hands back the raw JSON scalar (`"true"`, `"5"`,
  `"\"volcano\""`) rather than a tagged union — you declared the setting, so
  you already know its kind.
- No reconnect logic. If the socket drops, the daemon is gone; exit.
