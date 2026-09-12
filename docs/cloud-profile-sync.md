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
