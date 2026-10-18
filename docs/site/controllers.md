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

After Prepare, send `participation` before Ready (`GameNight.notify_participation` in Godot). Set `instant_join` only if the match can accept new players immediately. Handle `party_updated` without resetting the running match. Update names, clothing, skin and face artwork independently.

What our games do with a changing roster:

- **Fixed roster per round** (`instant_join: false`) is the simple default: a
  racing or sports game applies the new seats when the next round starts.
- **Drop in mid-round** (`instant_join: true`) suits games where one more
  player does not break fairness: spawn the newcomer near the others, or
  behind the leader in a race, rather than at the start.
- **A joining player replaces a bot**, never the other way round. AI never
  takes a seat a person holds.
- **A player who leaves** keeps their score until the round ends; their pawn
  can stand still, fade out or become a bot.
- **Colours can collide.** Two profiles may pick the same colour. Keep each
  player's own colour where you can and only shift the later duplicate.
- **Read the seat count from Prepare.** Don't assume a maximum. Declare
  `players_min` and `players_max` honestly in your catalog entry.

`controller_input` reports activity for presence and joining. It does not send movement to the game. Replacement lobbies use runtime-owned sampling; the legacy platformer publishes its own authenticated frames. Games consume the same frame format in both modes. See [Build a lobby](/docs/lobbies#input-and-screen-ownership).

## Start opens your menu, Back leaves

Back/Select belongs to GameNight and always returns to the party, even from
inside your pause menu. Start opens and closes your game's own menu with its
settings and the controls. In managed play, leave out anything GameNight
already chose (players, game mode picked in the lobby).

Use press edges for every menu and action button, and require a release after
Start and Resume, so the press that started the game does not also act in it.
Hold-to-confirm (about a second) suits actions that end a round or reset
progress.

## Back must toggle once

Request the lobby with `request_overlay`. Use press/release edges and the shared one-second release gate. The same held press must not reopen the game after focus changes. Never issue Resume or `request_start` from a focus callback.

## Check real devices

Test two different profiles, reversed connection order, unplugging one pad and reconnecting it. Then switch between games. Synthetic frames can check token matching, but they do not prove that a physical controller belongs to the right player on your machine.
