# GameNight for C and C++

Start with the [C/C++ integration guide](../../docs/site/c.md), published in
[GameNight Docs](https://gamenight.ontola.io/docs/c).

`gamenight.h` supplies a single-header C99 client for newline-delimited JSON over
TCP. Define `GAMENIGHT_IMPLEMENTATION` in one translation unit. C++ linkage,
POSIX sockets and Winsock are supported; Windows builds link `ws2_32`.

The current header handles lifecycle and settings messages and resolves seat
names. It does not expose controller tokens/frames, skin or clothing colours,
or face artwork. Its name decoder substitutes `?` for JSON Unicode escapes.
Those gaps must be addressed for a complete integration.

The [C example](../../examples/c-game.c) is a timer-based transport example,
not a playable or fully certified reference. Compile it on POSIX with:

```sh
cc -std=c99 -Wall -Wextra -Werror -I sdk/c -o /tmp/c-game examples/c-game.c
```

Keep polling during pause. Only Start/Resume commands make gameplay active;
window focus does not. The game owns the next round and exits on host loss.
The client buffers large profile messages on the heap, with an 8 MiB limit.
Call `gn_close()` after a disconnect to release the socket and receive buffer.
This allows artwork to pass through the transport; it does not add face
rendering support to the C adapter.
