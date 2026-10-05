# Native host services

The installed app does not host web pages. The public `gamenight-host-services`
package connects to the hosted GameNight service and exposes a small native
control API on `127.0.0.1:7913`. It rejects LAN binds and browser-origin requests.

- `GET /api/player-links`: hosted room code, QR, waiting profiles and bindings.
- `POST /api/room-pickup/{pending}/{player}`: controller-owned profile pickup;
  requires `X-GameNight-Local-Pickup: 1`.
- `POST /api/player-links/{player}/unlink`: detach a profile from its controller.
- `GET /api/host/lobby`: installed lobby choices and saved preference.
- `POST /api/host/lobby`: save `{ "id": "registered-lobby" }` for next launch;
  requires `X-GameNight-Host: 1`.
- `POST /api/host/recovery`: native `retry`, `resume` or `quit` command; requires
  `X-GameNight-Host: 1`.

There are no `/studio`, `/docs`, `/onboarding`, `/host/lobby` or static-asset
routes. Phone profile mutations go through the authenticated hosted service;
the host consumes them over its outbound relay. The relay also preserves
profile-to-seat revision checks, full avatar data and acknowledged updates.

Packaged launchers and `scripts/run-local.py` enable `GAMENIGHT_HOST_SERVICES=1`.
The default service is `https://gamenight.ontola.io`. An explicit
`GAMENIGHT_CLOUD_URL` must be an HTTPS origin. `GAMENIGHT_OFFLINE=1` disables
cloud sync while native controls and guest play continue working. Contributors
can run the API separately using `GAMENIGHT_HOST_SERVICES_ADDR`; non-loopback
addresses are rejected.

Local remembered profiles from earlier versions are retained on disk. New
account profile memory is managed by the centralized service. No migration
uploads old local profiles or deletes them.
