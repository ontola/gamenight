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

## Sync through the cloud's hub

Signed-in players' records follow them between their phone and the hosts
they play on, with Atomic's own sync protocol (`atomic_lib::sync`: version
vectors, Loro merges, so edits made offline on two devices both survive).

- The cloud (`gamenight-internal`, `atomic_hub.rs`) runs the hub at
  `wss://gamenight.ontola.io/atomic/ws`, with its own Atomic store next to
  the cloud database. Every account gets one drive there, owned by the hub's
  agent.
- Devices keep their own key pairs; nobody gets the account's credential.
  The hub lists who may read and write the drive: the account's signed-in
  phones, and a host only while that account holds a seat there.
- A phone registers its agent after signing in (`POST /v1/me/atomic-device`,
  answer: `drive`, `owner` = `account:<id>`, `path`), pulls the drive, moves
  its own `me` records in and syncs after every change and when the app
  opens. Signing out makes it `me` again.
- A host's local web server sends the store's agent (from the daemon's
  `welcome`, overlays only) with each cloud poll as `atomic_agent`; the poll
  answers with `atomic.drives` for the accounts seated there, which reach
  the daemon as `player_store_drives`. The store pulls each new drive, moves
  that profile's local records in, then syncs two seconds after a save and
  every minute. What came in from elsewhere reaches running games as
  `player_settings` / `player_data` (newer revisions only).
- `cargo run -p gamenight-store --example hub_client` tries a store against
  a real hub by hand.

Local profiles (`local:<id>`) and offline hosts never sync; they keep their
records in the host's own drive.
