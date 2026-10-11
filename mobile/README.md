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

The app signs in to gamenight.ontola.io and joins centrally registered rooms.
Email sign-in uses an eight-digit, single-use code tied to the app that requested
it. The email link opens the Android app; pasting the code into the app also
works. Browser and app sessions are separate. A code requested in the browser
cannot sign the app in: request a new code in the app instead.

Browser-requested sign-in links use `/auth/login` and stay in the browser.
App requests include `client: "app"` and receive `/auth/app` links.

Verified Android links cover `/auth/app`, `/join`, `/studio` and the root
room-code URL. Room invitations retain their target while you sign in. The
production proxy must serve `/.well-known/assetlinks.json` with the certificate
fingerprint of the published APK. Flutter's default deep-link routing is disabled
on the Activity because `app_links` handles those URLs.

Optional local-network connections use the phone server on port 7913. The app
never talks directly to the daemon's control port.

## Run

GameNight must have its phone studio on: start it with
`python scripts/run-local.py --studio`, or set `GAMENIGHT_WEB=1`.

```sh
cd mobile
flutter pub get
flutter run            # on a phone on the same Wi-Fi
flutter test
flutter build apk      # Android (CI publishes the signed one, see below)
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

## Download

CI signs every build from `main` with the GameNight key and publishes it as
the `app-latest` release, so this link always has the newest app:

<https://github.com/ontola/gamenight/releases/download/app-latest/gamenight.apk>

The app updates itself from there. CI builds with the workflow's run number
as versionCode and as `GAMENIGHT_BUILD`, and publishes a `version.json` with
that number next to the APK. When a newer build is out, a strip above the
tabs offers it; Android asks the player to confirm, then replaces the app.
The app checks at start and when it comes back after six hours. Local builds
(`GAMENIGHT_BUILD` unset) never offer updates. The first build with this
check has to be installed by hand once.

## Verify Android sign-in and room links

Run `flutter test test/sign_in_navigation_test.dart test/account_test.dart`.
The navigation regression covers entering a room code, signing in by pasted
code or duplicate email-link callbacks, then receiving room polling updates.
The home screen must remain visible and the room must still be joined.

On an Android device with the signed release installed, verify the domain and
open a real sign-in link requested from that same app. Never put real codes in
logs or committed fixtures.

```sh
adb shell pm verify-app-links --re-verify io.ontola.gamenight
adb shell pm get-app-links io.ontola.gamenight
```

Check warm and cold app launches, expired codes, and joining a room after sign-in.
The domain should report `verified`. Existing installs can retain an earlier
failed verification until Android checks again; installing the updated APK also
requests verification. A browser chosen by the user can still override app links.
