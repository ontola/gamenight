# GameNight app

A Flutter app for players on the couch. It does what the phone studio in the
browser does, as an installable app for Android and iOS:

- **Room.** Join by QR or room code. Once connected, Game opens the current
  game's phone screen and settings, Playlist shows the shared queue, and Room
  contains your room identity and device preferences. The same room connection
  drives all three views. You can reorder and remove queued games in local and
  hosted rooms.
- **Games.** Browse the catalog and choose games for your room. Swipe left or right on a game page to move through the same list, A gallery with multiple images or videos keeps its own swipe controls.
- **You.** Edit your name, skin colour and 48×48 face. Changes save automatically.

GameNight branding and Feedback remain in the top bar across these tabs.
Phone games open under Room automatically. Hosted rooms discover their private
phone screen through authenticated `GET /v1/rooms/companion`; the returned
same-origin URL is scoped to the player's seat and session. Local connections
continue to use `/api/companion`. Signing out or leaving clears the phone screen.
The cloud and desktop host must both support hosted companions for this flow.

Games can also declare a native phone app. On Android the app offers installation
from the game's download; on iOS it links to the App Store.

The app joins centrally registered rooms as a guest by default. No email or
installation is needed: the hosted website provides the same private phone
screens. Signing in is optional, from **You → Save your player**.
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

For hosted rooms, start the GameNight lobby with its cloud connection enabled.
The optional LAN fallback needs `python scripts/run-local.py --studio` or
`GAMENIGHT_WEB=1`; it is not required for website/app guest play.

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

## Guest room flow

A QR for one player binds that exact available seat immediately. A room QR or
code automatically binds the only free seat, or offers a player picker when
several are available. No sign-in page appears in this flow. The current game's
phone screen opens after binding. Occupied/stale seats are rejected, and an
expired room connection asks for a fresh scan, never an email login.

`POST /v1/rooms/guest` accepts a room `code` or seat `ticket`, plus the local
`profile` (`display_name`, `skin_color`, compact `avatar`). Its separate room
token is saved locally and sent as `X-GameNight-Room-Token` only to guest-aware
room endpoints. It is never an account bearer token or part of an invitation URL.
Room status includes available `seats`; `/guest/seat` claims one exact seat.
Guests can use their private phone game and the shared queue. Cloud profile
saving, main-player ownership and account/assistant controls remain account-only.
Guest face edits stay on this phone until a later join or optional profile save.

Optional sign-in calls `/v1/rooms/guest/upgrade` with both credentials, preserving
the player/controller while revoking the guest capability. Leaving revokes the
guest credential; a reload restores a still-active guest room without an account.
Run `flutter test test/guest_room_test.dart test/sign_in_navigation_test.dart`
for guest joining, choosing a seat, reload, expiry and optional profile sign-in.

## Browser navigation

The web app records tabs, detail pages, dialogs and phone fullscreen mode in
browser history. Back and Forward restore the UI without reconnecting the room
or recreating its phone iframe. Back closes fullscreen or a dialog first. A
normal detail page is rebuilt from its retained builder on Forward; a disposed
dialog or an unknown detail ID after a reload falls back safely to the known
tab. Native Android keeps its existing Navigator and fullscreen Back handling.

History contains only UI destinations and local numeric route IDs. The initial
room/email invitation is captured once and removed from the address; room
credentials and private companion URLs never enter browser history.

Run `flutter test test/browser_history_test.dart test/companion_fullscreen_test.dart`
for route restoration and native Back coverage. After
`flutter build web --release --base-href /app/`, run
`node test/browser/navigation.cjs` with Playwright installed for actual browser
Back/Forward, unchanged iframe identity, and one guest join across navigation.
These browser checks use synthetic room/catalog responses, not a physical TV.
Set `GAMENIGHT_TEST_SCREENSHOTS` for phone and desktop captures.
## Default player interface and larger screens

Flutter is the shared player UI on Android, iOS and web (`/app/`). Public game
pages, documentation and downloads remain indexable website content. Developer
and admin workspaces are still website pages; the app Menu links to the developer
portal, docs and hosting instructions. Those workspaces have not been ported.

The hosted service forwards legacy `/join`, `/studio` and QR invitations into
Flutter. Room/pair and requested-game intent survive the handoff. An existing
website guest room is imported from same-origin session storage before startup,
without creating another player or putting a room capability in the URL. A saved
account uses the same-origin HttpOnly session. Sign-in and installation remain
optional. A requested catalog game opens after joining; adding it to the queue
still requires the player's action.

Below 900 logical pixels, the app uses bottom navigation. Larger windows have a
side navigation rail, a catalog with up to six columns, bounded forms, and a
split profile editor. Game detail pages have previous/next buttons and Left/Right
keyboard shortcuts on desktop; browser Back/Forward keeps its normal behavior.
Resizing and fullscreen preserve the embedded game frame and private connection.

Run `flutter test --no-pub`, then build web and run
`node test/browser/navigation.cjs` with Playwright available through `NODE_PATH`.
The browser test uses synthetic rooms, checks navigation and resizing on the
compiled app, and writes phone/desktop screenshots when
`GAMENIGHT_TEST_SCREENSHOTS` is set. Native desktop packaging is not added by this
change; desktop users use the web app.
