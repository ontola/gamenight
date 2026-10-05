# Your first game on GameNight

Start with a playable local multiplayer game. Keep it in your own repository.
You can integrate and test locally without an account, store listing or cloud
service. Publishing through the GameNight store comes later.

## Install the development host

Install Git, Python 3.11 or newer, stable Rust and Godot 4.5.2 for the reference
lobby. Use native Windows tools for Windows controller testing, not WSL.
See [development setup](../development.md) for platform build dependencies.

```sh
git clone https://github.com/ontola/gamenight.git
cd gamenight
```

Your game can use another engine. Godot here runs the reference lobby, not your
game. [Choose your engine adapter](/docs#pick-your-engine), then implement
[Prepare, Start, Pause, Resume and Dispose](/docs/lifecycle).

Keep the host connection alive while paused. Prepare a frame before reporting
Ready, consume host controller frames, and show the game only on Start or Resume.
The host supplies the game ID and launch token; do not invent credentials.

## Add your local build

Export your game with all its assets. Create `my-game.json` in the GameNight
checkout with this Windows example, replacing the paths and player limits:

```json
[
  {
    "id": "my-game",
    "title": "My Game",
    "players": "2–4",
    "min_players": 2,
    "max_players": 4,
    "launch": {
      "command": "C:/dev/my-game/build/MyGame.exe",
      "args": [],
      "cwd": "C:/dev/my-game/build"
    }
  }
]
```

This is a **local shelf**, not a store catalog manifest. `command` is an
executable, not a shell command. Put arguments in `args`; use absolute paths
and an existing working directory. On macOS, point at the executable inside
the app bundle, for example `/Users/me/dev/MyGame.app/Contents/MacOS/MyGame`.
On Linux, use an executable such as `/home/me/dev/my-game/build/my-game`.

For an unexported Godot project, set `command` to your Godot executable and
`args` to `["--path", "C:/dev/my-game"]`. For LÖVE, use the LÖVE executable
with the absolute path to your `.love` package as its single argument.
Use the same game ID in the integration and this shelf.

## Play through the lobby

From the GameNight checkout:

```sh
python scripts/run-local.py --lobby godot --godot godot --shelf my-game.json
```

Replace the last `godot` with the executable's full path if it is not on PATH.
The first run builds the host. Connect your controllers, choose your game in
the lobby, queue it and select **Start game**. The game should appear with
the same players. Back/Select should return to the lobby; Resume should
continue the same game state.

The Godot lobby also enables the local phone interface on port 7913. Use the
room QR to test a profile change, then check the name, skin colour and drawn
face in your game. Phone access needs the same LAN and a firewall rule allowing
the local web port. Camera scanning may require HTTPS; entering the room code
or scanning with the phone's camera app is an alternative.

Stop this development host with Ctrl+C before starting another copy. Re-export
your game, then rerun the command with `--skip-build` to reuse the host binaries.
Logs are in `.local/gamenight.log`. If a host already uses port 7912, stop it or
choose another protocol port with `--port`; the phone web port remains separate.

## Verify the exported package

Follow [Test your own game](/docs/testing#test-your-own-game) for a protocol
smoke test and the manual controller/window checks. Test an extracted copy of
the release ZIP, not just your editor project. Repeat on each supported OS.

Add [faces](/docs/faces) and [settings](/docs/settings) through their shared
contracts. Settings declarations let the lobby, phone and optional assistant
discover your options; your game must apply them. Say when each option takes effect.

## Publish the first release

1. [Contact GameNight](/developers) if you want help, or sign in and create a
   draft in the [release workspace](/developers/releases).
2. In [publishing](/developers/publishing), choose **Set up** for that draft.
   Upload your platform package and choose **Use as preview**. Registration and
   private previews do not require distribution approval.
3. Download and play that preview using the [publishing guide](/docs/publishing#other-ci-systems-and-local-previews).
   Supply the exact version, platform, checksum, controls and a review-accessible
   HTTPS build link in the release submission. Submit it for staff review.
4. Send your artwork and test evidence as described in
   [the release handoff](/docs/publishing#first-release-review). After distribution
   approval, promote the tested build with **Publish to gamers**.

The preview download is private. A URL alone does not give staff access to an
owner-only artifact. Arrange build access in the private conversation; never
send your publishing API key. The release workspace and preview workspace do
not yet copy build details or attachments between each other automatically.

## Ship the next version

Upload new bytes under a new version, test a preview, then promote it. Once
distribution is approved, routine updates can use a publish-scoped CI key;
they do not require an operator to deploy the website. Certification is separate
and does not carry over to changed packages. To roll back, promote an older
ready build for the affected platform. See [publishing](/docs/publishing) for
CI setup, update activation and access limits.

## If something fails

| Symptom | First check |
| --- | --- |
| Game stays on Preparing | Process logs, exact game ID, launch token, and whether Prepare reaches Ready without user input |
| Game steals focus while queued | Hide and silence it at engine startup; wait for Start |
| Controller moves the wrong player | Match the seat's opaque controller token, not the engine's joystick index |
| Resume does nothing | Keep the network pump running while simulation is paused |
| Artwork is offset | Draw around the documented head centre and radius, with skin under the transparent artwork |
| Publishing is refused | Check distribution approval, key scope and expiry, package state and platform runtime |

For help, include the OS, host revision, game version, package checksum, exact
command and relevant logs. Remove launch tokens, API keys and private profile
data before sharing logs.
