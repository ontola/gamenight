# Remembered players

The phone's Join dialog and the You page offer **Remember me on this GameNight**. This is opt-in for each desktop installation. It is separate from saved game preferences and the player's account.

On host startup, remembered profiles wait at the pickup door. A controller must still collect a profile. Remembering never claims a seat or starts a game automatically. Turning memory off leaves the current player connected; leaving the room does not change the memory preference.

Local hosts save the selected profiles, including avatar data and colors, in `gamenight/players.json` under the OS user data directory (`LOCALAPPDATA` on Windows, `XDG_DATA_HOME` or `~/.local/share` elsewhere). `GAMENIGHT_PLAYER_MEMORY` overrides that file for isolated tests. Profile edits update remembered copies. Files are replaced atomically, and a failed write is reported to the phone.

The same file contains an installation secret used for cloud registration. Cloud rooms keep opt-ins in SQLite, keyed by the hash of that secret and the account ID. The host never receives an account login token. Restoring a cloud pickup reads the current account profile. Deleting the account also deletes its remembered-device entries.

Checks:

- `cargo test -p gamenight-local-web --lib`: local persistence, full profile restoration, forgetting, and access while waiting/connected.
- Cloud `cargo test -p gamenight-cloud`: persistence across relay/database reopen, device isolation, unauthorized changes, and forgetting without unlinking.
- `node scripts/test-player-memory.cjs`: mobile Join option, waiting/connected toggle, save failure rollback, and hiding the option after leaving. Uses mocked room endpoints against a local development host.
