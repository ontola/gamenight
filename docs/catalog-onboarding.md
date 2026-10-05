# From a catalog game to the first lobby

Every game uses the same installer. The hosted website remembers the selected
game in browser storage for seven days. On first launch, the app opens the
hosted `/play#setup=windows` page (or `mac`/`linux`). That page offers the saved
game or a picker if the choice is missing or unavailable for this platform.

The player clicks **Get this game ready**. The website opens
`gamenight://play/GAME_ID`, using the registered OS link handler. The browser
may ask permission. **Just open the lobby** uses `gamenight://lobby`.
There is no localhost website, browser-facing HTTP handoff or local login.

The launcher accepts only lowercase catalog IDs, never paths, commands or
URLs to executable files. The host validates the ID against its own platform
catalog. It persists the choice before queueing and waits for acknowledgement.
The lobby shows download/preparation progress. The player still presses Play;
setup never starts a game or interrupts a running match.

An existing launcher receives requests through its local file inbox. It does
not start another host. Incomplete downloads are selected again after restart.
Installed games mark setup complete. Existing installations without a pending
setup file do not open setup after an update. Reopening the application raises
the lobby and retries it if its automatic restart budget was exhausted.

## Limits and checks

A different default browser or cleared storage requires choosing the game again.
Phones can share the hosted game link with a computer; they cannot configure
that computer silently. The hosted picker needs a network connection. Offline
controller play and locally installed games do not.

`GAMENIGHT_ONBOARDING_FILE` is set by the packaged launcher; development runs
never open a browser unless configured. OS link parsing tests reject unsafe
input. `scripts/test-onboarding.py` exercises the native receiver, saved choices,
restart recovery and the absence of local pages. Internal browser tests cover
the hosted picker, installer links, native handoff links and mobile sharing.
Actual OS permission dialogs and installer registration still need release tests.
