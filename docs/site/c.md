# C / C++

Use [Your first game](/docs/first-game) for local host setup, a launchable shelf
and the path from testing to publication.

`sdk/c/gamenight.h` is a single-header TCP client for C99 and C++. It uses newline-delimited JSON on the same port as the WebSocket transport. POSIX and Winsock are supported.

## Add the header

```c
#define GAMENIGHT_IMPLEMENTATION /* In exactly one translation unit. */
#include "gamenight.h"
```

Copy the header into your project. Link Winsock (`ws2_32`) on Windows. Keep calling `gn_poll` from your loop, including when gameplay is paused. It returns 1 for an event, 0 when nothing is available and -1 on disconnection.

## Connect from the launch environment

This is the startup path in the checked-in C example:

::: source c examples/c-game.c "int main(void)" "    for (;;)"

`GN_ERR_NOT_LAUNCHED` selects standalone mode. Other connection errors should stop the managed launch rather than open a disconnected game window.

## Event data

The current adapter’s event types are:

::: source c sdk/c/gamenight.h "typedef enum {\n    GN_NOTHING" "typedef enum { GN_EMPTY"

On Prepare, load your level while hidden, then call `gn_ready`. Start shows play. Pause freezes simulation and audio; Resume restores them. Dispose frees session resources. Keep the socket alive for the next Prepare.

## What the header does not supply

The current `gn_seat` carries index, occupant, player ID and name. It does not expose controller tokens, controller frames, clothing colours, skin colours or face artwork. Implement those fields and message handling, or use a JSON client that preserves the full [protocol](/docs/protocol). Do not assign local joystick enumeration to seat indices as a workaround.

The built-in name parser also replaces JSON `\\uXXXX` escapes with `?`. Extend it if your game needs complete escaped Unicode names. Parsed fields have fixed limits even though the receive buffer grows; a custom face decoder needs its own storage and parsing.

## Compile the transport example

```sh
cc -std=c99 -Wall -Wextra -Werror -I sdk/c -o /tmp/c-game examples/c-game.c
```

This builds a timer-based protocol example on POSIX. It is not a playable reference with controller or face support. The docs CI compiles it to detect API drift; release confidence comes from [testing the actual packaged game](/docs/testing).

The C client grows its receive buffer for player artwork, up to 8 MiB. Call `gn_close()` when the connection ends to release it. Receiving artwork does not imply that the adapter renders faces; that remains a separate capability.
