# Dash Derby: the Gamepad Party demo for Unreal Engine

A small, complete couch game on the [Gamepad Party Unreal plugin](../../sdk/unreal).
Everyone races for orbs, A dashes and knocks others aside, a round lasts 60
seconds, then the results show and the next round starts by itself.

The whole game is two C++ files, `Source/DashDerby/DashDerbyGameMode.cpp` and
`DashDerbyHUD.cpp`, plus a phone page in `Content/Phone`. There is no `.umap` and
no asset of its own: the arena is built in code from engine shapes, so every
change reads as a diff. The [Unreal guide](../../docs/site/unreal.md) walks
through it.

| Gamepad Party feature | Where |
| --- | --- |
| Prepare hidden, ready, start, pause, resume, dispose | `HandlePrepared` and friends |
| Input per seat, bots in AI seats, activity, rumble | `ReadMove`, `Collide` |
| Names, colours and faces, live profile changes | `DashDerbyHUD.cpp`, `HandlePlayersUpdated` |
| Players joining mid-round | `HandleRosterChanged` |
| Match settings, the Start menu, a per-player setting | `SettingsSpec`, `StepMenu`, `ApplyShape` |
| Phone button and phone screen | `ActionsSpec`, `HandlePhone`, `Content/Phone` |
| Saved progress and an unlock for everyone present | `SaveProgress`, `EndRound` |
| Round results and the room log | `EndRound` |

## Run it

Open `DashDerby.uproject` with Unreal Engine 5.3 or later. The plugin comes from
`../../sdk/unreal` (`AdditionalPluginDirectories`), so keep the repository
layout. Standalone it plays with WASD or the first pad (Space or A to dash,
Escape or Start for the menu) against bots. `-players=2` adds a local player,
`-seed=7` makes a run repeatable, and `GAME_TRACE=1` logs what happens.

To play it under Gamepad Party, package it (see the guide) and add the build to
your local shelf, or set **Connect Standalone** in Project Settings > Plugins >
Gamepad Party while a Gamepad Party host runs on the same machine.

Not verified yet: this demo has not been compiled or played in CI. The plugin's
protocol core is tested and certified headless; see the guide for what that
covers.
