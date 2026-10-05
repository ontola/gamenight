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

Account profile memory is owned by the hosted service. The host keeps its
installation identity in `gamenight/players.json` under the OS user data directory
(`LOCALAPPDATA` on Windows, `XDG_DATA_HOME` or `~/.local/share` elsewhere).
`GAMENIGHT_PLAYER_MEMORY` overrides that file for isolated tests. The device
identity allows the service to restore remembered profiles at the door.

Older local profile files remain on disk and can still provide offline pending
profiles. They are not uploaded automatically. New phone joins, memory toggles
and main-player choices use the hosted authenticated APIs. The public host has
no phone-facing profile mutation endpoints or local editor.
