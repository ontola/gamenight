# Handoff: pushmelding "Je bent in de room" voor de GameNight-app

## Implementatie (21 oktober 2026)

De cloud heeft nu accountgebonden `POST` en `DELETE /v1/me/push-token` routes.
DELETE ontvangt `{token}` en verwijdert alleen deze telefoon, niet alle apparaten
van het account. Maximaal vijf tokens blijven bewaard. Alleen succesvolle
`/v1/lobbies/pickup` verstuurt; FCM draait buiten de broker-lock met een timeout.
Het productiepad wordt via Compose read-only in de container gemount. Omdat de
container als UID 10001 draait moet het JSON-bestand eigenaar `10001:10001` en
modus `600` hebben. Zonder configuratie blijft push uit.

De app gebruikt `firebase_core` en `firebase_messaging`. CI schrijft de configuratie
met `mobile/tool/configure_push.py` en zet `GAMENIGHT_PUSH=true` alleen als het
platformsecret aanwezig is. Lokale builds gebruiken dezelfde configuratiestap en
`--dart-define=GAMENIGHT_PUSH=true`. Zonder secrets bouwt de app zonder initialisatie
of push-entitlements. Firebase Analytics wordt niet toegevoegd. Tokenregistratie
vraagt pas na accountherstel/inloggen toestemming; logout verwijdert alleen het
eigen token en trekt het ook bij FCM in. De cloud blijft HTTP v1-registratietokens
gebruiken; de nieuwe FID-API van Firebase Messaging 17 wordt nog niet gebruikt.

Bij iOS genereert configuratie `Flutter/Firebase.xcconfig`; Runner gebruikt
`Runner.entitlements` met production voor TestFlight en development voor Debug.
`testflight.py` activeert voor geconfigureerde push-builds de bundle-capability via
de bestaande App Store Connect API en controleert het nieuwe profiel op
`aps-environment=production`. APNs-sleutelregistratie bij Firebase blijft een
aparte vereiste. Een tik kiest Room en haalt de actuele, geauthenticeerde room op;
de code uit een melding is nooit een toegangsbewijs.

Firebase-project: `gamenight-a2dd3` (Ontola), apps `io.ontola.gamenight` voor beide
platforms. De twee platformconfiguraties staan in de bedoelde Actions-secrets.
Privésleutels horen uitsluitend in de beveiligde lokale opslag, Firebase en de
productieserver. De serviceaccountsleutel is op 21 oktober geïnstalleerd op
`gamenight-web`; de cloud kan het bestand als UID 10001 lezen en de publieke
healthcheck is groen. Google OAuth gaf HTTP 200. Een FCM `validate_only`-request
met een bewust ongeldig testtoken gaf de verwachte `INVALID_ARGUMENT`; dit
controleert authenticatie en API-bereikbaarheid, niet aflevering.

Firebase heeft de productie-APNs-sleutel `GameNight Push`, beperkt tot topic
`io.ontola.gamenight`. Deze ondersteunt TestFlight en App Store-builds; er is
geen development-APNs-sleutel ingesteld voor lokale Debug-builds. De volledige
mobiele workflow voor commit `aaa6c317` en build 86 is geslaagd, inclusief
TestFlight-upload en Play. App Store Connect toont build 86 als verwerkt en
gekoppeld aan de interne groep GameNight. Op het moment van configuratie waren er nog geen
push-tokens geregistreerd. Open de nieuwe app en sta meldingen toe om een
telefoon te registreren.

De echte notificatie- en taptest op iPhone en Android moet nog
uitgevoerd worden; de gesimuleerde app-tests bewijzen geen aflevering op hardware.

## Oorspronkelijke overdracht

Het onderstaande plan beschrijft de situatie vóór bovenstaande implementatie.

## Doel

Joep is ingelogd op zijn telefoon en is de main player op de GameNight-PC. Hij pakt zijn controller, loopt met zijn character naar zijn deur in de Game Room-lobby en pakt zijn profiel op, zonder een QR-code te scannen. Op dat moment moet zijn telefoon een pushmelding krijgen ("Je bent in de room" of "Joined Room ABC234"). Tikt hij erop, dan opent de app en staat hij meteen in die room, ingelogd en gekoppeld.

## Wat er al is (niet aanpassen tenzij het faalt)

