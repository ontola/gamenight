# Unity, Unreal and other engines

There is no maintained Unity or Unreal plugin in this repository. Use the open protocol to write an adapter, or [ask for integration help](/developers). Do not assume a game is supported because its engine can open a socket. [Engine support](/docs/engines) lists what a Unity or Unreal adapter must cover.

## Open the connection

Read `GAMENIGHT_ADDR`, `GAMENIGHT_GAME_ID` and `GAMENIGHT_TOKEN` from the environment. Connect over WebSocket or newline-delimited JSON over TCP. The usual address is `127.0.0.1:7912`.

```json
{"type":"hello","role":"game","game":"my-game","token":"THE_LAUNCH_TOKEN"}
```

Use the actual game ID and launch token, then wait for Welcome and check the protocol version. The token is a launch credential, not a value to commit into your game.

## Keep the adapter alive

Receive messages independently of your simulation. On Unity, keep the connection pump running even when `Time.timeScale` is zero. On Unreal, ensure your connection handler still runs while gameplay is paused. Dispatch engine operations to the appropriate game thread.

Handle Prepare, Start, Pause, Resume and Dispose explicitly. Send Ready after preparing the first frame. Window focus is not a Start or Resume command. Use borderless fullscreen to avoid display-mode switches.

## Decode host input

Use the host’s `controller_frame` stream. Match each state to `seats[].controller`, preserve button release edges and neutralise stale frames. The wire representation is defined in the implementation:

::: source rust crates/gamenight-protocol/src/lib.rs "pub struct ControllerState {" "#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]"

Treat player IDs and controller tokens as opaque values. See [Controllers & players](/docs/controllers) for the matching rules and [Faces & colours](/docs/faces) for rendering player artwork.

## Prove the integration

Use the [protocol reference](/docs/protocol) for message fields and the [test guide](/docs/testing) for build-specific evidence. A custom adapter needs the same pause, input, window and cleanup checks as a bundled game.
