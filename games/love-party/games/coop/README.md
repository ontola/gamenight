# GameNight Co-op Arcade

Two original LÖVE 11.5 games inspired by shared falling-block puzzles and
Bubble Trouble/Pang. Procedural graphics and synthesized audio; no downloads
or external Lua dependencies needed. Keyboard and local gamepads supported.

## Play

Double-click **Play Co-op Arcade.cmd** on Windows, or from the repository:

```sh
love games/coop-arcade
love games/coop-arcade --game=bubble-buddies
```

Up/Down chooses a game; Left/Right chooses CPU practice or human players;
Enter/A starts. Stack Together has two players. Bubble Buddies has two or four
players in standalone mode and supports two to four occupied GameNight seats.
Start/Escape pauses; Q/B from pause returns to the menu. F11 toggles fullscreen,
M toggles sound. Choose **two human players** to use a second gamepad instead
of the CPU. The menu reports detected controllers. A disconnected pad pauses
play (or requests the GameNight party); remaining controller slots stay stable.

### Stack Together

Each player places falling pieces in one half of a shared 12x18 board. Only
full-width rows clear. Clear 12 together to win; either half reaching the top
ends the match. Seven-piece bags, rotation with wall kicks, landing ghosts,
soft drop, hard drop, next-piece preview, and a CPU teammate are included.

| Input | Move | Rotate | Soft drop | Hard drop |
| --- | --- | --- | --- | --- |
| P1 keyboard | A/D | W | S | Space |
| P2 keyboard | Left/Right | Up | Down | Enter |
| Controller | D-pad or stick | A | D-pad Down | B |

If GameNight seats the two players in slots 3/4, their keyboard equivalents
are J/L, I rotate, K soft drop, U hard drop; and Numpad 4/6, 8 rotate,
5 soft drop, 0 hard drop. The game displays the occupied slots' controls.

### Bubble Buddies

Fire vertical harpoons. Large bubbles split in two; the smallest disappear.
Survive five waves with six shared hearts and 80 seconds per wave. Clearing a
wave restores one heart. Hits briefly knock a player out, then return them
with temporary invulnerability. Later waves add elevated and moving bounce
ledges. Harpoons pass through ledges. There is no friendly fire.

| Input | Move | Fire (hold for repeated shots) |
| --- | --- | --- |
| P1 keyboard | A/D | Space |
| P2 keyboard | Left/Right | Enter |
| P3 keyboard | J/L | I |
| P4 keyboard | Numpad 4/6 | Numpad 8 |
| Controller | Stick or D-pad | A |

## GameNight

Both games have local catalog entries and entries in `examples/party-shelf.json`.
For a focused source shelf, run the daemon from the repository root with
`GAMENIGHT_LIBRARY=examples/coop-shelf.json` and `love` on PATH.

The shared TCP adapter supports authenticated hello, prepare/ready, start,
pause/resume, dispose/reprepare, finished, Back to the party, and daemon
disconnect. Prewarm/pause hide the window; Start/Resume shows fullscreen.
GameNight supplies occupied seats and drawn profile faces. Both current studio
and legacy avatar formats render with nearest-neighbor sampling. Standalone
play uses default faces. AI seats use CPU teammates; empty seats stay empty.
Profile changes appear on the next prepared match.

These are source integrations in the local development catalog. They are not
published to the hosted store and do not declare fictional download URLs.

## Verification and packaging

```sh
love games/coop-arcade --test
love games/coop-arcade --preview=stack
love games/coop-arcade --preview=bubbles
love games/coop-arcade --preview=menu
python3 games/coop-arcade/package.py
```

Screenshots and test results go to LÖVE's `gamenight-coop-arcade` save directory.
Preview faces are synthetic studio-format test drawings, not user profiles.
Packaging produces `dist/stack-together.love` and `dist/bubble-buddies.love`,
each selecting the correct game by default. LÖVE remains a separate runtime.

Simulation tests cover cooperative row clears, stack settling, seam boundaries,
hard drops, top-out/win, bubble splitting, wave transitions, shared damage,
invulnerability, timers, and CPU play. Physical gamepads need a couch check.
`tests/protocol.ps1 -GameDir PATH -GameId stack-together` (or `bubble-buddies`)
checks native Windows hello, ready, pause/resume, a complete match, reprepare,
and disconnect. Copy the script locally first if Windows blocks PowerShell
scripts on WSL network shares, then pass the original source directory.

Code follows the repository MIT license. The rxi JSON codec preserves its MIT
notice. Avatar decoding, window handling and the Back gate are reused from
Volley Trouble; no third-party game sprites or audio are included.
