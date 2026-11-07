# Gamepad Party for Bevy

`gamenight-bevy` is a Bevy 0.20 plugin for games that join a party on Gamepad Party:
lifecycle, per-seat controllers, window and audio ownership, settings, phone
buttons and screens, faces, saves and performance reports. `demo/` is Star
Catch, a small party game that uses all of it.

The guide is the canonical documentation: [Bevy](https://gamenight.ontola.io/docs/bevy)
(source: [`docs/site/bevy.md`](../../docs/site/bevy.md)).

```sh
cargo run -p bevy-demo -- --bots 3   # standalone, keyboard and gamepads
xvfb-run -a cargo test --workspace   # plugin tests and the conformance harness
```

This folder is its own Cargo workspace, so the main workspace does not build
Bevy. It uses the SDK and protocol crates from `crates/` by path.