- **App opent in de room** (`ontola/gamenight` commit 5db33aa, map `mobile/`). `AppState.findHostedRoom()` in `mobile/lib/app_state.dart` vraagt `GET /v1/rooms/status` op bij het starten (`loadAccount`), bij terugkomen naar de voorgrond (`didChangeAppLifecycleState` in `mobile/lib/main.dart`) en elke 10 seconden zolang de app open is. Is het account gekoppeld (`status: connected`) of wacht het bij de deur (`status: waiting`), dan gaat de app de room in. Een tik op de melding opent de app, en dan regelt deze code het inloggen al. De melding hoeft dus alleen de app te openen.
- **Waar de koppeling ontstaat** (privérepo `ontola/gamenight-internal`, crate `crates/gamenight-cloud`):
  - `pickup()` in `src/relay.rs`, rond de regel `room.bindings.insert(input.seat.index, pending.account);`. Dit is het oppakken aan de deur: de GameNight-PC stuurt `POST /v1/lobbies/pickup`. **Hier moet de melding verstuurd worden.**
  - De andere twee plekken waar `bindings.insert` staat (pairing claim in `relay.rs`, en `bind()` in `src/room_guests.rs`) komen van de telefoon zelf. Daar is de app al open, dus geen melding.
- **Accounts en opslag**: SQLite via `Store` in `src/lib.rs` (tabellen met `CREATE TABLE IF NOT EXISTS` in `Store::open`). Account-id uit een request via `account_id(&r, &headers)` in `relay.rs`.
- **Cloudconfig**: productie leest `/opt/gamenight-cloud/.env` (zoals `GAMENIGHT_AI_API_KEY`). Een push naar `main` van `gamenight-internal` deployt automatisch naar productie; zie `deploy/cloud/HOSTED.md`.
- **App-ids**: Android `applicationId` en iOS bundle ID zijn allebei `io.ontola.gamenight`. iOS-builds gaan via `.github/workflows/mobile.yml` (job `ios`) en `mobile/ios/testflight.py` naar TestFlight; zie `docs/handoff/ios-testflight.md`.
- De app heeft nog **geen** pushmeldingen: geen Firebase, geen `firebase_messaging`, geen entitlements.

## Aanpak

Gebruik Firebase Cloud Messaging (FCM) voor beide platforms. Upload de APNs-sleutel in Firebase, dan levert FCM ook op iOS af en hoeft de cloud maar één API te praten (FCM HTTP v1).

## Taken

### 1. Accounts (handmatig, door Joep of met zijn login)

1. **Firebase-project**: console.firebase.google.com → Add project `GameNight` (Analytics mag uit).
2. **Android-app** toevoegen met package name `io.ontola.gamenight`. Download `google-services.json`.
3. **iOS-app** toevoegen met bundle ID `io.ontola.gamenight`. Download `GoogleService-Info.plist`.
4. **APNs-sleutel**: developer.apple.com → Certificates, Identifiers & Profiles → Keys → + → naam `GameNight Push`, vink **Apple Push Notifications service (APNs)** aan. Download de `.p8` (kan maar één keer), noteer Key ID en Team ID.
5. Upload die `.p8` in Firebase: Project settings → Cloud Messaging → Apple app configuration → APNs Authentication Key (Key ID en Team ID invullen).
6. **Push-capability op de bundle ID**: developer.apple.com → Identifiers → `io.ontola.gamenight` → vink **Push Notifications** aan en sla op.
7. **Service account voor de cloud**: Firebase → Project settings → Service accounts → Generate new private key. Dit JSON-bestand is geheim.

### 2. Secrets zetten (nooit committen of in chat plakken)

- In `ontola/gamenight` (Actions-secrets), base64 zodat CI ze terug kan schrijven:
  ```sh
  gh secret set GOOGLE_SERVICES_JSON -R ontola/gamenight --body "$(base64 -w0 google-services.json)"
  gh secret set GOOGLE_SERVICE_INFO_PLIST -R ontola/gamenight --body "$(base64 -w0 GoogleService-Info.plist)"
  ```
- Op de productieserver (`gamenight-web`), in `/opt/gamenight-cloud/.env`:
  `GAMENIGHT_FCM_SERVICE_ACCOUNT=/opt/gamenight-cloud/fcm-service-account.json`, en zet dat JSON-bestand daar neer met `chmod 600`. Herstart de cloudservice zoals `deploy/cloud/HOSTED.md` beschrijft.

### 3. App (`ontola/gamenight`, map `mobile/`)

