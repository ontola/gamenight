# Unreal Engine

The Gamepad Party plugin for Unreal Engine 5 lives in `sdk/unreal/GameNight`. It
covers the whole game contract: the connection and lifecycle, input per seat,
the window and audio, the world pause, match and per-player settings, saved
progress, faces and phone screens. **Dash Derby** in `examples/unreal-demo` is a
complete demo game built on it, and every snippet on this page comes from
that game or the plugin.

The plugin is written for Unreal Engine 5.3 and later on Windows, macOS and
Linux. Its protocol core is plain C++17 and runs in CI on every change; the
Unreal side has no Unreal build in CI yet. See [What is tested](#what-is-tested).

## Add the plugin

Copy `sdk/unreal/GameNight` into your project's `Plugins/` folder, or point
your `.uproject` at the folder that holds it, as the demo does:

::: source json examples/unreal-demo/DashDerby.uproject

Add `"GameNight"` to your module's dependencies in its `.Build.cs`, then set
your game id under **Project Settings > Plugins > Gamepad Party**. It must match
your catalog entry; Gamepad Party also passes it in `GAMENIGHT_GAME_ID`.

::: source ini examples/unreal-demo/Config/DefaultGame.ini "[/Script/GameNight.GameNightSettings]" "[/Script/UnrealEd.ProjectPackagingSettings]"

A game started by hand stays offline, so a test run never joins the party on
your machine. Turn on **Connect Standalone** (or set `GAMENIGHT_ADDR`) to
connect a Play In Editor session to a running Gamepad Party.

## How it fits together

Everything goes through `UGameNightSubsystem`, a game instance subsystem that
lives from boot to quit and ticks also while the game is paused. Get it from
any actor with `UGameNightSubsystem::Get(this)`, or in Blueprint with the
**Gamepad Party Subsystem** node. It talks to Gamepad Party over the plain TCP
transport (one JSON message per line) on the same port as the WebSocket one.

The contract is the same as in every SDK:

1. **OnPrepared**: build the level for `GetSeats()` and `GetPlayers()` while
   hidden, then call `NotifyReady()`. Show nothing yet.
2. **OnStarted**: you are on screen. Start the match at once.
3. **OnPaused** and **OnResumed**: the party went to the lobby and came back.
4. A round ends: call `NotifyFinished()`, show the results, play the next
   round. Rounds repeat until the party picks another game.
5. **OnDisposed**: tear the session down. Another `OnPrepared` may follow.

The plugin takes care of the window and sound on its own: muted and off the
screen while warming, a lower frame cap once ready, borderless fullscreen in
front on Start and Resume, and away again on Pause. It also pauses the world
whenever the session is not running, so physics, timers and game sounds stop
without code from you. Both are settings. F1 returns to the party; the
controller's Back button is Gamepad Party's own and reaches the host directly.
When the host goes away, a launched game quits.

## Bind the lifecycle

Dash Derby connects its handlers in `BeginPlay` and declares its settings, its
phone button and its phone screen once. The plugin declares them again after
every reconnect.

::: source cpp examples/unreal-demo/Source/DashDerby/DashDerbyGameMode.cpp "\tUGameNightSubsystem* GN = GameNight();\n\tif (GN && GN->IsLaunchedByGameNight())" "\t// Standalone: the keyboard"

On prepare, it seats everyone in couch order (left to right as they sit),
opts into live joins and reports ready:

::: source cpp examples/unreal-demo/Source/DashDerby/DashDerbyGameMode.cpp "void ADashDerbyGameMode::HandlePrepared" "void ADashDerbyGameMode::HandleStarted"

::: source cpp examples/unreal-demo/Source/DashDerby/DashDerbyGameMode.cpp "void ADashDerbyGameMode::SeatFromSession" "\tTArray<FString> Seated;"

Seats with an AI occupant get a bot. Empty seats are skipped. The number of
people is `LocalSeatCount()`, never the number of pads you can see.

## Read input per seat

Gamepad Party routes every controller and phone to a seat. Read the seat, never
local device order: `GetPad(Seat)` gives the sticks (deadzone applied, up is
negative Y as on the wire) and buttons, and `JustPressed(Seat, Button)` is
true on the frame a button went down. A button still held from the lobby
must be released first, so one press never does two things.

::: source cpp examples/unreal-demo/Source/DashDerby/DashDerbyGameMode.cpp "\tif (Runner.Seat >= 0)\n\t{" "\telse if (Runner.bKeyboard)"

`ReportActivity` tells Gamepad Party someone is really playing, so the party does
not mark them asleep. `Rumble(Seat, Weak, Strong, Seconds)` vibrates that
seat's controller. Back is never bound: it returns to the party.

## Players, colours and faces

`FGameNightPlayer` carries the name, the clothing `Color`, the `SkinColor`
and the drawn face. Use the colour for the player's body and draw the head
with `DrawFace` on a HUD canvas. It draws the skin circle and the face, or the
default face when the player has none, and mirrors it with `Facing = -1`.

::: source cpp examples/unreal-demo/Source/DashDerby/DashDerbyHUD.cpp "\t// Each player's own face rides above their body." "\t// The only text while playing"

`GetFaceTexture(Player)` gives the face alone as a nearest-filtered texture,
for a material or a widget. Profile changes arrive in `OnPlayersUpdated`
while the match runs: update in place and never restart.

::: source cpp examples/unreal-demo/Source/DashDerby/DashDerbyGameMode.cpp "void ADashDerbyGameMode::HandlePlayersUpdated" "// ---- settings, actions, phones"

With `NotifyParticipation(true)`, players who join or leave mid-round arrive
in `OnRosterChanged`. Dash Derby keeps everyone still seated, with their score,
and adds the newcomers at once.

## Settings and the Start menu

Declare the settings the party may change. Phones, an LLM and your own menu
change the same values; every change arrives in `OnSettingChanged`, also the
ones you make yourself. A setting with `"scope": "player"` is every player's
own choice, here the shape of their body.

::: source cpp examples/unreal-demo/Source/DashDerby/DashDerbyGameMode.cpp "// Declared to GameNight: the phones" "}  // namespace"

Every Gamepad Party Start menu has the same layout: the game's name, **Resume**,
**New round**, then the settings, with no button hints. Dash Derby's menu sends
each change back with `SetSettingJson`, so the phones show the same value:

::: source cpp examples/unreal-demo/Source/DashDerby/DashDerbyGameMode.cpp "\t\tApplySetting(Key, Value);\n\t\t// Tell GameNight" "\treturn true;\n}"

## Rounds, results and saves

A round ends with `NotifyFinished()`; the session goes on. `AddRoomLog` writes
one short line to the room log in the app. Each player's own progress is saved
with their profile between nights, and `UnlockForPresent` gives an unlock to
everyone who was there; `PartyUnion` reads what the people here tonight have.

::: source cpp examples/unreal-demo/Source/DashDerby/DashDerbyGameMode.cpp "void ADashDerbyGameMode::EndRound" "// ---- the frame"

The C++ API takes `gamenight::Json` values (`GN->Core()` is the protocol
client underneath). Blueprints use the `...Json` functions, which take and
return JSON text.

## Phone screens and phone buttons

`DeclareActions` puts buttons such as **New round** on every player's phone;
presses arrive in `OnActionTriggered`. A phone screen is a small web page in
`Content/Phone`, declared with `DeclareCompanionFolder`. The host serves it
from a real folder, so stage it as loose files:

::: source ini examples/unreal-demo/Config/DefaultGame.ini "[/Script/UnrealEd.ProjectPackagingSettings]" "bUseIoStore"

The game decides and the phone draws: Dash Derby sends each player their whole
view, again whenever their phone connects, and checks every tap against the
rules.

::: source cpp examples/unreal-demo/Source/DashDerby/DashDerbyGameMode.cpp "void ADashDerbyGameMode::HandlePhone(" "void ADashDerbyGameMode::SendPhoneViews"

The page itself is plain HTML with the host's `/assets/companion.js`; see
[Phone screens](/docs/phone-screens) for the limits of hosted rooms.

::: source html examples/unreal-demo/Content/Phone/index.html "<script src=\"/assets/companion.js\"></script>" "</body>"

## Build and package

Open `examples/unreal-demo/DashDerby.uproject` with Unreal Engine 5.3 or later
and let it build the modules, or build from the command line:

```sh
# Windows
Engine\Build\BatchFiles\RunUAT.bat BuildCookRun -project=<path>\DashDerby.uproject -platform=Win64 -clientconfig=Shipping -build -cook -stage -pak -archive -archivedirectory=<out>
# macOS
Engine/Build/BatchFiles/RunUAT.sh BuildCookRun -project=<path>/DashDerby.uproject -platform=Mac -clientconfig=Shipping -build -cook -stage -pak -archive -archivedirectory=<out>
```

The demo has no `.umap` and no assets of its own: it builds the arena from
engine shapes in code, so it cooks `/Engine/BasicShapes` and the empty
`/Engine/Maps/Entry` explicitly. Standalone, it plays with the keyboard (WASD,
Space to dash, Escape for the menu) or the first pad against bots; pass
`-players=2` for more local players and `-seed=7` for a repeatable game.

On Windows, Gamepad Party starts games hidden. The plugin keeps a warming game
minimised and muted until Start, and parks the window off the screen when the
window server refuses to minimise it.

## What is tested

- The protocol core (`GameNightCore.cpp`) builds in CI with GCC and Clang
  without exceptions or RTTI, like an Unreal module, and its unit tests cover
  the lifecycle, input edges, stale input, settings, saves, phones, faces and
  performance samples (`scripts/test-unreal-sdk.py`).
- The same core drives a headless game over a real socket, and CI runs the
  Gamepad Party conformance harness against it
  (`gamenight-certify unreal-core`).
- `GameNightProtocol.h` is generated from the protocol schema, so message tags
  cannot drift (`scripts/build-protocol.py --check`).
- Not yet in CI: compiling the Unreal module and the demo, and the window,
  audio and pause behaviour on real hardware. Build the demo and run it under
  Gamepad Party, then follow the [test guide](/docs/testing), before relying on
  them for a release.
