# Bring your game to the couch

GameNight puts local multiplayer games in one lobby. Players pick a game, keep their controller and profile, and return to the lobby with Back. Your game keeps its engine and runs in its own process.

Follow [Your first game](/docs/first-game) to run your own build in the lobby,
test it, upload a private preview and publish a release.

## Pick your engine

| Engine | Starting point | What is included |
| --- | --- | --- |
| [LÖVE / Lua](/docs/love) | Shared party runner | Lifecycle, controller mapping, window handling and faces |
| [Rust / Bevy](/docs/rust) | Rust SDK | Typed protocol events; your engine handles input consumption and rendering |
| [Godot 4](/docs/godot) | Godot addon | Lifecycle, host controller frames, screen ownership and a face helper |
| [C / C++](/docs/c) | Single-header adapter | TCP transport and lifecycle; no controller stream or face decoder yet |
| [Unity, Unreal and others](/docs/other-engines) | Wire protocol | Implement the connection and engine adapter yourself |

These are implementation starting points, not certifications. The engine guides call out missing support before you copy anything.

## What a good integration does

Prepare a playable frame while hidden and silent. Show it when the host says Start. Pause simulation and audio when players return to the lobby, then resume the same state. Keep processing host messages throughout.

Controllers follow player seats. Faces, names and colours follow player IDs. Your game owns the rounds and score screens; finishing a round does not end the GameNight session.

Read [Game lifecycle](/docs/lifecycle), then [Controllers & players](/docs/controllers). Add [faces and colours](/docs/faces) once play is reliable.

## Have a game already?

[Tell us about it](/developers). An email and a link are enough to start. We can help with integration, or you can work through these guides yourself.

## How these docs stay current

These pages are built from Markdown in the public repository. Code excerpts are read from source, not pasted copies. CI checks generated pages, internal links and watched implementation files. The Rust example compiles against the SDK; the C example compiles against the header.

Changes to watched implementation files make the docs check fail until someone
reviews and regenerates the affected pages. Godot adapter behavior has headless
regression tests; those do not certify your game's callbacks or physical devices.
Publishing backend changes are reviewed in the private repository too. Checks
catch structural drift, not every outdated explanation. Physical controller and
window tests still matter.