1. Voeg `firebase_core` en `firebase_messaging` toe aan `mobile/pubspec.yaml`. Flutter-versie in CI: 3.47.6.
2. Android: Google Services-plugin in de Gradle-bestanden; `mobile/android/app/google-services.json` wordt in CI uit `GOOGLE_SERVICES_JSON` geschreven en staat in `.gitignore`. Vraag op Android 13+ `POST_NOTIFICATIONS` toestemming.
3. iOS: `Runner.entitlements` met `aps-environment` = `production` (TestFlight), gekoppeld in het Runner-target; `GoogleService-Info.plist` in CI uit het secret schrijven. Controleer dat het profiel dat `mobile/ios/testflight.py` aanmaakt de push-capability bevat (het neemt de capabilities van de bundle ID over, dus taak 1.6 is nodig). Background mode `remote-notification` is niet nodig voor een gewone melding.
4. Zonder de secrets moet de build blijven werken (zoals de iOS-job nu zonder signing-secrets): Firebase dan niet initialiseren.
5. Na inloggen (in `loadAccount` en na `verifySignInCode`): vraag toestemming voor meldingen, haal het FCM-token op en stuur het naar de cloud met `POST /v1/me/push-token` `{"token": "...", "platform": "ios"|"android"}`. Ook bij `onTokenRefresh`. Bij uitloggen: `DELETE /v1/me/push-token`.
6. Tik op de melding (`onMessageOpenedApp` en `getInitialMessage`): ga naar het Room-tabblad (tab 0 in `mobile/lib/main.dart`) en roep `state.findHostedRoom()` aan. Komt de melding binnen terwijl de app al open is, dan is een korte toast genoeg; de 10-secondenpoll doet de rest.
7. Tests: volg het patroon van `mobile/test/hosted_room_test.dart` (MockClient). `flutter analyze` en `flutter test` moeten groen zijn.

### 4. Cloud (`ontola/gamenight-internal`, `crates/gamenight-cloud`)

1. Nieuwe tabel in `Store::open`: `push_tokens(token TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, platform TEXT NOT NULL, updated INTEGER NOT NULL)`. Maximaal een handvol tokens per account; het oudste vervalt.
2. Routes in `src/lib.rs` naast de andere `/v1/me`-routes (rond `.route("/v1/me", ...)`): `POST /v1/me/push-token` en `DELETE /v1/me/push-token`, alleen voor ingelogde accounts (`account_id`), niet voor gasttokens.
3. In `pickup()`: na de succesvolle `bindings.insert`, buiten de broker-lock, een melding sturen naar alle tokens van `pending.account`. Nooit de pickup laten falen of wachten op FCM: `tokio::spawn`, korte timeout, fouten alleen loggen. Titel `GameNight`, tekst `You're in room ABC234` (de app is Engels), data `{"room_code": "ABC234"}`.
4. FCM HTTP v1: `POST https://fcm.googleapis.com/v1/projects/<project_id>/messages:send` met een OAuth2-token dat je uit het service account (JWT, scope `https://www.googleapis.com/auth/firebase.messaging`) haalt en cachet tot het verloopt. Antwoordt FCM met `UNREGISTERED` of 404, verwijder dat token.
5. Ontbreekt `GAMENIGHT_FCM_SERVICE_ACCOUNT`, dan doet de cloud niets (geen fout), zodat tests en lokale hosts blijven werken.
6. Tests in `crates/gamenight-cloud/tests/relay.rs`: token registreren, pickup aan de deur leidt tot precies één verzonden melding (maak de verzender vervangbaar, bijv. een trait of een testkanaal), geen melding bij de pairing claim of bij `/v1/rooms/guest/seat`. Draai `cargo fmt --all --check`, `cargo clippy -p gamenight-cloud --all-targets` en `cargo test -p gamenight-cloud`.
7. **Volgorde**: eerst de cloud deployen (de routes moeten bestaan), dan pas de app-build.

## Werkafspraken in dit project

- Direct pushen naar `main`, geen PR's (beide repo's).
- In `ontola/gamenight` moet de check `python3 scripts/build-docs.py --check` groen blijven (eerst `python3 scripts/fetch-game-sources.py`). Pas zo nodig `docs/player-memory.md` aan.
- Niet terugdraaien: de main player wordt nooit automatisch op een controller gezet. Hij wacht bij de deur en wordt daar opgepakt (zie `docs/player-memory.md`). De melding komt pas ná dat oppakken.

## Bekende risico's

- **iOS-build faalt op signing na de entitlements**: de bundle ID mist de Push Notifications-capability (taak 1.6), of het profiel uit `testflight.py` is ouder. Een nieuwe run maakt een nieuw profiel.
- **Geen melding op iOS, wel op Android**: APNs-sleutel niet geüpload in Firebase, of verkeerde Team ID.
- **401 van FCM**: verkeerd service account of verkeerd project-id.
- **Melding komt, maar app staat niet in de room**: kijk of `GET /v1/rooms/status` voor dat account `connected` geeft; zo niet, dan ging de pickup mis op de PC en niet de melding.

## Klaar wanneer

Joep scant niets, pakt zijn character op bij de deur op Mancave en krijgt binnen een paar seconden een melding op zijn iPhone. Tikken opent de app in die room met "Connected as Joep". Hetzelfde op een Android-telefoon met de APK.

