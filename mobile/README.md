# GameNight app

A Flutter app for players on the couch. It does what the phone studio in the
browser does, as an installable app for Android and iOS:

- **Room.** Join by QR or room code. Once connected, Game opens the current
  game's phone screen and settings, Playlist shows the shared queue, and Room
  contains your room identity and device preferences. The same room connection
  drives all three views. You can reorder and remove queued games in local and
  hosted rooms.
- **Games.** Browse the catalog and choose games for your room. Swipe left or right on a game page to move through the same list, or use the arrows. A gallery with multiple images or videos keeps its own swipe controls.
- **You.** Edit your name, skin colour and 48×48 face. Changes save automatically.

GameNight branding and Feedback remain in the top bar across these tabs.
Phone games open under Room automatically. Hosted rooms discover their private
phone screen through authenticated `GET /v1/rooms/companion`; the returned
same-origin URL is scoped to the player's seat and session. Local connections
continue to use `/api/companion`. Signing out or leaving clears the phone screen.
The cloud and desktop host must both support hosted companions for this flow.

Games can also declare a native phone app. On Android the app offers installation
from the game's download; on iOS it links to the App Store.

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

The web app can also run in Safari and be added to the iPhone home screen.
Build it for the hosted `/app/` path:

```sh
flutter build web --release --base-href /app/ --pwa-strategy none --no-web-resources-cdn
```

Serve `build/web` at `/app/` on the same HTTPS origin as the GameNight cloud API.
Browser sign-in uses the site's secure cookies and CSRF protection; native apps
continue to use bearer tokens. A separate static origin cannot authenticate or
open private phone controls. Enter the emailed code in the web app, or return
to it after following the sign-in link. There is no service worker cache, so a
reload fetches the current app. This web build does not produce a signed iOS IPA.

Phone controls have a full-screen button. It hides the app navigation without
reloading the game's phone page; the exit button or Back restores navigation.
Catalog game pages support sideways swipes without an extra counter bar.

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

## Feedback and automatic error reports

The Feedback button is available from every main tab, even before sign-in.
Tap the microphone, speak, review or edit the transcript, then send. Choose
GameNight or the current game. Explicit game feedback appears in that game's
owner-only developer inbox. GameNight staff can review both feedback and app
errors in the central private inbox.

Recording shows microphone activity and live text. Startup, silence and final-result timeouts prevent a stalled speech service from leaving the button stuck. Empty results, permissions, network and language failures show a message beside the recording controls; diagnostic codes go through the same error-reporting outbox without dictated text or audio.

Speech uses the phone's speech recognition service, which may process audio
online. GameNight stores the submitted text, not the recording. Microphone access
is requested only when recording starts. Keyboard input also works; interrupted
recordings and drafts remain editable. The operating system can stop recognition
on silence, so players can continue recording into the same draft.

Reports carry a unique retry ID, app build, platform, current tab and game ID
when available. Automatic reports include Flutter framework errors, uncaught
Dart errors, and handled cloud/local HTTP 5xx and connection failures. Exception
messages are excluded because they can contain profile data or sign-in links;
stack traces are redacted. Credentials, room codes and HTTP bodies are excluded.
A recent error can be linked to feedback for staff investigation. Developers do
not receive general app errors, account details or private linked error traces.
Native OS crashes and errors inside external games are not captured by these
Flutter handlers.

The app persists a bounded outbox before sending to `POST /v1/reports` on the
central service. Offline reports retry on app startup, resume and every minute.
The server must return the same ID before the client removes an item. Error
bursts are deduplicated locally; unsent player feedback is never evicted to make
room for automatic errors. The service implementation and staff/developer inbox
are in the internal repository.

Validate with `flutter test test/reports_test.dart test/voice_feedback_test.dart test/feedback_screen_test.dart`. Real microphone recognition still needs a phone
check, including denied permission, backgrounding, network loss and Dutch/English
speech. CI builds do not substitute for that check.

Game pages respect the system navigation inset, including three-button Android
navigation. The Share button opens the phone share sheet with the canonical
`https://gamenight.ontola.io/games/<id>` page, not a local-room URL. If sharing is
unavailable, it shows a selectable link and a copy action.

Room invitations survive sign-in: scanned QR/typed room destinations are kept
for ten minutes. Browser email requests carry an allowlisted `return_to` such as
`/app/?room=ABC234` (or a seat's `pair` ticket), so the magic link returns to the
player app even in a new tab. The app rejoins after validating the browser cookie
and opens the room's current phone game when the player's seat is connected.
Failed joins remain visible with retry; expired invitations require a fresh scan.
Native email links keep the app's saved invitation and resume it after sign-in.
