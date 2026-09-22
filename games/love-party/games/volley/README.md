# Volley Trouble

A self-contained LÖVE 11.5 couch volleyball game. No downloaded art, build step,
Lua packages, or physics engine. All graphics and sound are generated locally.

Volley Trouble is a mode in the shared `games/love-party` runner. Launch the
packaged `volley-trouble.love`, or set `GNLOVE_GAME=volley-trouble` and run
`love games/love-party`. GameNight supplies seats and controller IDs; the shared
input mapper preserves ownership even when seats are sparse. Teams alternate
between occupied seats. Court, bomb, target score and rotating rules are exposed
as game settings and apply to the next round. Rounds repeat automatically.

Bots forecast ball trajectories through wall, net and platform bounces, aim
their receptions, time jumps, and divide court coverage with a teammate.

| Player | Move | Jump | Smash |
| --- | --- | --- | --- |
| P1 | A / D | W | Space |
| P2 | Left / Right | Up | Right Ctrl |
| P3 | J / L | I | U |
| P4 | Numpad 4 / 6 | Numpad 8 | Numpad 0 |
| Gamepad | Left stick / D-pad | A | RT, RB, or B |

**Aim with the right stick, then press smash as the ball comes close.** An arrow
shows the shot direction and a small ring shows the cooldown. Right-stick aim
is independent of movement. With no aim input, smash defaults toward the other
court: upward from low positions, downward from above the net. Keyboard players
hold their movement keys to aim while pressing smash; S/Down/K/Numpad 5 aims
down and the jump key aims up. Releasing direction uses the default shot.

Smashes have 80-unit reach, a 0.16-second timing window and a 0.85-second cooldown,
including misses. Release and press again for a new swing. Airborne and close
contacts hit harder. Swings cannot reach through the net or platforms. Automatic
body hits still work without the smash button; the CPU also uses aimed smashes.

Menu: Up/Down selects, Left/Right changes, Enter/A starts. During a match,
Escape/Start pauses; Q/B returns to court selection while paused. Enter/A
replays a finished match. F11 toggles fullscreen; M toggles sound.
Four simultaneous keyboard players can encounter hardware key rollover limits;
gamepads are recommended for four players.

## Rules

Movement reaches 650 units/second with snappier acceleration and braking.
Each lava patch is 100 units wide, leaving most of each court safe to stand on.
**Round Rules → Party Mix** is enabled by default in standalone and GameNight
matches. Each new rally cycles through these rules, with a two-second serve
announcement. Choose **Classic Only** to keep the original rules.

1. Classic volleyball.
2. Double Trouble: two independent balls; the first scoring floor contact ends
   the rally and awards exactly one point. Both balls reset together.
3. Moon Ball: 55% gravity for players and balls.
4. Lava Saves: glowing patches bounce balls upward without scoring. Players
   still burn there; the remaining floor scores normally.
5. Fast & Small: a smaller ball and 15% stronger hits, with a higher speed cap.

The selected arena and optional exploding-ball modifier stay in effect across
rounds. The lava arena also always saves balls on its glowing patches. CPU
players prioritize nearby threats in multiball and predict the active gravity.

Land the ball on the opponent's colored floor. First to seven wins. Unlimited
touches, automatic body contact, and walls that bounce the ball back into play.
Hold jump for height, tap for a hop. Contact angle and movement direct shots.
Rising hits get extra power; a forward contact above the net can spike downward.

- Sunset Beach: the plain court.
- High Tide: one-way platforms for players; solid bounces for the ball.
- Up & Over: moving platforms carry standing players.
- Hot Foot: lava knocks you out for 1.35 seconds, then respawns you. The ball
  scores only on unlit floor; lava saves the ball. Platforms never award points.
- Hot Potato modifier: a 6.5-second fuse, faster hits, and a visible knockback
  blast. The ball reforms overhead after 0.8 seconds. Explosions do not score.

## GameNight

```sh
GAMENIGHT_LIBRARY=examples/volley-shelf.json cargo run -p gamenight-daemon
```

The shelf requires `love` on PATH and launch from the repository root. The
catalog is a source integration, not an automatically downloaded runtime.
The game supports prepare/ready/start, pause/resume, dispose/reprepare,
finished, and Back/Select to request the party. It hides during prewarm and
pause and exits if the daemon disconnects. Occupied party seats retain their
input slots and names, alternate between teams, and AI occupants use bots.
Empty seats do not receive players. No second joining flow runs under GameNight.
Court, exploding ball, rotating round rules, and winning score settings apply
to the next prepared match.

The full player circle uses `skin_color`; `shared.face.drawFace` draws the
transparent face and hat over it. The head anchor stays fixed when artwork
changes. Hats are not cropped. Profile edits apply through `party_updated`.
See the [face API](../../../../docs/faces.md) for centre, radius and mirroring.

## Checks and packaging

Run the shared simulation suite with `GNLOVE_TEST=1 GNLOVE_HEADLESS=1 love games/love-party`.
Volley tests live in `tests/volley`, including AI, rotating rules, sparse seats,
avatar decoding and five-minute bot soaks across all courts. The shared native
protocol tests check prewarming, repeat rounds, pause/resume and disconnect;
`tests/volley/protocol.ps1` also checks live settings and dispose/reprepare.

Build with `python scripts/package-love-party.py --output dist/party` from the
public repository. This produces `volley-trouble.love` alongside the other games.
The simulation remains pure Lua with a fixed 120 Hz step.

Current shared-runner controls: A or LB jumps; X, RB or RT smashes. Matches default to ten points. After a point the losing team bursts and the winners remain controllable through the short celebration. Avatar textures preserve their full studio canvas, including accessory padding.
