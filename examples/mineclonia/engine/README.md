# Mineclonia controller prototype

Two Windows clients share one local world. Each owns one SDL controller path.
The patch keeps movement and camera input active in both views without grabbing
the shared mouse. The launcher places the views side by side, borderless.
This is not a single-process split-screen renderer or a certified GameNight game.

## Try it

The patched runtime is installed under the prototype root on this development PC.
Connect two controllers and close the old diagnostic clients. Keep the isolated
world server running, then run from `examples/mineclonia`:

```powershell
python probe_controllers.py
python couch.py
```

The first launch requires exactly two recognized controllers. Saved device paths
keep seats stable when SDL enumeration changes. If a path changes after switching
USB ports or transport, use `python couch.py --reassign`. A missing controller
never inherits another player's input. Disconnect releases every held action;
reconnection waits for neutral buttons and sticks. Closing either viewport ends
the pair. The shared world server keeps running.

| Control | In game | In inventory |
| --- | --- | --- |
| Left stick | Move | Move cursor |
| Right stick | Look | Reserved |
| A | Jump | Pick up/place stack |
| B | Sneak | Close |
| X | Sprint/auxiliary | Split/place one item |
| Y | Inventory | Close |
| RT / LT | Dig / place or use | Reserved |
| LB / RB | Previous / next hotbar slot | Reserved |
| D-pad | Up zoom; other directions reserved | Move cursor in steps |
| Start / Back | Local pause menu | Close menu |

These bindings are implemented but have not yet passed a physical playtest.
Start/Back is the local engine menu, not GameNight's lobby toggle.

## Build from source

The patch is LGPL-2.1-or-later, matching Luanti. Keep the source patch and upstream
license with redistributed binaries. It applies to Luanti 5.17.0, commit
`c0e6812b1a4260bb25a1f606f70f55f4962bb97d`. It targets SDL2 on Windows x64.

On Linux/WSL install Git, CMake, a native C++ compiler, Python 3, wget, tar, xz and
unzip. The pinned upstream buildbot downloads the LLVM MinGW toolchain and native
libraries and validates their archive hashes. Allow several GB of build space.

```sh
bash examples/mineclonia/engine/build-windows.sh "$HOME/.cache/gamenight/luanti-couch-new"
```

On Windows, install the generated `build/build/luanti-5.17.0-win64.zip`:

```powershell
python examples/mineclonia/engine/install.py PATH_TO_BUILD_ZIP
```

The installer refuses to overwrite an existing controller-engine directory. The
build manifest records source, patch, archive and executable hashes. The launcher
checks the executable hash; this is local build evidence, not remote certification.

## Real lobby test (Windows prototype)

`lobby_test.py` starts a separate GameNight daemon on port 17942, with the installed
GameNight lobby and only Mineclonia on its temporary shelf. It does not publish a
catalog entry. Use `engine/install.py --name controller-engine-managed` for the
managed build. The adapter starts its own server using that executable and
`GAMENIGHT_CONTROLLER_FRAME=<root>/managed/server.frame`; the world and server.conf
are the same isolated prototype files. Do not start a separate server. Copy the Mineclonia game into that runtime's
`games/mineclonia`, and install the current world mod while the server is stopped.

The adapter receives Prepare/Start/Pause/Resume/Dispose over the real protocol.
Each view reads only its assigned host seat token. Native SDL pad input is disabled
in managed mode. Back belongs to the resident GameNight lobby; Start opens Luanti's
own menu. Both views hide and mute on Pause; the patched world server skips
simulation updates entirely while keeping connections and the local settings
mailbox alive. A dedicated callback polls only that mailbox while paused. Resume reveals both views. Input expires after 250 ms without a
fresh host sample. Lost adapter heartbeats pause and hide views within two seconds.
The first neutral frame after resuming arms controller input again.

The adapter only reports Ready after both clients acknowledge their first world
frame. Closing either view closes the pair; host disconnect cleans up clients.
The adapter owns the server process and asks it to save and shut down on exit.
An unresponsive world invalidates readiness.
Local file frames are a prototype transport, not an external API.

```powershell
python lobby_test.py
```

Join with A on each controller, select Mineclonia at the TV, play, then press Back.
The GameNight lobby should appear. Release Back, wait one second, and press it again
to resume. Start should still open the in-game menu. Check that each physical
controller owns the same seat in the lobby and game.

## Evidence and remaining checks

The Windows release build, package and executable startup pass. The C++ test uses
the actual binding class from the patch and checks isolated seats, wrong-device
rejection, disconnect and changed instance IDs after reconnect. Python tests
check saved seats, missing devices and ambiguous mappings. Run them with:

```sh
c++ -std=c++17 -I LUANTI_SOURCE/irr/include examples/mineclonia/engine/test_binding.cpp -o /tmp/test-binding
/tmp/test-binding
python -m unittest discover -s examples/mineclonia -p 'test_*.py'
```

Physical test still required: move and look with both controllers at once; dig,
jump and place independently; open inventory on one side while the other moves;
pick up, split and place stacks; unplug a moving pad, release it and reconnect;
restart with reversed connection order. Check both viewports and text at display
scaling settings used by players. The user confirmed both controllers worked independently in the standalone two-view
build on 2 October 2026. Three automated real-daemon start/pause/resume cycles also passed, with both
clients connected and a frozen world clock while paused. The user also confirmed
the custom lobby detected both controllers, launched Mineclonia and returned
through Back on 2 October 2026. Reconnect and reversed-order identity checks
remain separate manual checks.

Managed Windows views share their process IDs through `GAMENIGHT_COUCH_GROUP`.
They cover their monitor halves without borders and stay above the taskbar only
while one of those two game windows owns foreground focus. Alt-Tab to another
app releases that position; GameNight's pause hides both views. The updated
binary builds, but taskbar coverage still needs confirmation on the TV.

Known limits: Windows only, two seats, no on-screen keyboard, player 2 audio muted.
There is no automatic pause just because another desktop app gains focus.
GameNight names, skin and face artwork are not yet applied to Mineclonia models.
Two game processes use more GPU and memory than a shared renderer. None of these
limits is represented as a verified store integration capability.
