# Security scope

This developer preview is a local runtime, not an internet-facing game server.
The daemon listens on loopback by default. Do not expose its control protocol
on an untrusted network: overlay clients are trusted to control the party.
Per-launch game tokens are not authentication for arbitrary remote users.

Player authentication and phone pages are hosted by the GameNight service.
The native host connects outbound over HTTPS; it never serves a local login,
profile editor or browser lobby selector. The native control API binds only to
loopback, rejects browser-origin requests and is not a LAN API. Local processes
remain trusted, as with the game protocol. Use `--offline` to disable cloud sync.

Please do not include secrets or personal data in public bug reports. Report vulnerabilities privately through the repository's Security tab on GitHub.
