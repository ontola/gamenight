# Player store

The host keeps players' own settings and progress in an embedded
[Atomic Data](https://docs.atomicdata.dev) store (the `atomic_lib` crate,
redb on disk), in `crates/gamenight-store`.

- Location: `gamenight/store` in the user data directory (`%LOCALAPPDATA%` on
  Windows, `$XDG_DATA_HOME` or `~/.local/share` elsewhere). Override with
  `GAMENIGHT_STORE`. Test daemons keep everything in memory.
- Each host has its own Atomic agent, a key pair in `agent.secret` next to the
  database, and a private drive. Keep that file private: it signs every change.
- One resource (class `https://gamenight.ontola.io/ns/PlayerGame`) per profile
  and game holds that profile's setting values and saved progress. Changes are
  signed commits, so every record has a history.
- Profiles are the owners the host already uses (`account:<id>` for a signed-in
  player, `local:<id>` for a remembered one). Guests are never stored. Games
  never see the store, the agent or these owners: they get `player_settings`
  and `player_data` for the players in the room, keyed by player id, and a
  per-game `profile_key`.
- Hosts that kept settings in `gamenight/player-settings.json` move them into the
  store on first start and rename the file to `player-settings.json.migrated`.

## On the phone

The app (`mobile/`) has the same store, through `flutter_rust_bridge`:
`mobile/rust` wraps `gamenight-store` and `mobile/rust_builder` (cargokit)
builds it with the APK and the iOS app. It lives in the app's support
directory as `gamenight-store`, with the phone's own agent, and holds this
phone's player's settings per game (owner `me`). `lib/storage/phone_store.dart`
opens it at startup; on first start the settings the phone kept in its
preferences move in. The web app has no store and keeps using browser storage.
After changing `mobile/rust/src/api`, run `flutter_rust_bridge_codegen generate`
in `mobile/`.

Next: syncing phone, host and a hub with Atomic's sync protocol, and progress
for signed-out phones.
