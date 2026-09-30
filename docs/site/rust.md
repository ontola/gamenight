# Rust / Bevy

Use `gamenight-sdk` for the WebSocket connection and typed events. The SDK is engine-independent. It does not create windows, pause Bevy systems, draw faces or apply controller state for you.

## Add the SDK

For a project in this workspace, use the workspace dependency. For a separate project, pin a reviewed public repository commit:

```toml
[dependencies]
gamenight-sdk = { git = "https://github.com/ontola/gamenight", rev = "YOUR_REVIEWED_COMMIT" }
tokio = { version = "1", features = ["rt-multi-thread", "macros"] }
```

Replace `YOUR_REVIEWED_COMMIT` with an actual commit hash. Do not treat the placeholder as a published release.

## Receive lifecycle events

This compilable example shows the connection and session transitions. It has no renderer or simulation, so it reports Ready only for its empty sample session. Put your real loading and first-frame work before Ready.

::: source rust crates/gamenight-sdk/examples/docs_lifecycle.rs

Run it from the public repository with `cargo run -p gamenight-sdk --example docs_lifecycle`. Without a host launch it exits through the standalone branch. In a game, that branch starts your normal menu.

## Connect to your game loop

Run the network task separately and pass events into your engine through a channel. Apply Prepare and PartyUpdated to the roster. Store ControllerFrame data with a receipt time, then have your input system look up each seat’s exact controller token.

In Bevy, gate simulation systems on your session state. Do not pause the network task or the systems that receive Resume. Drain messages every frame, including while loading, paused or displaying results. Send Ready after assets and a rendered frame are ready, not immediately after receiving Prepare.

## Controllers and faces

`GameEvent::ControllerFrame` contains `Vec<ControllerState>`. Clear input after 250 ms without a frame, on an empty frame, or when a token disappears. [Controllers & players](/docs/controllers) covers axes, button bits and ownership.

Use `gamenight_protocol::Avatar::parse`, `to_rgba()` and `head_layout()` for artwork. Draw a skin-coloured circle underneath and use the head centre as the texture origin. [Faces & colours](/docs/faces) describes the coordinates.

## Validate the result

```sh
cargo check -p gamenight-sdk --example docs_lifecycle
cargo test -p gamenight-sdk
```

These check the SDK and example. They do not certify your window, audio, controller mapping or renderer. Run the packaged-game [integration checks](/docs/testing) too.
