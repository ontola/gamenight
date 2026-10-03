# Optional managed profile synchronization

The local editor remains independent. Set `GAMENIGHT_CLOUD_URL` to an HTTPS
GameNight service origin to enable the outbound connector in the local web server.
No inbound Internet port is required. Without this setting, no cloud registration
or polling occurs and the local editor keeps its existing behavior.

The host registers an ephemeral capability and reports occupied seats every three
seconds. A scanned local sign-in URL with a seat or player claim redirects to a
five-minute hosted pairing ticket. The signed-in player confirms the controller
before sharing their profile. Subsequent profile revisions are applied only to
that exact player and local unlink revision. Leaving/replacing a seat or unlinking
invalidates its association. The host never receives account login credentials.

API contract: POST `/v1/lobbies/register` returns a bearer capability; authenticated
POST `/v1/lobbies/poll` takes `{seats:[{index,player,revision}]}` and returns profile
updates for paired accounts; POST `/v1/lobbies/ticket` takes `{index}` and returns
an expiring ticket. Browser pairing uses authenticated CSRF-protected account APIs.
Only profiles are relayed; this does not expose game controls or purchases.

Current alpha limits: connections expire after two minutes without a heartbeat
and after 24 hours total. A cloud restart requires scanning a new QR, but not
creating another account. There is no automatic conflict merge: the editor retains
local unsynced work and rejects stale cloud saves. Cloud gallery data is isolated
per account on the same browser.


## Room codes and physical profile pickup

A cloud-enabled host displays a six-character room code. Signed-in players enter
it in Your player to offer their profile, without taking a controller seat. The
lobby renders pending profiles at doors; an unlinked local player stands at the
matching door for two seconds to accept. Linked players cannot accept. Pending
profiles expire after five minutes and may be cancelled on the phone.

The outbound relay poll now includes `room_code` and `pending` (opaque pickup ID,
profile and expiry). The native lobby reads these from `/api/player-links` under
`room`. It completes a pickup with a POST to
`/api/room-pickup/{pending}/{player}` on the local web server. This endpoint
requires a loopback peer and `X-GameNight-Local-Pickup: 1`; it is deliberately not
a phone API. The local bridge validates the player and unlinked state, then sends
a capability-authenticated `/v1/lobbies/pickup` request with the full seat identity
and link revision. The cloud consumes the pickup atomically; subsequent normal
profile updates apply the account. No account token is delivered to the host.

Codes last for the host session (at most 24 hours, or until its heartbeat expires).
Cloud restart requires a new code. The cloud limits code attempts to five/minute
and thirty/hour per account, twenty/minute per forwarded client IP and 120/minute
globally. It holds at most eight pending profiles per room. Hosted-service IP
limits assume its backend is reachable only through its trusted reverse proxy.
The existing controller-specific QR flow remains available.
