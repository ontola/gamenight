# Engine support

Which engines GameNight supports, how far, and where to start. Pick the row for
your engine, then follow its guide. If your engine is not listed as
**Full**, read its open work before you start: you write that part yourself.

## Support levels

- **Full**: an SDK in this repository handles the connection, lifecycle,
  per-seat controllers and the game window. Released games use it and CI runs
  its contract tests.
- **New**: an SDK covers everything Full does, but no released game uses it
  yet and CI checks it without the engine itself.
- **Partial**: an SDK handles the connection and lifecycle. You wire controllers,
  windows or faces into your engine yourself.
- **Protocol only**: no SDK. Write an adapter against the [protocol](/docs/protocol).

| Engine | Level | Start with | Games using it |
| --- | --- | --- | --- |
| [Godot 4](/docs/godot) | Full | [Godot template](/docs/playbook) and `sdk/godot` addon | Spaceracer, Ballkickers, Spellstorm, Hexstead, Downhill Rush, Bombing Bugs, The Builders, Growing Guns, Frog Fighter, The Voice and the Will |
| [LÖVE / Lua](/docs/love) | Full | Shared party runner | Blast Party, Neon Trails, Neon Siege, Volley Trouble, Stack Together, Bubble Buddies |
| [Rust / Bevy](/docs/rust) | Partial | `gamenight-sdk` crate | Demo game |
| [C / C++](/docs/c) | Partial | `sdk/c/gamenight.h` | None yet (transport example only) |
| [Unity](/docs/unity) | New | `sdk/unity` package and the Orb Rush demo | Orb Rush (demo) |
| [Unreal Engine 5](/docs/unreal) | New | `sdk/unreal` plugin and the Orb Rush demo | Orb Rush (demo) |
| Other engines | Protocol only | [Wire protocol](/docs/other-engines) | Mineclonia (Luanti, game-specific adapter) |

## Features per engine

"SDK" means the SDK does it for you. "You" means the protocol carries it but
your game code must handle it. "No" means the SDK cannot do it yet.

| Feature | Godot 4 | LÖVE | Rust | C / C++ | Unity | Unreal |
| --- | --- | --- | --- | --- | --- | --- |
| Connect, hello and launch token | SDK | SDK | SDK | SDK | SDK | SDK |
| Prepare, Ready, Start, Pause, Resume, Dispose | SDK | SDK | SDK | SDK | SDK | SDK (also pauses the world) |
| Controller input per seat | SDK (`frame_for_seat`, `just_pressed`, deadzones) | SDK | You (typed frames) | No | SDK (`FrameForSeat`, `JustPressed`, deadzones) | SDK (`GetPad`, `JustPressed`, deadzones) |
| Hidden preparation and taking the screen | SDK (`GameNightScreen`) | SDK | You | You | SDK (`GameNightScreen`; no hiding on Linux) | SDK (`bAutomaticScreen`) |
| Match settings from the lobby and phone | SDK | SDK | SDK | SDK | SDK | SDK |
| Player names, colours and faces | SDK (`face.gd`) | SDK (`shared.face`) | You (avatar decoding included) | No | SDK (`GameNightFaces`) | SDK (`DrawFace`, `GetFaceTexture`) |
| [Phone screens](/docs/phone-screens) for each player | SDK (`declare_companion_folder`) | SDK (`mode.phone`) | SDK | No | SDK (`DeclarePhoneScreen`) | SDK (`DeclareCompanionFolder`) |
| Performance diagnostics | SDK | SDK | You (manual samples) | No | SDK | SDK |
| Headless contract test in CI | Yes | Yes | Yes | Compile only | Yes, without Unity (dotnet) | Protocol core only, without Unreal |
| Keep the SDK copy current | `sync.py` and CI check | Pinned game sources | Cargo revision | Copy the header | Package Manager git URL | Copy the plugin folder |

## Open work

This list doubles as the roadmap for engine support.

- **Unity**: the package and the Orb Rush demo are new. CI runs the SDK core
  and the demo rules against a fake host and `gamenight-certify` with dotnet,
  and compiles the Unity layer against reference assemblies, but no Unity
  build has been tested on hardware yet: window handling, faces on screen and
  pads. Linux has no window hiding. The Input System code path is not compiled
  in CI.
- **Unreal**: the plugin and the Orb Rush demo are new. CI unit tests the
  plugin's C++ protocol core and runs `gamenight-certify` against it headless,
  but has no Unreal build: the module and the demo are not compiled there, and
  window handling, audio, the world pause, faces on screen and pads are not
  tested on hardware yet.
- **C / C++**: the header has no controller tokens, controller frames, colours
  or faces, and no phone screens. Games still have to parse those messages
  themselves.
- **Rust / Bevy**: the SDK delivers typed events but no Bevy plugin. Input,
  window behaviour and face rendering are left to the game.
- **Godot 4**: Godot has no package manager, so each game vendors the addon.
  Run `sdk/godot/sync.py` and the CI check to keep copies current.

## For agents and code generators

Use this page to choose an approach, then read only the guide for that engine.
Do not invent an SDK where the table says "You" or "No": implement that part
against the [protocol reference](/docs/protocol) and the
[controller rules](/docs/controllers). Before calling an integration done, run
the [integration checks](/docs/testing).
