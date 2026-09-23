# Integrating your game with GameNight

GameNight supplies the party, seats and lifecycle. Your game owns gameplay,
rounds and results. Players can stay in a game until they choose another one.

Start from the [shared LÖVE runner](../games/love-party/README.md) for a Lua game.
The [wire reference](protocol.md) defines messages; the
[release requirements](../contract/requirements.json) define what must work.
A successful handshake alone is not a complete integration.

## Connect

The host launches your process with `GAMENIGHT=1`, `GAMENIGHT_ADDR`,
`GAMENIGHT_GAME_ID` and `GAMENIGHT_TOKEN`. In managed mode, skip your title,
sign-in and controller-assignment screens. Keep standalone behavior separate.

Connect to the address over WebSocket, or send newline-delimited JSON over TCP.
Both transports use the same port, normally `127.0.0.1:7912`.

```json
{"type":"hello","role":"game","game":"my-game","token":"<GAMENIGHT_TOKEN>"}
```

The host returns `welcome` with `protocol_version` and the party snapshot.
Use the token supplied for this launch. One connected process serves one title;
that process may receive several sessions over its lifetime.

## Prepare before taking the screen

On `prepare`, retain the session ID, seats, player profiles and settings. Load
assets, compile shaders and prepare a real frame before replying `ready`.
Keep the window hidden and audio silent. Do not steal focus during launch.

```json
{"type":"progress","session":"<session UUID>","percent":40,"label":"Loading arena"}
{"type":"ready","session":"<session UUID>"}
```

Progress is optional. Ready must mean that Start can show playable content
without another loading screen. Do not require player input to finish preparing.
Keep the connection and lifecycle handling active while hidden or paused.

On `start`, show the prepared window and begin play. On `pause`, stop simulation,
timers and audio, then hide the game so the lobby can appear. On `resume`, show
the same game state and continue. Pause and resume are required for release,
including when the game is showing results rather than active gameplay.

On `dispose`, stop the session, hide the window, silence audio and release session
resources. Wait for another Prepare. If the host connection is lost, exit cleanly
rather than leaving a game window or background process behind.

## Controllers belong to players

A seat is a playable position. Its occupant identifies a player; its `controller`
is an opaque host device token. Neither the seat index nor an `ordinal:N` token
is an index into SDL or another engine's local gamepad list.

Managed bundled games consume the host's `controller_frame` stream and match
`controllers[].controller` to `seats[].controller`. Do not enumerate local pads
and assign the first pad to the first seat. Enumeration can differ between the
host and game, especially after disconnects.

Use [the shared input adapter](../games/love-party/shared/input.lua) or implement
[the frame contract](protocol.md#bundled-games-authoritative-controller-input).
Rust games receive the same stream as `GameEvent::ControllerFrame` from
`GameNight::next_event()`. Keep the latest frame and look up each non-AI seat by
its `seat.controller` token. An empty frame, absent token or a frame older than
250 ms means neutral input. `controller_input` is a separate activity report
for presence and joining; calling it does not supply movement to the game.
Process released buttons and disconnected devices; stale input must become
neutral. Never assign one device to two players or substitute another player's
controller when a device disappears. Standalone input is a separate path.

Create bots for `ai` seats and no controllable pawn for `empty` seats. Player
profiles are keyed by player ID, not array position. Preserve that association
when seats or profiles change.

## Back, focus and fullscreen

Back/Select requests the lobby with `request_overlay`. The host pauses the game.
From the lobby, Back/Select can resume a paused game. Accept one transition per
press, require release, and guard against the same held press reaching the newly
focused window. The bundled [Back gate](../games/love-party/shared/back_gate.lua)
requires one second of release before another accepted press.

**Never start or resume automatically on window focus.** Focus can change while
the host is opening the lobby. Only explicit host Start/Resume commands change
the running state. `request_start` exists for an explicit user request, not as a
focus-event handler.

Use a borderless window covering the display, not exclusive fullscreen. Configure
it before reporting Ready so switching does not change display resolution. The
bundled [window helper](../games/love-party/shared/window.lua) prepares off-screen,
then hides/shows the window. Its Windows path adds one off-screen pixel row to
avoid exclusive-like presentation on affected drivers. Retain that behavior when
reusing the helper. Test focus changes on the target OS; one platform's result is
not proof for another.

## Rounds continue inside the session

Your game shows its own scores, winner names and results screen, then starts the
next round. Pause also freezes the results countdown. Do not wait for GameNight
to create a fresh session after every round.

You may send `finished` as a round notification. It keeps the active session,
pause state and prepared next game intact. It opens voting state but does not
force a vote, return to the lobby or advance the playlist. Explicit votes may
still request a transition.

Play next switches games. Skip only replaces the upcoming game. An explicit
replay command creates a new session; an ordinary next round stays in the same
session. Do not confuse either with an automatic end-of-match transition.

## Live players and settings

After Prepare, send `participation` before Ready to receive `party_updated`.
Set `instant_join` to true if your running match can accept new players, or false
for a fixed roster. Apply profile changes without resetting the match. Report
real human activity through `controller_input`; see the
[presence contract](protocol.md#player-activity-sleep-and-joining-during-play).
`party_state` is the overlay snapshot, not a substitute for the game update API.

`declare_settings` exposes game options. Handle `setting_changed` and document
which settings apply immediately or at the next round. See
[match settings](protocol.md#match-settings). Log protocol errors and ignore
unknown fields rather than crashing.

## Player faces and colours

Name, clothing colour, skin colour and artwork are separate player fields.
Show the actual player name and preserve profile ownership. Draw skin beneath
the transparent face artwork; do not recolour the artwork with the clothing tint.

```lua
local Face = require("shared.face")
Face.drawFace(player, x, y, radius)
```

The [face API](faces.md) uses a head centre and radius, preserving hat padding.
It supports mirroring, rotation and live artwork changes. Rust integrations use
`gamenight_protocol::Avatar::parse` and `head_layout()`.
A player portrait is appropriate for vehicles or other non-human characters.

Faces, names and colours have separate checks. First-party games must pass all
three for release; a colour check does not prove that a face was rendered.

## Artwork for the catalog and lobby

Supply separate fields in the shelf entry:

```json
{
  "id":"my-game",
  "title":"My Game",
  "cover":"art/cover.png",
  "icon":"art/icon.png",
  "screenshot":"art/gameplay.png"
}
```

Use a portrait cover for Up next, a square icon for case spines, and a real
gameplay screenshot for the TV. They are distinct assets. Colour is an optional
accent, not a replacement for artwork. Missing artwork should retain a readable
title fallback.

Shelf-relative PNG paths are resolved by the host and sent as data URIs. For
catalog publication, follow the [catalog guide](../catalog/README.md) and the
current manifest validation. Do not put launch paths or credentials in profile
messages.

## Verify before shipping

Run the [contract checks](game-contract-verification.md) against packaged builds.
The versioned requirements distinguish essential play behavior, personalisation
and optional party extras. The catalog score uses matching platform/build evidence;
source declarations alone do not earn a pass.

Also follow the [desktop checklist](desktop-integration-checklist.md) with real
controllers. Test two different profiles, reversed connection order, unplugging
a pad, nonzero stick input while the lobby is unfocused, live artwork updates,
repeated Back/Resume and several game switches.
Synthetic input checks cannot prove physical controller ownership on your machine.
