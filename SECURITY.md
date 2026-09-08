# Security scope

This developer preview is a local runtime, not an internet-facing game server.
The daemon listens on loopback by default. Do not expose its control protocol
on an untrusted network: overlay clients are trusted to control the party.
Per-launch game tokens are not authentication for arbitrary remote users.

The character studio is opt-in (`--studio`). It permits local profile edits
and seat claims from devices on a trusted LAN. It has no account login and
must not be deployed as a public web service. The daemon address is configured
by the host, never chosen by an incoming browser request.

Please do not include secrets or personal data in public bug reports. Before
public release, maintainers must configure a private vulnerability-reporting
channel in the repository settings.
