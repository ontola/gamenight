# Engine support

Which engines GameNight supports, how far, and where to start. Pick the row for
your engine, then follow its guide. If your engine is not listed as
**Full**, read its open work before you start: you write that part yourself.

## Support levels

- **Full**: an SDK in this repository handles the connection, lifecycle,
  per-seat controllers and the game window. Released games use it and CI runs
  its contract tests.
- **Partial**: an SDK handles the connection and lifecycle. You wire controllers,
  windows or faces into your engine yourself.
- **Protocol only**: no SDK. Write an adapter against the [protocol](/docs/protocol).

| Engine | Level | Start with | Games using it |
| --- | --- | --- | --- |
| [Godot 4](/docs/godot) | Full | `sdk/godot` addon | Spaceracer, Ballkickers, Growing Guns, Frog Fighter, Downhill Rush, The Voice and the Will |
| [LÖVE / Lua](/docs/love) | Full | Shared party runner | Blast Party, Neon Trails, Neon Siege, Ricochet Club, Volley Trouble, Stack Together, Bubble Buddies, Pinpals, Hexstead |
| [Rust / Bevy](/docs/rust) | Partial | `gamenight-sdk` crate | Demo game, Bevy lobby |
| [C / C++](/docs/c) | Partial | `sdk/c/gamenight.h` | None yet (transport example only) |
| [Unity](/docs/other-engines) | Protocol only | Wire protocol | None |
| [Unreal](/docs/other-engines) | Protocol only | Wire protocol | None |
| Other engines | Protocol only | [Wire protocol](/docs/other-engines) | Mineclonia (Luanti, game-specific adapter) |

## Features per engine

"SDK" means the SDK does it for you. "You" means the protocol carries it but
your game code must handle it. "No" means the SDK cannot do it yet.

| Feature | Godot 4 | LÖVE | Rust | C / C++ | Unity / Unreal |
| --- | --- | --- | --- | --- | --- |
| Connect, hello and launch token | SDK | SDK | SDK | SDK | You |
| Prepare, Ready, Start, Pause, Resume, Dispose | SDK | SDK | SDK | SDK | You |
| Controller input per seat | SDK (`frame_for_seat`) | SDK | You (typed frames) | No | You |
| Hidden preparation and taking the screen | SDK (`GameNightScreen`) | SDK | You | You | You |
| Match settings from the lobby and phone | SDK | SDK | SDK | SDK | You |
| Player names, colours and faces | SDK (`face.gd`) | SDK (`shared.face`) | You (avatar decoding included) | No | You |
| Phone screens for each player | SDK | You | SDK | No | You |
| Performance diagnostics | SDK | SDK | You (manual samples) | No | You |
| Headless contract test in CI | Yes | Yes | Yes | Compile only | No |
| Keep the SDK copy current | `sync.py` and CI check | Pinned game sources | Cargo revision | Copy the header | n/a |

## Open work

This list doubles as the roadmap for engine support.

- **Unity**: no package yet. Needed: a C# client for the connection and
  lifecycle that keeps running while `Time.timeScale` is zero, controller frames
  mapped to seats, a window helper and a sample scene.
- **Unreal**: no plugin yet. Needed: a C++ plugin on the game thread with the
  same scope as Unity, plus packaging notes for Windows and macOS.
- **C / C++**: the header has no controller tokens, controller frames, colours
  or faces, and no phone screens. Games still have to parse those messages
  themselves.
- **Rust / Bevy**: the SDK delivers typed events but no Bevy plugin. Input,
  window behaviour and face rendering are left to the game.
- **LÖVE**: phone screens are not in the shared runner yet; Hexstead sends the
  messages itself.
- **Godot 4**: Godot has no package manager, so each game vendors the addon.
  Run `sdk/godot/sync.py` and the CI check to keep copies current.

## For agents and code generators

Use this page to choose an approach, then read only the guide for that engine.
Do not invent an SDK where the table says "You" or "No": implement that part
against the [protocol reference](/docs/protocol) and the
[controller rules](/docs/controllers). Before calling an integration done, run
the [integration checks](/docs/testing).
