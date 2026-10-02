# Controllers & players

A controller belongs to a seat through its host token. A profile belongs to a player through its ID. Those associations must survive switching games and reconnecting devices.

## Match tokens, not array positions

For each local seat, find the `controller_frame.controllers` entry whose `controller` equals `seat.controller`. Look up the profile using `seat.occupant.player_id`. Neither list order nor a token such as `ordinal:2` tells you an SDL, Godot or engine device index.

The host frame uses these fields:

::: source rust crates/gamenight-protocol/src/lib.rs "pub struct ControllerState {" "#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]"

Axes are left X/Y, right X/Y and left/right trigger. Divide signed axis values by 32767. The button bits are A, B, X, Y, LB, RB, Back, Start, LS, RS, Up, Down, Left and Right, beginning at bit zero.

## Release stale input

An empty frame releases every controller. A missing token releases that device. More than 250 ms since the last frame means neutral input. Never borrow another device to fill a gap.

The LÖVE runner already applies this rule:

::: source lua games/love-party/shared/input.lua "function M.updateHost(controllers)" "function M.bind(players, pads)"

AI seats receive bots. Empty seats receive no controllable pawn. Keep standalone device enumeration separate from managed input.

## Joining and changing profiles

After Prepare, send `participation` before Ready. Set `instant_join` only if the match can accept new players immediately. Handle `party_updated` without resetting the running match. Update names, clothing, skin and face artwork independently.

`controller_input` reports activity for presence and joining. It does not send movement to the game. Replacement lobbies use runtime-owned sampling; the legacy platformer publishes its own authenticated frames. Games consume the same frame format in both modes. See [Build a lobby](/docs/lobbies#input-and-screen-ownership).

## Back must toggle once

Request the lobby with `request_overlay`. Use press/release edges and the shared one-second release gate. The same held press must not reopen the game after focus changes. Never issue Resume or `request_start` from a focus callback.

## Check real devices

Test two different profiles, reversed connection order, unplugging one pad and reconnecting it. Then switch between games. Synthetic frames can check token matching, but they do not prove that a physical controller belongs to the right player on your machine.
