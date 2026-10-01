# From a catalog game to the first lobby

The desktop installer stays identical for every game. The selected game travels
through the browser on first launch, not through an installer filename or an
account. A catalog query parameter alone cannot pass data into a native app.

1. The catalog remembers a game ID in browser storage for seven days and offers
   the standard installer for a supported platform.
2. A fresh desktop launch creates `onboarding.json` in the GameNight data directory.
   The local web server opens `/play` on the website in the default browser, with
   a random one-time capability, local port and OS in the URL fragment.
3. The website reads the remembered choice. If it is missing or incompatible, it
   offers a game picker. No account is required.
4. A top-level navigation to `http://127.0.0.1:PORT/onboarding#ticket=...&game=...`
   brings the browser back to this computer. The local page posts JSON to
   `/api/onboarding`. This avoids cross-origin fetches from HTTPS to the LAN.
5. The host validates the capability and its local catalog, then sends `QueueNext`
   and waits for an acknowledged snapshot. The chosen game gets download priority.
   The existing lobby Up next display shows actual download/preparation progress.
   Players still press Play when ready. Setup never launches a game on its own.

The receiver accepts only loopback clients and a capability that expires after
20 minutes. It accepts only free, directly downloadable catalog IDs for this OS.
It never accepts an executable path, a download URL or arguments from a website.
Once accepted, only retries of the same choice succeed. Tokens are not stored in
browser history or server query logs. Choosing “Just open the lobby” consumes the
capability without changing the playlist.

The choice is saved before it is queued. Failed handoffs can be retried. An
interrupted first download is selected again on the next launch; once it is
installed, setup is marked complete. Existing installs with a shelf and no
onboarding file do not open a new setup tab after updating.

## Boundaries

- The browser must have the choice saved. A different default browser, private
  browsing or cleared storage leads to the picker instead. A phone can share the
  game's setup URL with the computer; it cannot silently configure that computer.
- An existing app uses the room join flow and Play next. This flow does not yet
  register a `gamenight:` URL handler or launch an already installed app.
- The browser handoff needs the website once. Local gameplay does not depend on
  it. Offline setup can still use the lobby normally.
- `GAMENIGHT_ONBOARDING_FILE` is set by the packaged launcher. Development daemons
  do not launch a browser unless it is explicitly configured.
- Unit tests cover capability expiry, loopback-only claims, retries and waiting
  for QueueNext acknowledgement. Browser tests cover installer selection, mobile
  sharing, missing storage and the loopback redirect. These do not certify OS
  browser prompts, SmartScreen, Gatekeeper or physical controller play.
