# Local character studio API

This opt-in API is intended for trusted LAN devices. See [security scope](../SECURITY.md).
The host configures the daemon address; browser input cannot override it.
Profiles and bindings are temporary and disappear when the server stops.

## Profiles and joining

`POST /api/profiles` stores a profile with `id`, `username`, `color` and `avatar`.
`GET /api/profiles/:id` retrieves it, or returns 404.
`POST /api/profiles/:id/join` accepts optional `seat` and `claim` fields.
A seat takes precedence over a player ID. With neither, the host requests a new
party member. Successful fresh joins include the player ID for later updates.

| HTTP status | Meaning |
|---|---|
| 200 | Read the response's `status`: `joined`, `claimed`, `no_such_seat`, or `already_signed_in` |
| 404 | Profile does not exist |
| 502 | Daemon connection or reply stream failed |
| 504 | Daemon did not answer within the deadline |

The server requires Welcome before sending player changes. A fresh join also
requires a party snapshot containing the new player before reporting success.
Connection and reply deadlines are two seconds each, with a six-second overall
request deadline that also bounds socket writes and closing the connection.

A timeout does not roll back commands already delivered to the daemon. A claim
response confirms commands were sent; the protocol does not acknowledge each
individual profile update. Clients should refresh party state before retrying
an ambiguous operation. Concurrent fresh joins still rely on snapshot differences;
request correlation is a future protocol improvement.

### Player session status

`GET /api/profiles/:id/session` reports `linked`, `player_name`, zero-based
`seat`, party `players` count, `current` (title and phase), and `next` title.
A stale binding whose player has left is reported as unlinked. The mobile
Session tab uses this live state instead of showing another sign-in QR.

## Room controls for linked phones

These endpoints act as the party member a profile is bound to, so a phone can
only act as the character it drives. The phone sends its profile ID, never a
player ID. A profile that is not bound to a seated player gets 403.

`GET /api/games?profile=<id>` lists the host's games as `{"games": [...]}`,
each with `id`, `title`, `selectable` and `state` (`available`, `playing`,
`downloading`…). Only selectable games can be queued. Launch details are never
included.

`POST /api/playlist/queue` with `{"profile", "game"}` adds a selectable game to
the end of the queue without starting or interrupting play. It answers with the
same playlist view as `GET /api/playlist`, or 409 when the host cannot play the
game.

`POST /api/playlist/next` with `{"profile", "game", "start"}` makes a
selectable game the next one up, so it starts loading. With `"start": true` it
also ends the current game as soon as the new one has loaded, like the party
choosing Next. It answers with the playlist view, or 409 when the host cannot
play the game.

`GET /api/settings?profile=<id>` returns the match settings of the active or
warm game; add `&game=<id>` to ask for that game, which must be active or warm.
The answer has `game`, `instance` (the session), `revision`, `can_undo` and a
`settings` map of `toggle`, `number` and `choice` controls with their current
`value`. It returns `null` when that game declared none.

`POST /api/settings` with
`{"profile", "command": {"action", "instance", "expected_revision", "values"}}`
sends a [`control_settings`](protocol.md#atomic-settings-batches) batch as the
profile's player. `action` is `set`, `undo` or `keep`. Success returns the
settings afterwards. A stale revision, an invalid value or a session that ended
returns 409 with `{"error": "..."}` naming the daemon's reason.
