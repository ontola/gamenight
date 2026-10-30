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

## Save schemas: typed progress per game

A game can describe what it saves with `save_player_data` in
`save-schema.json` next to `gamenight.json`: a JSON Schema (draft 2020-12)
with one object type in `$defs` whose `properties` are the top-level keys of
the saved data. `gamenight-publish.py schema` (and `store`, when the file is
there) sends it to `PUT /v1/developer/games/<id>/save-schema` and writes the
answer to `save-schema.lock.json` (the ontology and property ids; commit it).

- The hub turns the schema into an Atomic ontology for the game
  (`atomic_lib::schema::json_schema`): one content-addressed Property per
  field, in the hub's schema drive, with a `GameSchema` record listing the
  current fields. Every account drive points to that drive
  (`ns/schemas`), so the store syncs it next to the account, at most every
  ten minutes (`Store::sync_hub`).
- With the schema here, the store keeps each known field as its own typed
  property, which Atomic merges per field; keys the schema does not know,
  values that do not fit the type and whole data that is not an object stay
  in the JSON blob (`ns/data`). Games without a schema keep the blob only.
  Games see no difference: they save and load the same JSON.
- A property's identity is its ontology, shortname and datatype, so a
  renamed or retyped field is a new property. A new version must say what
  became of every field the last one had, or the hub refuses it (HTTP 409):
  `"x-gamenight-lenses": [{"from": "wins", "to": "victories", "op": "rename"}]`
  (any Atomic lens op: `rename`, `wrap`, `head`, `map`, `convert`), or
  `"x-gamenight-dropped": ["wins"]`. A field never comes back under an old
  name with another type. Lenses apply when a record is read: data saved
  under the old field shows under the new one, and a save under the new one
  drops the old value, so a host still on the older build reads the new
  value back through the lens.
- Hexstead is the pilot (`played`, `wins`, `bestPoints`).


## Players' own projects (vibecoded Warp games)

A Warp (Luau) game folder can live in a player's drive, so they make it at
home and play it at a friend's (`gamenight-store/src/projects.rs`).

- A project is a `GameProject` resource (owner, `id` and `title` from its
  `game.toml`) with a `ProjectFile` child per file: path and text. Only the
  text a Warp game is made of is kept (`.luau`, `.lua`, `.wgsl`, `.toml`,
  `.json`, `.md`, `.txt`; 512 KB per file, 4 MB and 400 files per project).
  Files gone from the folder are marked removed (an edit syncs; a destroy
  would not).
- Saving: list folders in `gamenight/projects.json` in the user data
  directory, `[{"dir": "C:/dev/my-game", "profile": "account:<id>"}]`. While
  that profile is seated here (its account drive linked), the host checks the
  folder every two seconds and saves what changed; it syncs two seconds later.
- Playing: for everyone seated here, the host writes their projects out under
  `gamenight/project-cache/<profile>/<id>` and puts them on the shelf
  ("A player's own Warp project"), started as `warp <folder>`. Edits that sync
  in are written out again, so a running project hot reloads. When the
  player leaves, their projects leave the shelf (after the round, if one is
  running).
- The Warp runtime comes from `GAMENIGHT_WARP`, else the `warp` executable of a
  Warp game registered in `local-games.json`. Without one, projects stay off
  the shelf (logged).
- Luau runs in Warp's sandbox (no os, io or network); a host only sees the
  drives of people seated there.
