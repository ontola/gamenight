# Unity

The Unity package (`sdk/unity`, `com.ontola.gamenight`) handles the
connection, the session lifecycle, every player's controller by seat, names,
colours and faces, match settings, phone buttons, plain-text requests, phone
screens, saved progress, the room log, rumble and the game window. Your game
connects these to its own simulation and rendering.

Orb Rush in [`examples/unity-demo`](https://github.com/ontola/gamepad-party/tree/main/examples/unity-demo)
is the reference game: a small 3D couch game that uses every feature on this
page. The code below is read from it, so it is the code that runs. Copy the
project to start your own game.

## Install

In Unity 2021.3 or later, open **Window → Package Manager → + → Add package
from git URL** and enter:

```text
https://github.com/ontola/gamepad-party.git?path=/sdk/unity
```

Or add it to `Packages/manifest.json`, pinned to a commit or tag:

```json
"com.ontola.gamenight": "https://github.com/ontola/gamepad-party.git?path=/sdk/unity#main"
```

The package is plain C# with no other dependencies. It reads keyboard and pad
input through the Input System when that package is installed and active, and
through the old Input Manager otherwise.

## Player settings

These are the settings every Gamepad Party game needs. Orb Rush applies them from
its build script:

::: source csharp examples/unity-demo/Assets/Editor/BuildOrbRush.cs "        public static void ApplyPlayerSettings()" "        static void Build("

Run in Background matters most. Gamepad Party prepares the next game while
another one is on screen; a Unity player that stops updating when it loses
focus never hears Start. The package also sets it at startup when Gamepad Party
launched the game, but set it in the project too.

## Connect

`GameNight.Client` is the connection. Touch it once, from `Awake`, and the
package creates a hidden `GameNight` object that pumps it every frame before
your scripts run, also while `Time.timeScale` is 0. You never put it in a
scene. Set your catalog id first:

::: source csharp examples/unity-demo/Assets/OrbRush/OrbRushView.cs "            // The catalog id." "            var args ="

The same build runs standalone and under Gamepad Party. Gamepad Party launches it with
`GAMENIGHT=1` and the address in the environment, and
`GameNight.Client.LaunchedByHost` is true: skip your menus and wait for
Prepared. A game you start by hand stays offline, so a test run never joins the
party on your machine. To connect it to a development host anyway, set
`GAMENIGHT_ADDR=127.0.0.1:7912` or call `GameNight.Configure(id, connectStandalone: true)`.

Every event fires on the main thread, inside that pump. When Gamepad Party goes
away, a launched game quits.

## Lifecycle

Subscribe once. The package re-declares your settings, phone buttons, phone
screen and plain-text requests after every reconnect, so declare them in
`Connected`:

::: source csharp examples/unity-demo/Assets/OrbRush/OrbRushGame.cs "        void Wire()" "            gn.SettingChanged += OnSetting;"

Prepared loads the level while hidden and silent, then reports Ready. Start
begins play at once. Pause must freeze gameplay, timers and sound; Resume
continues the same match. Dispose clears the session, and a new Prepared may
follow later in the night, in the same process:

::: source csharp examples/unity-demo/Assets/OrbRush/OrbRushGame.cs "        void OnPrepared(" "        void SeatRunners("

Call `NotifyReady` only when the first frame can be drawn. `NotifyProgress`
is optional: send it when loading takes more than a moment, so the lobby can
show a real bar. `NotifyParticipation` from Prepared opts into live roster
updates; pass `instantJoin: true` only when a running match can take a new
player at once.

`NotifyFinished(session)` reports a round. It changes nothing else: your game
keeps its own results screen and starts the next round itself.

## Controllers

Seats are players. A seat's controller token is opaque; it is not a Unity
joystick index, and the order of pads Unity sees means nothing under
Gamepad Party. `FrameForSeat(seat)` returns that seat's input from the host. It is
neutral while the session is not running and when the input is more than
250 ms old:

::: source csharp examples/unity-demo/Assets/OrbRush/OrbRushGame.cs "        (float x, float y) Read(Runner r)" "        PadInput BotInput("

`Pad` names every button and axis (`Pad.A` to `Pad.Right`). `Pad.Stick` and
`Pad.Trigger` apply the deadzones our games settled on (0.15 and 0.06). On the
wire, up on a stick is negative y; `GameNight.Stick(seat)` gives a `Vector2`
with up positive, as Unity expects. `GameNight.JustPressed(seat, Pad.A)` is
true in the one frame a button went down; read it in `Update`, not
`FixedUpdate`. After Start and Resume, a button still held from the lobby must
be released first, so the press that started the game does not also fire in it.

Back/Select belongs to Gamepad Party: the host pauses you and shows the lobby.
Never bind it. F1 does the same from a keyboard; the package handles it.

`ReportActivity(seat)` on a press or a stick past its deadzone keeps the
player from being marked asleep. It sends at most once a second per pad.
`Rumble(seat, weak, strong, seconds)` vibrates a seat's pad, both strengths 0
to 1; standalone it drives the local pad through the Input System.

Standalone, read your own pads and keyboard. Orb Rush does that in
`OrbRushView.ReadLocal`, and only there.

## The Start menu

Every Gamepad Party game has the same Start menu: the game's name, Resume, New
round (which applies the options), then the settings. No button hints. Play
waits while it is open:

::: source csharp examples/unity-demo/Assets/OrbRush/OrbRushGame.cs "        bool Menu()" "        void CloseMenu()"

A value changed in the menu goes through `SetSetting`, so the phones and the
assistant show the same value.

## Settings

Declare the settings the party may change from their phones or by asking the
assistant. Mark a setting `PerPlayer()` when every player picks their own
value, such as a character; it is saved with their profile between nights:

::: source csharp examples/unity-demo/Assets/OrbRush/OrbRushGame.cs "        public static readonly Setting[] Settings =" "        public static readonly PhoneAction[] Actions ="

Values arrive through `SettingChanged`, and per-player values through
`PlayerSettingsChanged` and `PlayerSetting(playerId, key)`. Apply a value live
when that is safe, or at the next round, and say which in the label:

::: source csharp examples/unity-demo/Assets/OrbRush/OrbRushGame.cs "        public void OnSetting(" "        /// <summary>Plain words from the app"

## Phone buttons and requests in words

Phone buttons sit next to your settings on every player's phone, for things
that happen once. Presses arrive through `ActionTriggered`, only while your
session is the one being played:

::: source csharp examples/unity-demo/Assets/OrbRush/OrbRushGame.cs "        public static readonly PhoneAction[] Actions =" "        public readonly GameNightClient GameNight;"

`DeclareCommands` accepts requests in plain words from the Gamepad Party app and
the session assistant ("8 orbs", "rounds of 90 seconds"). Your game decides
what the words mean and answers once:

::: source csharp examples/unity-demo/Assets/OrbRush/OrbRushGame.cs "        void OnCommand(GameCommand command)" "        // ---- phone screen"

## Names, colours and faces

Every player arrives with a name, a clothing colour, a skin colour and their
own pixel-art face. `GameNightFaces.Head(player, size)` paints the head every
Gamepad Party game draws, as a `Texture2D`, cached per face. Put it on a sprite, a
quad or a `RawImage`; hair may stick out past the circle:

::: source csharp examples/unity-demo/Assets/OrbRush/OrbRushView.cs "            // The player's own face, from their GameNight profile." "            return body;"

`PlayersUpdated` fires when someone picks up a profile in the lobby mid-match:
the same players in the same seats, with a new name, colour or face. Update in
place and keep playing; never restart over it.

Lay out anything that runs left to right, such as split screens or a
scoreboard, in couch order: where the players sit, which they pick in the
lobby. `Couch.Order(seats, players)` sorts seats that way:

::: source csharp examples/unity-demo/Assets/OrbRush/OrbRushGame.cs "        public List<Runner> CouchOrder()" "        // ---- input and the Start menu"

## Players joining and leaving

After `NotifyParticipation`, `RosterChanged` brings the new seats and players
when someone joins or leaves during your session. Keep everyone else's score:

::: source csharp examples/unity-demo/Assets/OrbRush/OrbRushGame.cs "        void OnRoster(" "        /// <summary>Values from the party"

## Saved progress

`SavePlayerData(playerId, data)` stores any JSON value up to 64 KB with a
player's profile: unlocks, stats, a best score. It arrives back through
`PlayerDataChanged` and `PlayerData(playerId)`. `UnlockForPresent(item)` adds
an unlock for everyone here now, and `PartyUnion()` is what anyone here has
unlocked, for tonight only:

::: source csharp examples/unity-demo/Assets/OrbRush/OrbRushGame.cs "        void EndRound()" "        public List<Runner> Ranking()"

`AddRoomLog(text)` adds a line to the room log players read back in the
Gamepad Party app, never on the TV. Use it for a round or a winner, not every frame.

## Phone screens

A phone screen is a small web page every player gets on their phone. Keep it
under `Assets/StreamingAssets`, which stays a real folder in a desktop build,
and declare it from `Connected` with `GameNight.DeclarePhoneScreen("phone")`.
The package checks the folder fits a hosted room. Orb Rush's page is
[`StreamingAssets/phone/index.html`](https://github.com/ontola/gamepad-party/blob/main/examples/unity-demo/Assets/StreamingAssets/phone/index.html):
your score and a boost button. Messages from a phone are untrusted input:

::: source csharp examples/unity-demo/Assets/OrbRush/OrbRushGame.cs "        void OnPhoneMessage(" "        // ---- standalone"

See [Phone screens](/docs/phone-screens) for the page side.

## The screen

`GameNightScreen` comes with the package and needs no code. When Gamepad Party
launched the game it mutes and minimises the window at startup, drops to 10
frames a second once you report Ready, takes the screen in borderless
fullscreen with sound on at Start and Resume, and gets out of the way on Pause
and Dispose. Window focus never starts or resumes a game; only the host does.
Set `Automatic` to false to call `GoQuiet`, `Settle` and `TakeTheScreen`
yourself.

On Windows it minimises without taking focus and parks a warming window off
screen; on macOS it hides the app. On Linux there is no portable way to hide a
window, so it only mutes and throttles. Unity creates its window before any
script runs, so a warming game may show for a moment at launch; starting
windowed and without a splash screen keeps that short.

## Test without Unity

The SDK core and Orb Rush's rules are plain C#, kept apart from the Unity
view. CI builds them into a console game with dotnet and plays every feature
on this page against a fake Gamepad Party host, then compiles the Unity layer and
the view against Unity's reference assemblies:

```sh
python3 scripts/test-unity-sdk.py
dotnet build "sdk/unity/Tests~/Harness" -c Release -o /tmp/orb-rush
cargo run -p gamenight-certify -- unity-demo -- /tmp/orb-rush/orb-rush-headless
```

Keep your own game split the same way and you can test it like this too. These
checks do not run a Unity build: window handling, faces on screen and real
pads need a test on hardware. Build the demo with **Gamepad Party → Build Orb
Rush** in the editor, then run the [integration checks](/docs/testing) on the
build.

After changing a file in `sdk/unity`, run `python3 scripts/unity-package-meta.py`:
a package installed from git needs a `.meta` file next to every file, and CI
checks they are there.
