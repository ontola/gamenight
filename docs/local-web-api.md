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
