# Remembered players

Each desktop installation has one **main player**. The first successful room-code
join or controller QR claim selects that player automatically and remembers the
full profile. Opening a QR link, an invalid code or a failed claim does not count.
Later guests never replace the main player automatically.

On the phone's You page, **Main player on this GameNight** lets a connected or
waiting player select their own profile, or clear it. Clearing also stops that
profile returning automatically, but does not unlink the current controller.
The installation remembers that the setting was cleared; the next guest will
not silently become the main player. Selecting a different main player leaves
previously remembered guests available at the door.

The Join dialog and You page also offer **Remember me on this GameNight** for
guests. Remembering is per installation, separate from saved game preferences
and account sign-in. In the controller QR confirmation, the first-player default
is explained and can be declined by unchecking Remember me.

On host startup, the main profile and remembered guests wait at the pickup door,
with the main profile listed first. A controller must still collect a profile.
Remembering never claims a seat or starts a game automatically. Turning memory
off leaves the current player connected; leaving the room does not change the
memory preference. Main player is a startup preference, not an administrator
role, account login or permission to access another person's account.

Local hosts save the selected profiles, including avatar data and colors, in `gamenight/players.json` under the OS user data directory (`LOCALAPPDATA` on Windows, `XDG_DATA_HOME` or `~/.local/share` elsewhere). `GAMENIGHT_PLAYER_MEMORY` overrides that file for isolated tests. Profile edits update remembered copies. Files are replaced atomically, and a failed write is reported to the phone.

The same file contains an installation secret used for cloud registration. Cloud rooms keep opt-ins in SQLite, keyed by the hash of that secret and the account ID. The host never receives an account login token. Restoring a cloud pickup reads the current account profile. Deleting the account also deletes its remembered-device entries.

Local memory stores `main_profile` and `main_initialized` in the same atomic
file. Cloud installations use `device_main_players`: a null account keeps an
explicitly cleared setting from being claimed automatically. Account deletion
clears this reference. Cloud profile restoration requires the cloud connection;
offline LAN profiles use the local file. Local and cloud profiles are separate.

Endpoints: local `POST /api/profiles/:id/main-player` accepts `{ "enabled": true }`;
cloud `POST /v1/rooms/main-player` also requires `code` and the signed-in account.
Only a currently connected or waiting profile can change its own setting. Status
responses include `main_player` for that caller. This is not a general device
administration API.

Checks:

- `cargo test -p gamenight-local-web --lib`: local persistence, full profile restoration, forgetting, and access while waiting/connected.
- Cloud `cargo test -p gamenight-cloud`: persistence across relay/database reopen, device isolation, unauthorized changes, and forgetting without unlinking.
- `node scripts/test-player-memory.cjs`: mobile Join option, waiting/connected toggle, save failure rollback, and hiding the option after leaving. Uses mocked room endpoints against a local development host.
