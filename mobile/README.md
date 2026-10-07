# GameNight app

A Flutter app for players on the couch. It does what the phone studio in the
browser does, as an installable app for Android and iOS:

- **Room.** Scan the lobby QR (or type the address) to connect to a GameNight
  on your Wi-Fi. Enter the room code and walk your character to your door to
  be picked up, or scan the QR above a character to sign in as that one.
  Shows who you are signed in as, the current game and what is up next, and
  lets you become the main player or be remembered, or hand your character
  back.
- **Game.** The current game's own phone screen, for games that declare one
  (see [Phone screens](../docs/protocol.md#phone-screens)): a hand of cards,
  a private map. It opens by itself when such a game starts, so there is
  nothing to install per game. Hexstead in `ontola/gamenight-games` is the
  example. A game that needs a native phone app instead (like the God game)
  gets an Install / Open card: on Android GameNight downloads the APK from
  the GameNight computer and installs it, like a store. Android asks once to
  allow installs from GameNight and confirms each first install; updates of
  apps GameNight installed go through without asking on Android 12+. On iOS
  the player gets the app from the App Store.
- **You.** Your name, skin colour and the 48×48 face you draw, with the same
  presets, tools and wire format as the web studio. Every change saves by
  itself and follows your character into every integrated game. Keep several
  faces, and copy or restore a backup as text (the web studio's format).
- **Playlist.** Tonight's queue: drag to reorder, remove a game, or play an
  earlier game again.

The app only talks to the local web server on the GameNight PC (port 7913),
over the same HTTP endpoints as `web/studio.js`, plus `/api/companion` for
phone screens. It never touches the daemon's control port. Hosted rooms on
gamenight.ontola.io still open in the browser.

## Run

GameNight must have its phone studio on: start it with
`python scripts/run-local.py --studio`, or set `GAMENIGHT_WEB=1`.

```sh
cd mobile
flutter pub get
flutter run            # on a phone on the same Wi-Fi
flutter test
flutter build apk      # Android
flutter build ipa      # iOS, needs a Mac and signing
```

Android allows plain HTTP for this app (`usesCleartextTraffic`), and iOS
allows local networking (`NSAllowsLocalNetworking`), because the GameNight PC
serves plain HTTP on the LAN.

`flutter build web` also works for quick UI checks. Serve the build from the
same origin as the GameNight web server (or through a proxy): the local web
server sends no CORS headers.

## Not yet

- Phones as plain gamepads for games without a phone screen.
- Signing in to a GameNight account and hosted rooms.
